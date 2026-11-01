import Foundation
import UIKit

@MainActor
final class AppModel: ObservableObject {
    enum Phase {
        case loading
        case activation
        case ready
    }

    @Published private(set) var phase: Phase = .loading
    /// 完整性校验失败 → 硬阻断，激活成功也不放行
    @Published private(set) var integrityBlocked = false
    @Published private(set) var grant: RoomGrant?
    /// 首次进入不预设模式，用户选定后才展开该模式的教程和节点配置。
    @Published var usageMode: RadarUsageMode?
    @Published private(set) var activating = false
    /// 激活自动重试时的进度提示（"卡密服务器忙，正在自动重试（第 N 次）"）。
    @Published private(set) var activationNote: String?
    @Published private(set) var recoveryMessage: String?
    @Published var errorMessage: String?
    /// 本机中继状态（真实流量本机直出，解析也在本机完成）
    /// 当前算法服务状态：实时处理 / 未就绪。
    /// ⚠️ 这是**内部实现细节**，只出现在面板最底部折叠的"诊断信息"里；
    /// 它曾经被摆在面板顶部当状态用（"解码：本机"），用户明确要求删掉那一行 ——
    /// 客户要的是"通没通"，不是"哪一层在解"。
    @Published private(set) var decodePath = "未知"
    /// 本机面板数据流状态（给连接面板的折叠诊断区显示）
    @Published private(set) var panelStreamStatus = "未开启"
    /// 诊断：本机面板可达性（区分"引擎没监听"和"WebView加载失败"）
    @Published private(set) var panelProbe = "检测中…"
    @Published private(set) var panelProbeDetail: String?
    @Published private(set) var proxyDiagnostics: ProxyDiagnosticsSnapshot?
    @Published private(set) var backgroundStatus = "前台运行"
    @Published private(set) var relayRunning = false
    @Published private(set) var relayError: String?
    @Published private(set) var gameTrafficState: GameTrafficController.State = .idle
    @Published private(set) var gameTrafficError: String?
    /// 普通全能签不能承载 Network Extension 时，回退到小火箭接管游戏流量。
    @Published private(set) var shadowrocketFallback = false
    @Published private(set) var lanIPAddress: String?

    /// 局域网共享链接：**同一个 Wi-Fi 下**的其它设备（手机/平板/电脑）直接打开本机面板页。
    /// 数据全部在本机引擎里，不经过服务器，所以延迟为 0，但**离开这个 Wi-Fi 就打不开**。
    /// 形式：`http://<本机局域网IP>:18080/?token=<本机面板令牌>`（引擎面板绑 0.0.0.0 + 放行局域网）。
    var lanRadarShareLink: URL? {
        guard let host = lanIPAddress, !host.isEmpty,
              let token = LocalRelay.panelToken, !token.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = Int(LocalRelay.panelPort)
        components.queryItems = [URLQueryItem(name: "token", value: token)]
        return components.url
    }
    /// ⚠️ **恒为 0，不要拿它做"已连接 N 台"的显示。**
    /// `CodevMobile` 没有活跃会话 gauge（`codev-proxy` 的计数器全是累计值），
    /// 旧框架的 `phoenix_cloud_relay_client_count()` 没有等价物。
    /// 界面上"是否真的有数据在流"改由 `dataFlow` 回答（来源见下）。
    @Published private(set) var relayClientCount = 0
    private var relayTimer: Task<Void, Never>?
    private var proxyDiagnosticsTask: Task<Void, Never>?
    private var relayGeneration: UInt64 = 0
    /// 保护异步启动/自愈：旧的一次 startRelay 不能在新一次启动后回写状态。
    private var relayOperationID: UInt64 = 0
    /// 保护本机/双机模式切换：旧的 stopGameTraffic 不能清掉刚启动的新通道。
    private var gameTrafficOperationID: UInt64 = 0
    /// 保护进入雷达的异步任务：模式切换后旧任务不得再启动 PiP。
    private(set) var usageModeGeneration: UInt64 = 0

    // MARK: - 「有数据在流」的唯一真实信号
    //
    // `PanelStreamMonitor` 连的就是**雷达页同一条** WS（ws://127.0.0.1:18080/api/v1/ws），
    // 它每收到一条坐标，我们就记一次时间戳。所以这不是推测，是"雷达页正在画的那一帧"的同源读数。
    // 面板健康探测（panelProbe）负责回答"引擎还在不在"，两者分开：
    //   · 引擎在 + 没坐标 = A 还没有启动游戏或还没进入对局   → 琥珀
    //   · 引擎在 + 有坐标 = 数据真的在流                   → 绿
    //   · 引擎不在                                        → 红
    @Published private(set) var lastPositionAt: Date?
    @Published private(set) var positionCount = 0
    @Published private(set) var monitorState: PanelStreamMonitor.State = .idle

    /// 界面用的数据流状态。UI 只读这个，不自己拼条件。
    enum DataFlow: Equatable {
        /// 引擎还在启动 / 面板还没探测出结果。
        case starting
        /// 引擎与面板都正常，但还没有坐标进来（A 还没进入对局）。
        case waiting
        /// 有坐标在流。`count` 是本次收到的坐标帧数。
        case streaming(count: Int)
        /// 出问题了。`reason` 直接就是给客户看的一句话。
        case fault(String)

        var lampLevel: SignalLamp.Level {
            switch self {
            case .starting, .waiting: return .waiting
            case .streaming: return .go
            case .fault: return .fault
            }
        }

        /// 状态灯旁边那句话 —— 全界面最重要的一行字。
        var headline: String {
            switch self {
            case .starting: return "引擎启动中…"
            case .waiting: return "等待本机游戏流量"
            case .streaming: return "正在接收坐标"
            case let .fault(reason): return reason
            }
        }

        /// 补充行：只在有真实数据时给数字，拿不到就不编。
        var detail: String? {
            switch self {
            case let .streaming(count): return "已收到 \(count) 帧"
            case .waiting: return "点击进入游戏模式后启动一局"
            case .starting: return "正在启动本机引擎"
            case .fault: return nil
            }
        }

        var isStreaming: Bool {
            if case .streaming = self { return true }
            return false
        }
    }

    /// 由「面板探测结果 + 最近一次坐标时间 + 转发器状态」推导出的当前状态。
    var dataFlow: DataFlow {
        if let lastPositionAt, Date().timeIntervalSince(lastPositionAt) < 3 {
            return .streaming(count: positionCount)
        }
        switch monitorState {
        case let .failed(reason):
            // 转发器已经说清楚原因了（本机连接断开 / 上传异常），直接用它的原话。
            return .fault(shortReason(reason))
        default:
            break
        }
        if panelProbe.hasPrefix("本机面板不可达") {
            return .fault("引擎未运行")
        }
        if panelProbe == "检测中…" {
            return .starting
        }
        return .waiting
    }

    /// 把转发器的长句压成状态带能放下的一句话。
    private func shortReason(_ reason: String) -> String {
        if reason.contains("断开") { return "引擎连接断开" }
        if reason.contains("超时") { return "引擎无响应" }
        if reason.contains("HTTP") { return "云端上传失败" }
        return "转发异常"
    }

    /// 算法服务：雷达页来自本机实时处理面板；局域网共享是可选输出（异地观看已移除）。

    private let p0 = GatewayClient()
    private let p1 = JSONEncoder()
    private let p3 = "activation-card.v2"
    private let p4 = "room-grant.v2"
    private let p5 = "device-id"
    private let p6 = "com.myrader.val.codev.device-id"
    private var p7: Task<Void, Never>?
    private var p8: Task<Void, Never>?
    private var authorizationGeneration: UInt64 = 0

    init() {
        GameTrafficController.shared.onStateChanged = { [weak self] state in
            self?.gameTrafficState = state
            if case let .failed(reason) = state { self?.gameTrafficError = reason }
        }
        // Hosted tests must not migrate real credentials or start a relay.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            Task { await x0() }
        }
    }

    /// 统一记录模式切换代次，供主界面与雷达页在 await 之后丢弃过期任务。
    func selectUsageMode(_ mode: RadarUsageMode) {
        guard usageMode != mode else { return }
        usageModeGeneration &+= 1
        usageMode = mode
    }

    func activate(card rawCard: String) async {
        guard !integrityBlocked else {
            errorMessage = "应用完整性校验失败，已停止运行。请安装官方版本。"
            return
        }
        let card = rawCard
            .replacingOccurrences(of: "\u{200B}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !card.isEmpty else {
            errorMessage = "请输入卡密"
            return
        }
        authorizationGeneration &+= 1
        let generation = authorizationGeneration
        activating = true
        defer { if generation == authorizationGeneration { activating = false } }
        activationNote = nil
        errorMessage = nil
        do {
            // 网关侧激活看门狗是 180 秒，客户端给 200 秒并自动重试 2 次 ——
            // 客户不会再看到"客户端先失败、服务器随后成功"的矛盾提示。
            let authorization = try await p0.activate(card: card, deviceID: x4()) { [weak self] attempt in
                Task { @MainActor in
                    guard self?.authorizationGeneration == generation else { return }
                    self?.activationNote = "卡密服务器忙，正在自动重试（第 \(attempt) 次）"
                }
            }
            let room = authorization.grant
            guard generation == authorizationGeneration, !Task.isCancelled else { return }
            SecureStore.write(SealedStore.seal(Data(card.utf8), deviceID: x4()), account: p3)
            try SecureStore.write(p1.encode(room), account: p4)
            grant = room
            activationNote = nil
            recoveryMessage = nil
            if integrityBlocked { errorMessage = "应用完整性校验失败，已停止运行。请安装官方版本。"; activating = false; return }
            phase = .ready
            await startRelay(for: room)
            x5(for: room, serverUnix: authorization.serverUnix)
        } catch {
            guard generation == authorizationGeneration, !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
            recoveryMessage = nil
            phase = .activation
        }
        activating = false
    }

    func refreshAuthorization() async {
        guard let sealed = SecureStore.read(p3),
              let data = SealedStore.open(sealed, deviceID: x4()),
              let card = String(data: data, encoding: .utf8) else {
            phase = .activation
            return
        }
        await activate(card: card)
    }

    /// WebView 已经证明房间被回收/授权到期。立即离开“看似正常”的雷达页，
    /// 用钥匙串中的卡密向服务器重新验证，并且合并同一次失效的重复回调。
    /// 上一次自动恢复的时间 —— 用来**打断恢复循环**。
    private var lastRecoverAttempt = Date.distantPast

    func recoverDeadRoom() {
        guard p7 == nil else { return }
        // ⚠️ 冷却：这是打断"反复重新激活"死循环的关键。
        //
        // 触发源可能来自多处（到期定时器、WebView 4xx、页面文本判定），
        // 而每次恢复都会重新加载页面 → `didReportDeadRoom` 被重置 → 又能再次触发，
        // 于是变成每几秒向 /api/activate 打一次（旧网关日志里每 3 秒一条），
        // 并把正在进行的 WebView 加载取消(-999)、把转发器反复重启。
        //
        // 30 秒内只允许自动恢复一次：正常情况下一轮就够；异常情况下也不会失控。
        guard Date().timeIntervalSince(lastRecoverAttempt) > 30 else { return }
        lastRecoverAttempt = Date()

        recoveryMessage = "房间已失效，正在向服务器重新验证…"
        phase = .loading
        // 到期定时器和 WebView 4xx 可能几乎同时到达；已有一次验证在跑时
        // 只切换可见状态，不再发第二个 /api/activate。
        guard !activating else { return }
        p7 = Task { [weak self] in
            guard let self else { return }
            await self.refreshAuthorization()
            self.recoveryMessage = nil
            self.p7 = nil
        }
    }

    func forgetAuthorization() {
        authorizationGeneration &+= 1
        activating = false
        activationNote = nil
        recoveryMessage = nil
        x2()
        p8?.cancel()
        p8 = nil
        SecureStore.delete(p3)
        SecureStore.delete(p4)
        grant = nil
        errorMessage = nil
        phase = .activation
    }

    /// 回到前台：给雷达页一个"刷新一下"的信号（页面自己会重连 WebSocket）。
    @Published private(set) var foregroundTick = 0
    func markForeground() {
        foregroundTick &+= 1
        backgroundStatus = "前台运行"
        BackgroundRuntime.shared.enterForeground()
        guard let room = grant, relayRunning else { return }
        Task { [weak self] in
            guard let self else { return }
            let healthy = await LocalRelay.isHealthy()
            await self.restartRelayIfNeeded(healthy: healthy, room: room)
            await self.runProxyDiagnostics(for: self.relayGeneration)
        }
    }

    func markBackground() {
        BackgroundRuntime.shared.enterBackground(
            extensionManaged: GameTrafficController.shared.state.isConnected
        )
        backgroundStatus = BackgroundRuntime.shared.status.displayText
    }

    private func scheduleProxyDiagnostics() {
        proxyDiagnosticsTask?.cancel()
        let generation = relayGeneration
        proxyDiagnosticsTask = Task { [weak self] in
            guard let self else { return }
            await self.runProxyDiagnostics(for: generation)
        }
    }

    private func runProxyDiagnostics(for generation: UInt64) async {
        guard let result = await LocalRelay.diagnostics() else { return }
        guard !Task.isCancelled, generation == relayGeneration, LocalRelay.isRunning else { return }
        proxyDiagnostics = result
        if !result.isHealthy, let detail = result.firstFailure {
            relayError = detail
        }
    }

    /// 神明之眼 1.0：卡密验证链路已移除。
    ///
    /// 启动即构造一份本机 grant 并直接进入雷达页：
    ///   · 不请求 /api/activate，不读钥匙串卡密，不查设备绑定，不判到期；
    ///   · 雷达数据仍然全部由本机引擎（CodevMobile）解码，页面只开 127.0.0.1；
    ///   · 局域网共享（可选）与画中画能力保持原样，不依赖任何服务器。
    private func x0() async {
        grant = RoomGrant(
            roomID: "SHENMING-EYE",
            roomURL: "http://127.0.0.1:\(LocalRelay.panelPort)",
            radarURL: "http://127.0.0.1:\(LocalRelay.panelPort)",
            nodeHost: "127.0.0.1",
            nodePort: Int(LocalRelay.port),
            nodeUsername: "local",
            nodePassword: "local",
            expiresAt: "永久",
            expiresUnix: Int64(Date().timeIntervalSince1970) + 315_360_000,
            notice: "",
            sourceMode: "local"
        )
        phase = .ready
        if let grant { await startRelay(for: grant) }
    }

    /// 起本机中继：游戏设备的节点地址变成"这台手机的局域网 IP:2025"，
    /// 解析与出图全部在本机完成，不上传任何坐标。
    func startRelay(for room: RoomGrant) async {
        relayOperationID &+= 1
        let operation = relayOperationID
        relayGeneration &+= 1
        proxyDiagnosticsTask?.cancel()
        relayTimer?.cancel()
        relayTimer = nil
        proxyDiagnostics = nil
        PanelStreamMonitor.shared.stop()
        panelStreamStatus = "未开启"
        monitorState = .idle
        positionCount = 0
        lastPositionAt = nil
        // 算法服务模式：引擎负责代理与实时处理，**不需要上游节点凭据**
        // （流量从本机直出，只抓一份副本在实时算法处理）。
        lanIPAddress = LocalAddressProvider.currentIPv4()
        let controller = GameTrafficController.shared
        let restored = controller.state.isConnected ? true : await controller.restore()
        guard operation == relayOperationID, !Task.isCancelled else { return }
        let status: Int32
        if restored, let access = controller.access {
            LocalRelay.adopt(access)
            gameTrafficState = .connected
            status = 0
        } else {
            LocalRelay.stop()
            status = await LocalRelay.start(advertisedHost: lanIPAddress ?? "")
        }
        guard operation == relayOperationID, !Task.isCancelled else { return }
        if status == 0 {
            relayRunning = true
            // 引擎在跑就常驻后台音频会话：没有画中画也不会被挂起（2026-10-20 修）。
            RadarKeepAlive.shared.start()
            relayError = lanIPAddress == nil ? "没检测到局域网地址（先连上 Wi‑Fi 或开热点）" : nil
            decodePath = LocalRelay.panelURL == nil
                ? "算法服务未就绪"
                : "算法服务"
            // 诊断：直接问一次本机面板是否真的可达。
            // 这一行能一次分清两种完全不同的故障：
            //   · 面板不可达 → 引擎没在监听（跟 WebView 无关）
            //   · 面板可达   → 引擎正常，问题在 WebView 加载那一步
            Task { [weak self] in await self?.probePanel() }
            scheduleProxyDiagnostics()

            // ===== 「有没有数据在流」的信号源 =====
            // 连本机面板的 WS（和雷达页同一条），把收到的坐标帧当心跳。
            // 只连 127.0.0.1：新版不再向任何上游地址推送坐标（异地观看已移除）。
            if let panelURL = LocalRelay.panelURL, let token = LocalRelay.panelToken {
                PanelStreamMonitor.shared.onActivity = { [weak self] in
                    Task { @MainActor in self?.refreshPanelStreamReadout() }
                }
                PanelStreamMonitor.shared.start(panelURL: panelURL, panelToken: token)
                refreshPanelStreamReadout()
                #if targetEnvironment(simulator)
                startSimulatedPositionFeedIfRequested()
                #endif
            } else {
                panelStreamStatus = "未开启（缺少面板地址）"
                monitorState = .idle
            }
            // 注：不再向云端索取"会话密钥/加密字典"。
            // 2026-10-06 实测证明：能正常解码的脱机包里根本不含字段字典
            // （256 种单字节异或全试过，0 命中），说明算法服务不依赖它。
            // 该机制保护的是一份客户端用不到的资产 —— 已废弃。
        } else {
            relayRunning = false
            RadarKeepAlive.shared.stop()
            decodePath = "算法服务未就绪"
            relayError = "本机引擎启动失败（代码 \(status)）"
            panelProbe = "本机面板不可达 ✗（引擎没在监听）"
        }
        relayTimer?.cancel()
        relayTimer = Task { [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: UInt64(1.5 * 1_000_000_000)) } catch { return }
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.relayClientCount = LocalRelay.clientCount
                    self?.lanIPAddress = LocalAddressProvider.currentIPv4()
                }
                ticks += 1
                // 每 ~9 秒真发一个请求确认面板还在。界面上的"引擎未运行"就是它判出来的，
                // 所以它必须一直跑 —— 引擎内部挂掉时 `relayRunning` 这种标志位不会变。
                if ticks % 6 == 0 {
                    await self?.probePanel()
                }
                // 自愈：引擎跑着跑着可能停掉（表现为"连不上"/"房间打不开"）。
                // 不在就自动重建 —— 客户不用手动点、也不用退后台重进。
                if ticks % 7 == 0, let self, !self.isRestartingRelay {
                    let healthy = await LocalRelay.isHealthy()
                    if !healthy, !Task.isCancelled {
                        await self.restartRelayIfNeeded(healthy: false, room: room)
                    }
                }
            }
        }
    }

    /// 启动 A 的游戏流量路径。
    /// 普通全能签版本优先使用“小火箭 + 127.0.0.1:2025”，不再把
    /// Network Extension/VPN 设置页作为前置条件；带完整能力的签名包仍可
    /// 通过 GameTrafficController 恢复已有 Packet Tunnel。
    @discardableResult
    func startGameTraffic() async -> Bool {
        gameTrafficOperationID &+= 1
        let operation = gameTrafficOperationID
        guard let room = grant else { return false }
        let controller = GameTrafficController.shared
        if controller.state.isConnected { return true }

        // 普通全能签的确定性路径：算法服务负责雷达面板，
        // Shadowrocket 负责把 A 手机游戏流量送到 127.0.0.1:2025。
        // 不调用 startVPNTunnel()，避免系统跳转到一个没有 entitlement 的 VPN 设置页。
        shadowrocketFallback = true
        // 不重启已经运行的引擎：重启会重新生成 SOCKS 密码，导致用户刚复制的
        // 小火箭配置立刻失效。只有节点尚未运行时才启动一次。
        if !LocalRelay.isRunning {
            await startRelay(for: room)
        }
        guard operation == gameTrafficOperationID, !Task.isCancelled else { return false }
        guard LocalRelay.isRunning else {
            shadowrocketFallback = false
            gameTrafficError = relayError ?? "本机节点启动失败"
            gameTrafficState = .failed(gameTrafficError ?? "本机节点启动失败")
            return false
        }
        gameTrafficState = .idle
        gameTrafficError = "请在小火箭连接 127.0.0.1:\(LocalRelay.port)，再返回游戏"
        return true
    }

    func stopGameTraffic() async {
        gameTrafficOperationID &+= 1
        let operation = gameTrafficOperationID
        await GameTrafficController.shared.stop()
        guard operation == gameTrafficOperationID, !Task.isCancelled else { return }
        gameTrafficState = .idle
        gameTrafficError = nil
        shadowrocketFallback = false
        if let room = grant { await startRelay(for: room) }
    }

    /// 把转发器的真实读数搬进 @Published（界面才会随数据流动刷新）。
    private func refreshPanelStreamReadout() {
        monitorState = PanelStreamMonitor.shared.state
        positionCount = PanelStreamMonitor.shared.positionCount
        lastPositionAt = PanelStreamMonitor.shared.lastPositionAt
        panelStreamStatus = PanelStreamMonitor.shared.stateText
    }

    #if targetEnvironment(simulator)
    /// 【仅模拟器】`PHOENIX_SIM_FAKE_POSITIONS=1` 时每 0.35 秒灌一条合成坐标，
    /// 让"正在接收坐标 / 已 N 帧"那套显示在模拟器里真的动起来（真机不存在这段）。
    private func startSimulatedPositionFeedIfRequested() {
        guard ProcessInfo.processInfo.environment["PHOENIX_SIM_FAKE_POSITIONS"] == "1" else { return }
        Task { [weak self] in
            var tick: Int64 = 0
            while !Task.isCancelled {
                tick += 1
                PanelStreamMonitor.shared.debugInjectPositionBatch(captureNs: tick)
                self?.refreshPanelStreamReadout()
                try? await Task.sleep(nanoseconds: UInt64(0.35000000000000003 * 1_000_000_000))
            }
        }
    }
    #endif

    /// 面板健康探测。启动时探一次，之后由 `relayTimer` 每 ~9 秒复核一次。
    private func probePanel() async {
        let ok = await LocalRelay.isHealthy()
        panelProbe = ok
            ? "本机面板可达 ✓"
            : "本机面板不可达 ✗（引擎没在监听）"
        if !ok {
            // 只说链路层，不把面板主机、端口或令牌写进可见诊断。
            panelProbeDetail = "本地面板未响应"
        } else {
            panelProbeDetail = "本地面板已响应"
        }
    }

    // MARK: - 引擎自愈

    private var isRestartingRelay = false
    private var lastRelayRestart = Date.distantPast

    /// 引擎停掉时自动重建，带 8 秒冷却，避免"检查失败 → 重建 → 又失败"死循环。
    ///
    /// 为什么需要：引擎内部挂掉时，`LocalRelay.isRunning` 这类标志位不会变，
    /// 界面看起来一切正常，但面板已经不在监听了 —— 表现就是客户看到的
    /// "连不上 / 房间打不开，点重试没反应，退后台重进才好"。
    func restartRelayIfNeeded(healthy: Bool, room: RoomGrant) async {
        if healthy { return }
        guard !isRestartingRelay else { return }
        guard Date().timeIntervalSince(lastRelayRestart) > 8 else { return }
        isRestartingRelay = true
        lastRelayRestart = Date()
        await startRelay(for: room)
        isRestartingRelay = false
    }

    /// 游戏设备扫码用的本机节点链接
    var lanSocksLink: String? {
        guard relayRunning, let address = lanIPAddress else { return nil }
        return LocalRelay.link(address: address)
    }

    /// A 手机安装普通签名包时给小火箭导入的本机节点。
    /// 引擎监听 0.0.0.0:2025，因此同一台手机用 127.0.0.1 即可接入。
    var localSocksLink: String? {
        guard relayRunning else { return nil }
        return LocalRelay.link(address: "127.0.0.1")
    }

    /// 额外设备大屏观看用的局域网雷达地址。它只读本机面板，带令牌，
    /// 不参与 A 的游戏通道，也不出网。
    var lanRadarLink: String? {
        guard relayRunning else { return nil }
        return LocalRelay.panelPageURL?.absoluteString
    }

    private func x2() {
        relayOperationID &+= 1
        gameTrafficOperationID &+= 1
        relayGeneration &+= 1
        proxyDiagnosticsTask?.cancel()
        proxyDiagnosticsTask = nil
        proxyDiagnostics = nil
        p7?.cancel()
        p7 = nil
        relayTimer?.cancel()
        relayTimer = nil
        PanelStreamMonitor.shared.onActivity = nil
        PanelStreamMonitor.shared.stop()
        panelStreamStatus = "未开启"
        monitorState = .idle
        positionCount = 0
        lastPositionAt = nil
        panelProbe = "检测中…"
        panelProbeDetail = nil
        LocalRelay.stop()
        RadarKeepAlive.shared.stop()
        Task { await GameTrafficController.shared.stop() }
        gameTrafficState = .idle
        gameTrafficError = nil
        shadowrocketFallback = false
        relayRunning = false
        relayClientCount = 0
        lanIPAddress = nil
    }

    static func authorizationRecheckDelay(expiresUnix: Int64, serverUnix: Int64?) -> Int64? {
        if let serverUnix {
            let remaining = expiresUnix - serverUnix
            return remaining > 0 ? remaining : nil
        }
        // 响应缺 Date 时也不回退到手机时钟；最多 5 分钟后重新问服务器。
        return 300
    }

    private func x5(for grant: RoomGrant, serverUnix: Int64?) {
        p8?.cancel()
        guard let seconds = Self.authorizationRecheckDelay(
            expiresUnix: grant.expiresUnix,
            serverUnix: serverUnix
        ) else {
            grantExpiredWithoutDeletingCard()
            return
        }
        p8 = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Double(seconds) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.recoverDeadRoom()
        }
    }

    private func grantExpiredWithoutDeletingCard() {
        x2()
        grant = nil
        errorMessage = "服务器返回的授权已到期，请重新验证"
        phase = .activation
    }

    private func x4() -> String {
        if let data = SecureStore.read(p5),
           let value = String(data: data, encoding: .utf8), !value.isEmpty {
            UserDefaults.standard.set(value, forKey: p6)
            return value
        }
        if let value = UserDefaults.standard.string(forKey: p6), !value.isEmpty {
            SecureStore.write(Data(value.utf8), account: p5)
            return value
        }
        // ③ 沙盒文件：覆盖安装（同签名）不清 Application Support，重签也会保留
        if let fileValue = Self.stableDeviceIDFile(), !fileValue.isEmpty {
            UserDefaults.standard.set(fileValue, forKey: p6)
            SecureStore.write(Data(fileValue.utf8), account: p5)
            return fileValue
        }
        // 钥匙串在 iOS 上跨重装保留，正常情况下上面就已经返回了。真走到这里时
        // 用 identifierForVendor（同一台设备 + 同一发行方恒定）派生，比随机 UUID
        // 稳定：不会再出现"重装后设备号变了，卡密被判设备绑定不一致"。
        let value = UIDevice.current.identifierForVendor
            .map { "IOS-\($0.uuidString.replacingOccurrences(of: "-", with: ""))" }
            ?? UUID().uuidString.replacingOccurrences(of: "-", with: "").uppercased()
        UserDefaults.standard.set(value, forKey: p6)
        SecureStore.write(Data(value.utf8), account: p5)
        Self.writeStableDeviceIDFile(value)
        return value
    }

    private static func stableDeviceIDPath() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("device-id.txt")
    }
    static func stableDeviceIDFile() -> String? {
        guard let url = stableDeviceIDPath(),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
    static func writeStableDeviceIDFile(_ value: String) {
        guard let url = stableDeviceIDPath() else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? value.write(to: url, atomically: true, encoding: .utf8)
    }
}