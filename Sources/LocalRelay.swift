import CodevMobile
import Foundation

private actor LocalRelayStartGate {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func lock() async {
        if !locked {
            locked = true
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(continuation)
        }
    }

    func unlock() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        } else {
            locked = false
        }
    }
}

/// iOS 本机引擎（`CodevMobile`：进程内 SOCKS5 代理 + 抓包 + **旧版部署**）。
///
/// 与旧版 `PhoenixCloudRelay` 的**架构差别**（这次切换的核心）：
/// | | 旧（PhoenixCloudRelay） | 新（CodevMobile） |
/// |---|---|---|
/// | 上网路径 | B → A → **云端节点** → 出口 | B → A → **本机直出**（延迟最低） |
/// | 算法服务 | **云端** | **实时处理**（按会话授权） |
/// | 雷达页来源 | 云端房间 URL | **本机面板 127.0.0.1:18080** |
///
/// 之所以保留 `LocalRelay` 这个名字和大部分外形：让上游（`AppModel`、`ConnectionSheet`）
/// 尽量少改，降低切换风险。
@MainActor
enum LocalRelay {
    /// 本机监听端口：和 Mac 版保持一致，Shadowrocket 里习惯用 2025。
    static let port: UInt16 = 2025
    /// 本机面板端口（雷达页由它提供）。
    static let panelPort: UInt16 = 18_080

    /// 本机代理账号：引擎启动时铸一次，密码每次启动随机。
    private(set) static var username = "phoenix-local"
    private(set) static var password: String?
    /// 雷达页地址（本机面板）；引擎未就绪时为 nil。
    private(set) static var panelURL: URL?
    private(set) static var panelToken: String?
    private(set) static var isRunning = false
    /// C 引擎是进程级单例；启动跨越健康检查 await，必须串行化，不能让两次启动交错覆盖凭据。
    private static let startGate = LocalRelayStartGate()
    private static var startGeneration: UInt64 = 0

    /// 已接入的游戏设备数。
    ///
    /// ⚠️ 已知功能降级：旧框架有 `phoenix_cloud_relay_client_count()`，
    /// 而 `CodevMobile` 没有等价的瞬时计数（`codev-proxy` 的计数器全是累计值）。
    /// 暂时恒为 0 —— **"已连接 N 台"这个提示在当前架构下拿不到数据**，
    /// 需要后续给引擎补一个活跃会话 gauge，或改读面板的 `/api/v1/proxy/status`。
    static var clientCount: Int { 0 }

    /// 启动进程内引擎。`advertisedHost` 是给 B 手机扫码用的局域网地址，可为空。
    /// 返回 0 表示成功（与旧版 `phoenix_cloud_relay_start` 的约定保持一致）。
    @discardableResult
    static func start(advertisedHost: String) async -> Int32 {
        await startGate.lock()
        startGeneration &+= 1
        let generation = startGeneration
        resetEngineState()
        let result: Int32
        do {
            let access = try await LocalCodeVEngine.shared.start(advertisedHost: advertisedHost)
            guard generation == startGeneration, !Task.isCancelled else {
                resetEngineState()
                result = -1
                await startGate.unlock()
                return result
            }
            username = access.proxyUsername
            password = access.proxyPassword
            panelToken = access.panelToken
            panelURL = access.panelURL
            isRunning = true
            result = 0
        } catch {
            isRunning = false
            result = -1
        }
        await startGate.unlock()
        return result
    }

    /// 单机模式：主 App 只接管扩展返回的面板地址，不在本进程再起代理。
    static func adopt(_ access: LocalCodeVAccess) {
        username = access.proxyUsername
        password = access.proxyPassword
        panelToken = access.panelToken
        panelURL = access.panelURL
        isRunning = true
    }

    static func stop() {
        startGeneration &+= 1
        resetEngineState()
    }

    private static func resetEngineState() {
        LocalCodeVEngine.shared.stop()
        isRunning = false
        password = nil
        panelToken = nil
        panelURL = nil
    }

    /// **雷达页要用的地址**：必须带令牌 —— 而且是**两个**参数，少一个就"网页没数据"。
    ///
    /// 引擎返回的 `panelURL` 是 `http://127.0.0.1:18080/`（不含令牌），令牌在 `panelToken` 里。
    ///
    /// - `token=` ：让面板的 `/` 路由放行（require_access），页面才打得开；
    /// - `access=`：保留给外部/房间页的兼容入口。127.0.0.1 页面由引擎的
    ///   `allow_lan_hosts` 直接放行，不再依赖 Cookie 交换；如果以后把同一地址
    ///   交给外部浏览器，网页仍可用这个参数完成会话交换。
    static var panelPageURL: URL? {
        guard let panelURL, let panelToken, !panelToken.isEmpty else { return nil }
        var components = URLComponents(url: panelURL, resolvingAgainstBaseURL: false)
        var items = components?.queryItems ?? []
        items.append(URLQueryItem(name: "token", value: panelToken))
        items.append(URLQueryItem(name: "access", value: panelToken))
        components?.queryItems = items
        return components?.url
    }

    /// 真健康检查：直接问本机面板 `/api/v1/healthz`。
    ///
    /// 为什么需要它：`isRunning` 只是 Swift 侧的标志位 —— 引擎内部挂掉时它仍是 true。
    /// 要判断"面板到底还在不在听"，只能真发一个请求。
    static func isHealthy(timeout: TimeInterval = 1.5) async -> Bool {
        guard let panelURL else { return false }
        var request = URLRequest(url: panelURL.appendingPathComponent("api/v1/healthz"))
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    /// 分层探测本机代理链路。Rust 端通过 C ABI 返回脱敏 JSON。
    static func diagnostics() async -> ProxyDiagnosticsSnapshot? {
        guard let password, isRunning else { return nil }
        let username = self.username
        return await Task.detached(priority: .utility) {
            let raw = username.withCString { user in
                password.withCString { secret in codev_engine_diagnostics(user, secret) }
            }
            guard let raw else { return nil }
            let payload = String(cString: raw)
            codev_engine_string_free(raw)
            return try? ProxyDiagnosticsSnapshot(json: Data(payload.utf8))
        }.value
    }

    /// Shadowrocket 扫码用：`socks5://<账号>:<密码>@<局域网IP>:2025`
    static func link(address: String) -> String? {
        guard isRunning, let password else { return nil }
        var components = URLComponents()
        components.scheme = "socks5"
        components.host = address
        components.port = Int(port)
        components.user = username
        components.password = password
        return components.url?.absoluteString
            ?? "socks5://\(username):\(password)@\(address):\(port)"
    }
}
