import Foundation

/// 本机面板数据流监视器（原 `MirrorForwarder` 去掉「上传」之后的样子）。
///
/// 只做一件事：连本机引擎面板的那条 WebSocket，数坐标帧，回答界面
/// "现在到底有没有数据在流"。
///
/// ## 为什么保留这个类
/// 雷达页渲染靠的就是这条 WS；界面上的"已收到 N 帧"必须是**真实观测**，
/// 不能靠计时器假装。删掉转发逻辑后，它仍然是"数据在流"的唯一可信来源。
///
/// ## 它绝不联网
/// 只连 `ws://127.0.0.1:<面板端口>/api/v1/ws`。异地观看（把坐标 POST 到云端房间）
/// 已整体移除 —— 新版除卡密验证外不依赖任何服务器。
@MainActor
final class PanelStreamMonitor {
    static let shared = PanelStreamMonitor()

    /// 多久没收到任何消息就认为连接没建起来
    private static let connectWatchdog: TimeInterval = 8

    /// 界面用状态。每一档都对应一个**可分辨的真实情况**，不做模糊描述。
    enum State: Equatable {
        case idle
        case connecting
        case waitingForMatch
        case streaming(frames: Int)
        case failed(String)

        var text: String {
            switch self {
            case .idle:
                return "未开启"
            case .connecting:
                return "连接中"
            case .waitingForMatch:
                return "已连本地，等待坐标（进游戏开一局新的）"
            case let .streaming(frames):
                return "正常（已收到 \(frames) 帧）"
            case let .failed(reason):
                return "异常：\(reason)"
            }
        }
    }

    private(set) var state: State = .idle
    var stateText: String { state.text }

    /// 本机 WS 每收到一条消息就 +1 —— 界面据此判断连接是否还活着。
    private(set) var messageCount = 0
    /// 收到的 **坐标** 条数（只数 `position_delta`，会话/快照类消息不计）。
    private(set) var positionCount = 0
    /// 最近一次收到坐标的时间；3 秒没有新坐标就不再算"正在流动"。
    private(set) var lastPositionAt: Date?
    /// WS 是否处于已建连状态（收过任意消息即为真；断开时清掉）。
    private(set) var isSocketOpen = false

    /// 每条消息到达时回调（按 ~100ms 节流，避免 SwiftUI 每秒重排 20 次）。
    var onActivity: (() -> Void)?
    private var lastActivityNotify = Date.distantPast

    private var socketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var webSocketSession: URLSession?

    private init() {}

    /// 界面用：现在这一刻是否真的有坐标在流。
    var isStreamingNow: Bool {
        guard let lastPositionAt else { return false }
        return Date().timeIntervalSince(lastPositionAt) < 3
    }

    // MARK: - 启停

    /// 连上本机面板的广播。
    /// - Parameters:
    ///   - panelURL: 本机面板地址（引擎返回的 `panelURL`）
    ///   - panelToken: 本机面板令牌（引擎返回的 `panelToken`）
    func start(panelURL: URL, panelToken: String) {
        stop()
        guard let wsURL = Self.webSocketURL(from: panelURL, token: panelToken) else {
            state = .failed("本机面板地址无效")
            return
        }
        state = .connecting

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        let session = URLSession(configuration: configuration)
        webSocketSession = session

        // 服务端校验 Origin 必须与 Host 一致；原生客户端默认不发这个头，要显式给
        var request = URLRequest(url: wsURL)
        request.setValue(Self.origin(for: panelURL), forHTTPHeaderField: "Origin")

        let task = session.webSocketTask(with: request)
        socketTask = task
        task.resume()
        receive(task)
        startWatchdog()
    }

    func stop() {
        receiveTask?.cancel(); receiveTask = nil
        socketTask?.cancel(with: .goingAway, reason: nil); socketTask = nil
        webSocketSession?.invalidateAndCancel(); webSocketSession = nil
        messageCount = 0
        positionCount = 0
        lastPositionAt = nil
        isSocketOpen = false
        state = .idle
    }

    // MARK: - 收本地坐标

    private func receive(_ task: URLSessionWebSocketTask) {
        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let message = try await task.receive()
                    guard let self, !Task.isCancelled else { return }
                    let data: Data? = switch message {
                    case let .data(value): value
                    case let .string(value): value.data(using: .utf8)
                    @unknown default: nil
                    }
                    if let data { self.accept(message: data) }
                } catch {
                    guard let self, !Task.isCancelled else { return }
                    self.isSocketOpen = false
                    self.state = .failed("本机连接断开：\(error.localizedDescription)")
                    self.notifyActivity(force: true)
                    return
                }
            }
        }
    }

    /// 收到一条本地广播。只认 `position_delta` 的坐标帧；其余消息只用来判断"连着"。
    private func accept(message: Data) {
        guard state != .idle else { return }
        isSocketOpen = true
        messageCount += 1
        if state == .connecting { state = .waitingForMatch }

        guard let object = try? JSONSerialization.jsonObject(with: message) as? [String: Any],
              object["kind"] as? String == "position_delta",
              let payload = object["payload"] as? [String: Any],
              let positions = payload["positions"] as? [[String: Any]],
              !positions.isEmpty
        else {
            notifyActivity()
            return
        }

        positionCount += 1
        lastPositionAt = Date()
        state = .streaming(frames: positionCount)
        notifyActivity()
    }

    private func notifyActivity(force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastActivityNotify) >= 0.1 else { return }
        lastActivityNotify = now
        onActivity?()
    }

    /// 看门狗：连上后迟迟没有任何消息时把状态说清楚，不要永远停在"连接中"。
    private func startWatchdog() {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Double(Self.connectWatchdog) * 1_000_000_000))
            guard let self, self.state == .connecting else { return }
            self.state = .failed("本机连接超时（\(Int(Self.connectWatchdog)) 秒无响应）")
            self.notifyActivity(force: true)
        }
    }

    #if targetEnvironment(simulator)
    /// 【仅模拟器】灌一条合成的坐标消息，用来在没有游戏机的机器上验证
    /// "有数据在流"那套显示（状态灯、帧数、清单打勾）真的会动。
    func debugInjectPositionBatch(captureNs: Int64) {
        let payload = """
        {"kind":"position_delta","capture_ns":\(captureNs),\
        "payload":{"positions":[{"x":1.0,"y":2.0}]}}
        """
        accept(message: Data(payload.utf8))
    }
    #endif

    // MARK: - 地址构造

    private static func webSocketURL(from panelURL: URL, token: String) -> URL? {
        guard var components = URLComponents(url: panelURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.scheme = panelURL.scheme == "https" ? "wss" : "ws"
        components.path = "/api/v1/ws"
        components.queryItems = [URLQueryItem(name: "token", value: token)]
        return components.url
    }

    /// 与服务端 `Host` 完全一致的 Origin 值。
    private static func origin(for url: URL) -> String {
        let scheme = url.scheme ?? "http"
        let host = url.host ?? "127.0.0.1"
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        let isDefault = (scheme == "https" && port == 443) || (scheme == "http" && port == 80)
        return isDefault ? "\(scheme)://\(host)" : "\(scheme)://\(host):\(port)"
    }
}
