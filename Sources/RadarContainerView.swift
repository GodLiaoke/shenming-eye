import SwiftUI
import WebKit

/// 手机端外壳 —— 重设计 v3（2026-10-09）：**两个界面**。
///
/// ```
/// 主界面（MainConsoleView）= 配置与连接   一局只做一次
///     └─ 底部一颗「雷达」按钮  →  全屏雷达
/// 全屏雷达（RadarStageView）= 只有雷达   整局 30 分钟一直看
/// ```
///
/// ## 三条不能破的规则（改这个文件之前先读）
/// ① **WebView 常驻，绝不重建。** 它活在本文件的 `ZStack` 里，两个界面共用同一个实例，
///    切界面只改 `opacity` / `offset` / `allowsHitTesting`。一旦改成"用时创建"：
///    WebSocket 重连 → 地图重新加载 → 标定重算，每次切换都卡一下，还可能丢几秒坐标。
/// ② **不碰雷达页的 JS / WebSocket / 渲染逻辑。** 网页控制抽屉负责视图与目标。
/// ③ **雷达页上只保留原生状态点和画中画入口**；不再与网页重复放置视图工具条。
struct RadarContainerView: View {
    @EnvironmentObject private var model: AppModel
    let grant: RoomGrant

    /// 当前在哪个界面。**这是唯一的界面状态** —— 它只决定显隐，不决定生死。
    @State private var stage: Stage = .console
    @State private var viewMode: RadarViewMode = RadarContainerView.storedViewMode
    @State private var showingConnection = false
    @State private var hint: String?

    @StateObject private var webBox = WebViewBox()
    @StateObject private var pip = PiPPump()

    /// 上一次真正交给 WebView 的地址。
    /// 用它做等值判断 + 做 `.id()`：**地址没变就绝不重载**，地址变了才允许重建一次。
    @State private var radarURLLast: String = ""

    private enum Stage { case console, radar }

    /// 【仅模拟器】`PHOENIX_SIM_OPEN_PANEL=1` 时启动就展开主界面的连接详情，
    /// 供截图核对排版（模拟器没有稳定的点击注入手段）。真机恒为 false。
    private static var simulatorOpensDetailAtLaunch: Bool {
        #if targetEnvironment(simulator)
        return ProcessInfo.processInfo.environment["PHOENIX_SIM_OPEN_PANEL"] == "1"
        #else
        return false
        #endif
    }

    /// 【仅模拟器】`PHOENIX_SIM_OPEN_RADAR=1` 直接进全屏雷达（截图用）。真机恒为 false。
    private static var simulatorStartsOnRadar: Bool {
        #if targetEnvironment(simulator)
        return ProcessInfo.processInfo.environment["PHOENIX_SIM_OPEN_RADAR"] == "1"
        #else
        return false
        #endif
    }

    /// 视图模式记在本地：切过 3D 的人下次进来还是 3D。
    private static var storedViewMode: RadarViewMode {
        if let raw = UserDefaults.standard.string(forKey: "phoenix.radar.viewMode"),
           let mode = RadarViewMode(rawValue: raw) {
            return mode
        }
        return .twoD
    }

    var body: some View {
        ZStack {
            PhoenixTheme.background.ignoresSafeArea()

            // ① 雷达层：**永远在**。这是整条数据链的命根子。
            radarStage
                .opacity(stage == .radar ? 1 : 0)
                .offset(y: stage == .radar ? 0 : 14)
                .allowsHitTesting(stage == .radar)
                .accessibilityHidden(stage != .radar)
                .zIndex(stage == .radar ? 1 : 0)

            // ② 主界面层：配置与连接。
            MainConsoleView(
                grant: grant,
                pip: pip,
                webBox: webBox,
                onEnterRadar: { enterRadar() },
                onEnterSelectedMode: { enterSelectedMode() },
                onOpenConnection: { showingConnection = true },
                onStartConnection: { Task { await model.startRelay(for: grant) } }
            )
            .opacity(stage == .console ? 1 : 0)
            .offset(y: stage == .console ? 0 : -10)
            .allowsHitTesting(stage == .console)
            .accessibilityHidden(stage != .console)
            .zIndex(stage == .console ? 1 : 0)

            // ③ 画中画宿主：1×1、不吃点击、几乎不可见。
            // **必须在屏**，否则系统判定 `isPictureInPicturePossible == false`，小窗起不来。
            // 它挂在两个界面之外，所以两层谁来谁走都不影响小窗。
            PiPHostRepresentable(controller: pip.controller)
                .frame(width: 1, height: 1)
                .opacity(0.02)
                .allowsHitTesting(false)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .zIndex(2)
        }
        .background(PhoenixTheme.background.ignoresSafeArea())
        .onAppear {
            if Self.simulatorStartsOnRadar { stage = .radar }
            if Self.simulatorOpensDetailAtLaunch { showingConnection = true }
        }
        .sheet(isPresented: $showingConnection) {
            ConnectionConsole(grant: grant)
        }
        .onReceive(pip.$hint.compactMap { $0 }) { message in
            withAnimation { hint = message }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(2.4 * 1_000_000_000))
                if hint == message { withAnimation { hint = nil } }
            }
        }
        .overlay(alignment: .bottom) {
            if let hint {
                Text(hint)
                    .font(PhoenixType.captionStrong)
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 74)
                    .allowsHitTesting(false)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    // MARK: - 雷达地址解析

    /// 本机面板优先（解码在本机，延迟最低）；引擎没起来时退回云端房间地址。
    ///
    /// ⚠️ 这里只把**解析结果**交给 WebView，而不是把闭包交给它。
    /// 闭包版（v2 的写法）在每次 SwiftUI 刷新时都会算出一个新的 `URL` 值，
    /// `updateUIView` 里的等值判断就一直不成立 → 反复 load → 把正在进行的加载取消(-999)。
    private func resolveRadarURL() -> URL? {
        #if targetEnvironment(simulator)
        // Simulator UI review must be deterministic even when the host-side
        // local engine is not listening on 18080.  The override is compiled
        // only for the simulator and never changes a device/customer build.
        if let raw = ProcessInfo.processInfo.environment["PHOENIX_SIM_ROOM_URL"],
           let simulatedURL = URL(string: raw) {
            return simulatedURL
        }
        #endif
        // 新版只开本机面板：云端房间页（异地观看）已移除，
        // 面板没起来就如实报错，不回退到任何远端地址。
        let base = LocalRelay.panelPageURL
        // `?view=` 是雷达页**本来就有**的深链（页面初始化时读一次）。
        // 用它切 2D/双视/3D，就不必在页面里再加一套 JS 状态。
        let candidate = base.flatMap { url -> URL? in
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
            var items = (components.queryItems ?? []).filter { $0.name != "view" }
            items.append(URLQueryItem(name: "view", value: viewMode.deepLink))
            components.queryItems = items
            return components.url ?? url
        }
        return candidate
    }

    private func enterRadar() { withAnimation(PhoenixMotion.stage) { stage = .radar } }

    /// 本机模式：先让 A 的游戏通道进入可用状态，再启动 PiP。
    /// WebView 常驻在 ZStack，但首次布局可能还没有拿到实例，因此最多等 2 秒再启动。
    private func enterSelectedMode() {
        let modeToken = model.usageModeGeneration
        guard model.usageMode == .singleDevice else {
            withAnimation(PhoenixMotion.stage) { stage = .radar }
            Task { @MainActor in
                if !model.relayRunning { await model.startRelay(for: grant) }
                guard model.usageMode == .dualDevice,
                      model.usageModeGeneration == modeToken else { return }
            }
            return
        }
        withAnimation(PhoenixMotion.stage) { stage = .radar }
        Task { @MainActor in
            guard model.usageMode == .singleDevice,
                  model.usageModeGeneration == modeToken else { return }
            guard await model.startGameTraffic() else {
                hint = model.gameTrafficError ?? "本机游戏通道未连接，请重试"
                return
            }
            guard model.usageMode == .singleDevice,
                  model.usageModeGeneration == modeToken else { return }
            for _ in 0..<20 {
                guard model.usageMode == .singleDevice,
                      model.usageModeGeneration == modeToken else { return }
                if let webView = webBox.webView {
                    pip.start(webView: webView)
                    return
                }
                try? await Task.sleep(nanoseconds: UInt64(0.1 * 1_000_000_000))
            }
            hint = "雷达还没加载好，请稍后再点进入游戏模式"
        }
    }

    private func leaveRadar() {
        withAnimation(PhoenixMotion.stage) { stage = .console }
    }

    // MARK: - 雷达层

    private var radarStage: some View {
        ZStack(alignment: .bottomTrailing) {
            radarSurface

            // 底缘一条极淡的暗角：把"屏幕下沿"交代出来，也让状态点所在的那一角安静下来。
            // 它是**画在地图之上的渐变**，不吃点击、不改变 WebView 的任何几何。
            LinearGradient(
                colors: [.clear, PhoenixTheme.background.opacity(0.42)],
                startPoint: .center,
                endPoint: .bottom
            )
            .frame(height: 150)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .allowsHitTesting(false)

            // 状态点：全屏雷达上唯一常驻的状态显示，点一下回主界面。
            RadarStatusDot(
                level: model.dataFlow.lampLevel,
                label: model.dataFlow.headline,
                onTap: leaveRadar
            )
            .padding(.leading, 12)
            // radarStage 忽略了顶部安全区，原生返回条必须主动避开灵动岛/状态栏。
            .padding(.top, 58)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            if !radarNodeReady {
                radarConnectionGate
            }

            radarControls
        }
        .ignoresSafeArea(edges: .top)
    }

    private var radarNodeReady: Bool {
        switch model.dataFlow {
        case .waiting, .streaming: return true
        case .starting, .fault: return false
        }
    }

    /// 防止“点进雷达后才发现节点没连上”的死路：雷达页也给出下一步，
    /// 但默认动作是回连接页，不会把客户留在一张空地图上。
    private var radarConnectionGate: some View {
        VStack(spacing: 14) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(PhoenixTheme.warm)
            Text("还没有连接节点")
                .font(PhoenixType.title)
            Text("先连接本机节点，雷达才能接收坐标。")
                .font(PhoenixType.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 10) {
                Button("返回连接节点", action: leaveRadar)
                    .buttonStyle(.borderedProminent)
                    .tint(PhoenixTheme.accent)
                Button("重试连接") {
                    Task { await model.startRelay(for: grant) }
                }
                .buttonStyle(.bordered)
                .tint(PhoenixTheme.auroraViolet)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 22)
        .frame(maxWidth: 360)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(PhoenixTheme.warm.opacity(0.42), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 26, y: 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 20)
        .padding(.bottom, 86)
        .accessibilityElement(children: .contain)
    }

    /// 当前应当显示的雷达地址。**每次 body 现算**，而不是"进页面时算一次存起来" ——
    /// 存起来那版在"引擎后起来"时会永远停在 nil（实测：主界面显示引擎失败，
    /// 之后引擎被自动拉起，雷达页却一直是空白错误页）。
    private var radarURL: URL? { resolveRadarURL() }

    @ViewBuilder
    private var radarSurface: some View {
        if let radarURL {
            RadarWebView(
                roomURL: radarURL,
                reloadTick: model.foregroundTick,
                box: webBox,
                pip: pip,
                onRoomDead: {
                    // 房间被回收/卡到期 → 用本地存着的卡密自动重新激活，客户不用手点
                    model.recoverDeadRoom()
                },
                onRetry: {
                    // **无条件重建引擎**。
                    // 不要判断 `LocalRelay.isRunning` —— 那只是 Swift 侧的标志位，
                    // 引擎内部挂掉时它仍然是 true，会导致"重试了但其实什么都没做"。
                    // 重建的代价约 1~2 秒，换来的是"按了就一定有效"。
                    await model.startRelay(for: grant)
                    // 引擎重建会重新铸面板令牌 → `panelPageURL` 变 → body 重算 → `.id` 变 →
                    // 这个 WebView 会带着新地址重建一次。这是**必要**的一次重建。
                }
            )
            // 地址真的变了才允许重建这一个 WebView 实例；
            // **两个界面之间切换不会改这个 id** —— 那正是"常驻"这条硬约束的落点。
            .id(radarURL.absoluteString)
            .task(id: radarURL.absoluteString) { radarURLLast = radarURL.absoluteString }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "antenna.radiowaves.left.and.right.slash")
                    .font(.system(.title2))
                    .foregroundStyle(PhoenixStatus.offline)
                Text("房间链接无效，请重新授权")
                    .font(PhoenixType.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(PhoenixTheme.background)
        }
    }

    /// 原生只保留画中画入口；2D/双视/3D、镜头和目标统一交给网页控制抽屉。
    /// 这样不会与 WKWebView 自己的控制入口叠在右下角。
    @ViewBuilder
    private var radarControls: some View {
        if let pip = pipRailItem {
            Button(action: pip.toggle) {
                Image(systemName: pip.isActive ? "pip.exit" : "pip.enter")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(pip.isActive ? PhoenixTheme.accent : .primary)
                    .accessibilityLabel(pip.isActive ? "退出画中画" : "画中画")
            }
            .buttonStyle(RadarHUDButtonStyle(tinted: pip.isActive))
            .opacity(0.78)
            .accessibilityHint("在其他应用上继续查看雷达")
            .padding(.leading, 14)
            .padding(.bottom, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
    }

    /// 画中画只在设备支持时出现。它在全屏雷达下依然有意义：
    /// 切到别的 App（比如查战绩）时，系统小窗里还能继续看到雷达。
    private var pipRailItem: (isActive: Bool, toggle: () -> Void)? {
        guard model.usageMode == .singleDevice, RadarPiPController.isSupported else { return nil }
        return (pip.isActive, { pip.toggle(webView: webBox.webView) })
    }
}

/// 两界面切换的动效：**一个被设计过的时刻**，不是每处都加一点动画。
///
/// 雷达是"升上来"的（`offset` + 轻微缩放 + 交叉淡入），回主界面反向。
/// 用一条舒展的弹簧而不是线性淡入淡出 —— 30 分钟里可能只切两次，
/// 这两次要让客户感觉到"进入雷达"这件事本身有分量。
enum PhoenixMotion {
    static let stage = Animation.spring(response: 0.42, dampingFraction: 0.86)
}

/// 把画中画宿主视图挂进 SwiftUI（1×1 不显眼，但必须在屏）。
///
/// 它挂在**两个界面之外的常驻层**上：全屏雷达和主界面都在时它都在，
/// 因为系统要求"画中画宿主视图必须在屏"才会允许起小窗。
struct PiPHostRepresentable: UIViewRepresentable {
    let controller: RadarPiPController

    func makeUIView(context: Context) -> UIView {
        controller.makeHostView()
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

/// 画中画状态外壳：原生帧源从本机面板 WebSocket 取数并绘制，
/// 不再读取 WKWebView 的页面像素。参数保留给旧 UI 调用兼容。
///
/// ## 有了全屏雷达之后，画中画还要不要？
/// **要，但它从"主入口"降级成了备用件。** 理由：
///  · 它当初解决的问题是"雷达只占屏幕一小块，切到别的 App 就看不见了"；
///    全屏雷达解决了"小"，但**没解决"切走就看不见"** —— 那是后台存活问题。
///  · `UIBackgroundModes: [audio]` 只能让 App 不被立刻挂起，用户切到浏览器/微信时
///    屏幕上看不到任何雷达；画中画是唯一能在别的 App 上面继续显示雷达的手段。
///  · 它在界面上不再占右下角：网页右下角只保留统一控制抽屉，原生画中画入口放在左下角。
/// 所以：保留功能，取消它的常驻位置。
@MainActor
final class PiPPump: ObservableObject {
    @Published private(set) var isActive = false
    @Published private(set) var isPreparing = false
    @Published private(set) var hint: String?
    let controller = RadarPiPController()
    private var panelAttached = false

    init() {
        controller.onActiveChanged = { [weak self] active in
            Task { @MainActor in
                self?.isActive = active
                self?.isPreparing = false
            }
        }
        controller.onFailure = { [weak self] message in
            Task { @MainActor in
                self?.isPreparing = false
                self?.hint = message
            }
        }
    }

    /// 原生帧源绑定到本机面板；之后画中画不再读取 WKWebView 截图。
    func attach(panelURL: URL, token: String, webView: WKWebView?) {
        controller.attachPanel(panelURL, token: token, webView: webView)
        panelAttached = true
    }

    func detach() {
        controller.detachPanel()
        panelAttached = false
        isActive = false
        isPreparing = false
    }

    func toggle(webView: WKWebView? = nil) {
        if isActive {
            stop()
        } else {
            start(webView: webView)
        }
    }

    func stop() {
        controller.stop()
        isActive = false
        isPreparing = false
    }

    /// 参数保留给旧 UI 调用兼容；真正的画面来源是原生 WebSocket + Core Graphics。
    func start(webView: WKWebView?) {
        guard !isActive, !isPreparing else { return }
        guard panelAttached else {
            hint = "雷达还没加载好，请稍后再试"
            return
        }
        isPreparing = true
        controller.start()
    }
}

