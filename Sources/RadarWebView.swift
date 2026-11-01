import SwiftUI
import WebKit

/// 让外层能拿到内部那个 WKWebView（画中画要定期抓它的快照）。
final class WebViewBox: ObservableObject {
    weak var webView: WKWebView?
}

/// 算法服务版的雷达视图：只显示**服务器房间**的雷达页。
///
/// 和旧版旧版部署的区别：
/// - 不再加载 127.0.0.1 的本机面板，也不做管理员令牌交换 ——
///   房间链接（`/r/<房间号>?access=…`）本身会下发会话 cookie，页面直接用。
/// - 页面会自己连 `/api/v1/ws` 拿数据，所以这里只负责"把页面显示好 + 别乱跳转"。
/// - 测试包（裸 IP + 自签证书）在 `PhoenixTestInsecureTLS=1` 时放行证书校验。
struct RadarWebView: UIViewRepresentable {
    let roomURL: URL
    /// 回到前台时自增，用来触发页面重连（网页里的 WebSocket 断了会自己重连，这里只是补一刀）。
    var reloadTick: Int = 0
    /// 把创建好的 WebView 交出去，供画中画抓快照。
    var box: WebViewBox?
    /// 原生画中画帧源；不再抓取此 WebView 的截图。
    var pip: PiPPump?
    /// 页面变成"房间已失效"（房间被回收/卡到期）→ 让上层自动重新激活一次。
    var onRoomDead: (() -> Void)?
    /// 失联时的"当前地址"——**实时计算**，而不是用加载时那份快照。
    ///
    /// 这是个真 bug 的修复：本机引擎每次重启都会**重新铸面板令牌**，
    /// 而失败页上的"重新连接"原先指向 `requestedURL`（带着旧令牌的旧地址），
    /// 于是重试永远失败 —— 表现就是"点重新连接没反应，退后台重进才好"。
    var freshURL: (() -> URL?)?
    /// 重试时先让上层把引擎拉起来（引擎可能已经停了）。
    var onRetry: (() async -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(onRoomDead: onRoomDead, freshURL: freshURL, onRetry: onRetry)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        // S1：地图已在 App 包里，起一个只服务图片的本地服务，并注入地址改写，
        // 让页面的 /api/v1/maps/<文件> 走本地（清单仍走云端）。服务未就绪时不注入，页面照旧走云端。
        // 网页现在收到第一条 map_roster 就能采用引擎绑定，不再需要包裹原生
        // WebSocket。此前的注入包装器会让 WKWebView 偶发只触发 open、不转发首批
        // hello/snapshot/map_roster，结果就是画中画有图而 App 页面停在空态。
        LocalMapServer.shared.start()
        if let base = LocalMapServer.shared.baseURL {
            configuration.userContentController.addUserScript(
                WKUserScript(source: Self.mapRewriteScript(base: base),
                             injectionTime: .atDocumentStart,
                             forMainFrameOnly: true)
            )
        }
        // 神明之眼 1.0：英雄身份放行。
        // 引擎已经把 roster 里的 agent_id 贴到每个位置上（codev-web 的
        // attach_roster_identity），但页面只在 identity_confidence == "proven"
        // 时才肯用 agent_id / display_name —— 敌人那五格在阵营 commit 之前是
        // "unresolved"，于是"有英雄编号也显示不出英雄"。这里在页面脚本之前
        // 包一层 JSON.parse：只把**已带 agent_id 的位置**标成 proven 并补昵称，
        // 坐标/阵营/连续性的可信度一概不动。
        configuration.userContentController.addUserScript(
            WKUserScript(source: Self.heroIdentityScript,
                         injectionTime: .atDocumentStart,
                         forMainFrameOnly: true)
        )
        // 换皮：白色液态玻璃（只动 CSS，不动页面逻辑）。
        configuration.userContentController.addUserScript(
            WKUserScript(source: Self.radarSkinScript,
                         injectionTime: .atDocumentStart,
                         forMainFrameOnly: true)
        )
        // 雷达页在手机上是"贴着边缘铺满"的，别让 WebView 自己留白。
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = UIColor(red: 0.016, green: 0.027, blue: 0.043, alpha: 1)
        webView.scrollView.backgroundColor = webView.backgroundColor
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.bounces = false
        webView.allowsBackForwardNavigationGestures = false
        // 手机上地图要能拖动/缩放，但不要页面级别的橡皮筋滚动。
        webView.scrollView.isScrollEnabled = false
        context.coordinator.webView = webView
        box?.webView = webView
        // 单机模式绑定 127.0.0.1 面板；双机模式不会展示画中画入口。
        pip?.attach(panelURL: LocalRelay.panelURL ?? roomURL, token: LocalRelay.panelToken ?? "", webView: webView)
        context.coordinator.load(roomURL, in: webView)
        return webView
    }

    /// 把页面里 `/api/v1/maps/<文件名>` 的取图请求改写到本地服务（S1）。
    /// **只改写具体地图文件**；`/api/v1/maps/manifest` 清单仍走云端 ——
    /// 这样以后换地图、加地图，清单能跟着云端更新，不必重发 App。
    /// 服务未就绪时不注入本脚本，页面行为与改动前完全一致（可安全回退）。
    /// 英雄身份放行脚本（注入在页面脚本之前）。
    ///
    /// 只做两件事：
    ///   ① 把 `map_roster` 里的 `slot → display_name` 缓存下来；
    ///   ② 给 `position_delta` / `snapshot` 里**已经带 agent_id 的位置**打上
    ///      `identity_confidence = "proven"` 并补上昵称。
    ///
    /// 为什么必须打这个补丁：页面 `zt()` 里写死
    /// `agent_id: "proven" === identity_confidence ? … : null`，
    /// 而引擎只有在阵营 commit 后才把位置标 proven，敌人前几秒是 unresolved
    /// → 英雄头像/名称整块被丢掉（界面上就是"没有英雄"）。
    /// 这里只放行"英雄身份"这一项；坐标、阵营、continuity 全部原样不动，
    /// 所以不会把未确认的位置画成已确认。
    static let heroIdentityScript = """
    (function () {
      var ROSTER = Object.create(null);
      function remember(obj) {
        if (!obj || obj.kind !== "map_roster") return;
        var list = obj.payload && obj.payload.roster;
        if (!Array.isArray(list)) return;
        for (var i = 0; i < list.length; i++) {
          var e = list[i];
          if (!e) continue;
          if (Number.isInteger(e.slot) && typeof e.display_name === "string" && e.display_name) {
            ROSTER[e.slot] = e.display_name;
          }
        }
      }
      function unlock(obj) {
        if (!obj || typeof obj !== "object") return;
        if (obj.kind !== "position_delta" && obj.kind !== "snapshot") return;
        var list = obj.payload && obj.payload.positions;
        if (!Array.isArray(list)) return;
        for (var i = 0; i < list.length; i++) {
          var p = list[i];
          if (!p || typeof p !== "object") continue;
          if (typeof p.agent_id !== "number" || !(p.agent_id > 0)) continue;
          var name = ROSTER[p.slot];
          if (!p.display_name && name) p.display_name = name;
          if (p.identity_confidence !== "proven") p.identity_confidence = "proven";
        }
      }
      var original = JSON.parse;
      if (typeof original !== "function") return;
      window.JSON.parse = function (text, reviver) {
        var value = original.call(this, text, reviver);
        try { remember(value); unlock(value); } catch (ignore) {}
        return value;
      };
    })();
    """
    /// 神明之眼 · 雷达页白色液态玻璃皮肤（运行时注入，不改引擎二进制）。
    ///
    /// 页面自带 104 KB 深色 CSS，但颜色几乎全走 :root 变量；覆盖变量 + 20 条
    /// 结构规则即可整页换皮，并隐藏只给开发看的「引擎指标 / 操作」诊断块。
    /// 底图画布保持深色（地图与标记对比度不动）。
    static let radarSkinScript = """
    (function () {
      var CSS = `
      :root{color-scheme:light !important;
      --bg:#eef2f8;--bg-raised:#ffffff;--panel:rgba(255,255,255,.80);--panel-solid:#ffffff;
      --panel-soft:rgba(255,255,255,.62);--line:rgba(20,23,37,.10);--line-strong:rgba(20,23,37,.18);
      --text:#141725;--muted:#6d7587;--dim:#8b93a3;--good:#14a369;--warn:#d88c14;--bad:#e03b57;
      --blue:#2b6cff;--red:#e03b57;--accent:#2b3160;--accent-strong:#4a4f8a;
      --shadow:0 18px 44px rgba(20,23,37,.12);--shadow-1:0 1px 2px rgba(20,23,37,.08),0 2px 8px rgba(20,23,37,.06);
      --shadow-2:0 8px 28px rgba(20,23,37,.10);--shadow-3:0 24px 60px rgba(20,23,37,.16);
      --surface-night:#eef2f8;--surface-indigo:#ffffff}
      html,body{background:#eef2f8 !important;color:#141725 !important}
      body{background:radial-gradient(circle at 12% 0,rgba(124,103,246,.26) 0,transparent 42%),radial-gradient(circle at 92% 100%,rgba(113,199,246,.24) 0,transparent 46%),linear-gradient(160deg,#ffffff 0,#eef2f8 62%) !important}
      header,aside,footer,.map-panel{background:rgba(255,255,255,.76) !important;border-color:rgba(255,255,255,.92) !important;color:#141725 !important;backdrop-filter:blur(18px) saturate(1.15);box-shadow:0 12px 32px rgba(20,23,37,.10) !important}
      header{background:linear-gradient(180deg,rgba(255,255,255,.94),rgba(255,255,255,.60)) !important}
      h1,.section-title,.player-name,.metric b,.operation-name{color:#141725 !important}
      .sub,.status,.player-detail,.health,.metric span,.operation-detail,.operation-state,.time-labels,.privacy,.map-label{color:#6d7587 !important}
      .player{background:rgba(255,255,255,.68) !important;border-color:rgba(20,23,37,.08) !important;box-shadow:0 6px 18px rgba(20,23,37,.06) !important}
      .player[aria-pressed="true"]{background:rgba(43,49,96,.10) !important;border-color:rgba(43,49,96,.28) !important}
      .swatch{border-color:rgba(20,23,37,.14) !important}
      button,select,input{background:rgba(255,255,255,.92) !important;color:#2b3160 !important;border-color:rgba(20,23,37,.14) !important;box-shadow:0 4px 14px rgba(20,23,37,.06) !important}
      button:hover{background:#ffffff !important;border-color:rgba(43,49,96,.34) !important}
      .metric,.operation,.timeline{background:rgba(255,255,255,.62) !important;border-color:rgba(20,23,37,.08) !important}
      .metrics,.operations{display:none !important}
      canvas{background:#0b0f16 !important;border-radius:18px}
      .map-panel{border-radius:22px;overflow:hidden}
      #toast,.auth-card{background:rgba(255,255,255,.94) !important;color:#141725 !important;border:1px solid rgba(255,255,255,.95) !important;box-shadow:0 20px 48px rgba(20,23,37,.16) !important}
      ::-webkit-scrollbar{width:10px}::-webkit-scrollbar-thumb{background:rgba(20,23,37,.14);border-radius:8px}
      `;
      function apply() {
        try {
          if (document.getElementById('shenming-skin')) return;
          var style = document.createElement('style');
          style.id = 'shenming-skin';
          style.textContent = CSS;
          (document.head || document.documentElement).appendChild(style);
        } catch (ignore) {}
      }
      apply();
      if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', apply, { once: true });
      }
    })();
    """
    static func mapRewriteScript(base: String) -> String {
        """
        (function () {
          var BASE = "\(base)";
          var KEY = "/api/v1/maps/";
          function rewrite(u) {
            if (typeof u !== "string") return u;
            var i = u.indexOf(KEY);
            if (i < 0) return u;
            var rest = u.substring(i + KEY.length);
            if (rest.indexOf("manifest") >= 0) return u;   // 清单继续走云端
            return BASE + "/" + rest;
          }
          var of = window.fetch;
          if (of) {
            window.fetch = function (input, init) {
              try {
                if (typeof input === "string") input = rewrite(input);
                else if (input && input.url) input = new Request(rewrite(input.url), input);
              } catch (e) {}
              return of.call(this, input, init);
            };
          }
          try {
            var d = Object.getOwnPropertyDescriptor(HTMLImageElement.prototype, "src");
            if (d && d.set && d.get) {
              Object.defineProperty(HTMLImageElement.prototype, "src", {
                configurable: true,
                get: function () { return d.get.call(this); },
                set: function (v) { d.set.call(this, rewrite(v)); }
              });
            }
          } catch (e) {}
        })();
        """
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.roomURL = roomURL
        // 闭包可能捕获了变化中的状态（比如面板令牌），每次更新都刷新一遍
        context.coordinator.freshURL = freshURL
        context.coordinator.onRetry = onRetry
        // ⚠️ 页面正在加载时**绝不能** reload —— reload 会把进行中的加载
        // 取消掉，WebKit 报 -999（表现为"雷达未连上"且永远好不了）。
        if context.coordinator.reloadTick != reloadTick {
            context.coordinator.reloadTick = reloadTick
            if !webView.isLoading {
                webView.reload()
            }
        }
        guard context.coordinator.requestedURL != roomURL else { return }
        context.coordinator.load(roomURL, in: webView)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let onRoomDead: (() -> Void)?
        /// 实时地址与重试回调（由上层注入；Coordinator 是嵌套类型，拿不到父 struct 的属性）
        fileprivate var freshURL: (() -> URL?)?
        fileprivate var onRetry: (() async -> Void)?
        private var didReportDeadRoom = false
        fileprivate var requestedURL: URL?

        init(
            onRoomDead: (() -> Void)? = nil,
            freshURL: (() -> URL?)? = nil,
            onRetry: (() async -> Void)? = nil
        ) {
            self.onRoomDead = onRoomDead
            self.freshURL = freshURL
            self.onRetry = onRetry
            super.init()
        }

        fileprivate var roomURL: URL?
        fileprivate var reloadTick = 0
        fileprivate weak var webView: WKWebView?

        private let allowInsecureTLS =
            (Bundle.main.object(forInfoDictionaryKey: "PhoenixTestInsecureTLS") as? String) == "1"

        /// 只放行我们自己的服务器（房间页会 307 到 /radar），别的地址一律不跳。
        private var allowedHosts: Set<String> {
            var hosts: Set<String> = ["127.0.0.1", "localhost"]
            if let host = roomURL?.host { hosts.insert(host) }
            hosts.insert(GatewayClient.origin.host ?? "")
            return hosts
        }

        fileprivate func load(_ url: URL, in webView: WKWebView) {
            didReportDeadRoom = false
            requestedURL = url
            roomURL = url
            webView.load(
                URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
            )
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
        // 失败页上的"重新连接"：重启引擎（如需）→ 用**当前**地址重新加载。
        if navigationAction.request.url?.scheme == "phoenix-retry" {
            decisionHandler(.cancel)
            Task { @MainActor in
                await onRetry?()
                let target = freshURL?() ?? requestedURL
                if let target {
                    requestedURL = target
                    webView.load(URLRequest(url: target))
                }
            }
            return
        }

            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            if ["about", "blob", "data"].contains(url.scheme ?? "") {
                decisionHandler(.allow)
                return
            }
            let ok = (url.scheme == "https" || url.scheme == "http")
                && allowedHosts.contains(url.host ?? "")
            decisionHandler(ok ? .allow : .cancel)
        }

        /// 自签证书放行（**仅测试包**）：只对房间主机 / 网关主机 / 回环生效。
        func webView(
            _ webView: WKWebView,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            guard allowInsecureTLS,
                  challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  allowedHosts.contains(challenge.protectionSpace.host),
                  let trust = challenge.protectionSpace.serverTrust else {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            completionHandler(.useCredential, URLCredential(trust: trust))
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // 页面标题统一成 App 名字（画中画/浏览器标签用得到）。
            webView.evaluateJavaScript("document.title = 'Phoenix CodeV';")
            detectDeadRoom(in: webView)
        }

        /// 房间被回收时服务端会给一页"这间房已经失效了"的人话页面。
        /// 客户不该自己去点「去激活页」——App 里存着卡密，自动重新激活才是对的做法。
        private func detectDeadRoom(in webView: WKWebView) {
            guard onRoomDead != nil, !didReportDeadRoom else { return }
            webView.evaluateJavaScript("document.body ? document.body.innerText.slice(0, 400) : ''") { [weak self] value, _ in
                guard let self, let text = value as? String else { return }
                let dead = text.contains("已经失效") || text.contains("房间不存在") || text.contains("卡密已到期")
                guard dead else { return }
                self.didReportDeadRoom = true
                self.onRoomDead?()
            }
        }

        /// 房间链接直接 4xx（房间没了）也走同一条自愈路径。
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
        ) {
            // ⚠️ 只有**云端房间**的 4xx 才算"房间失效"。
            // 本机面板（127.0.0.1 / localhost）返回 401 是面板自己的鉴权问题，
            // 跟云端房间死活无关；以前把它也当成房间死亡 → 触发重新激活 →
            // 页面重载 → 把正在进行的加载取消(-999) → 死循环（网关每 3 秒一条激活日志）。
            let isLocalPanel = ["127.0.0.1", "localhost"].contains(navigationResponse.response.url?.host ?? "")
            if let http = navigationResponse.response as? HTTPURLResponse,
               Self.isDeadRoomStatus(http.statusCode), !isLocalPanel {
                if onRoomDead != nil, !didReportDeadRoom {
                    didReportDeadRoom = true
                    onRoomDead?()
                }
            } else if let http = navigationResponse.response as? HTTPURLResponse,
                      http.statusCode >= 500 {
                // 5xx 是服务器短暂故障，不是卡密/房间死亡。别发起重复激活，
                // 直接给一个可点击的重连页。
                decisionHandler(.cancel)
                showFailure(
                    in: webView,
                    error: NSError(domain: "PhoenixRoomHTTP", code: http.statusCode)
                )
                return
            }
            decisionHandler(.allow)
        }

        static func isDeadRoomStatus(_ statusCode: Int) -> Bool {
            [400, 401, 402, 403, 404, 410].contains(statusCode)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            guard let requestedURL else { return }
            load(requestedURL, in: webView)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            showFailure(in: webView, error: error)
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            showFailure(in: webView, error: error)
        }

        private func showFailure(in webView: WKWebView, error: Error) {
            // 只说人话：客户不需要知道 NSURLErrorDomain，只要知道"网络/服务器"。
            let text = (error as NSError).code == NSURLErrorCannotConnectToHost
                || (error as NSError).code == NSURLErrorTimedOut
                ? "连不上云端房间，请检查网络后点击重试。"
                : "房间暂时打不开，请稍后点击重试。"
            // 用自定义协议：点击时由原生**实时**算出当前地址（含最新令牌）。
            let retryURL = "phoenix-retry://now"
            // 诊断：把**真实原因**印在失败页上。以前只显示"房间暂时打不开"，
            // 完全看不出是网络超时、被导航策略拦掉(-999)、还是服务器返回了错误页。
            let code = (error as NSError).code
            let diag = "错误码 \(code) · 页面连接策略：实时算法 / 共享房间"
            webView.loadHTMLString(
                """
                <html><head><meta name="viewport" content="width=device-width,initial-scale=1">
                <style>body{background:#04070b;color:#8fa5b5;font:15px -apple-system;padding:48px 28px;text-align:center}
                b{color:#e6f1f8;font-size:17px;display:block;margin-bottom:10px}
                a{display:inline-block;margin-top:20px;padding:11px 24px;border-radius:999px;background:#184c5b;color:#e6faff;text-decoration:none;font-weight:700}</style></head>
                <body><b>雷达未连上</b>\(text)<br><span style="font-size:11px;opacity:.65;display:block;margin-top:10px">\(diag)</span><a href="\(retryURL)">重新连接</a></body></html>
                """,
                baseURL: nil
            )
        }
    }
}