import Foundation
import NetworkExtension

/// A 手机的主链路。引擎运行在 Packet Tunnel 扩展进程中，不依赖主界面留在前台。
@MainActor
final class GameTrafficController: ObservableObject {
    static let shared = GameTrafficController()

    enum State: Equatable {
        case idle, starting, connected
        case failed(String)
        var isConnected: Bool { self == .connected }
    }

    @Published private(set) var state: State = .idle {
        didSet { onStateChanged?(state) }
    }
    private(set) var access: LocalCodeVAccess?
    var onStateChanged: ((State) -> Void)?
    private var manager: NETunnelProviderManager?
    private var statusObserver: NSObjectProtocol?
    private var operationID: UInt64 = 0

    private init() {
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange, object: nil, queue: .main
        ) { [weak self] notification in
            let connection = notification.object as? NEVPNConnection
            Task { @MainActor in
                guard let self, let connection, connection === self.manager?.connection else { return }
                switch connection.status {
                case .disconnected, .invalid:
                    if self.state == .connected {
                        self.access = nil
                        self.state = .failed("本机游戏通道已断开")
                    }
                case .reasserting:
                    self.state = .starting
                case .connected:
                    if self.access != nil { self.state = .connected }
                default: break
                }
            }
        }
    }

    /// 重进软件时恢复已有隧道，避免再起一个引擎抢占相同端口。
    func restore() async -> Bool {
        operationID &+= 1
        let operation = operationID
        do {
            let manager = try await loadManager()
            guard operation == operationID else { return false }
            guard manager.connection.status == .connected else { return false }
            self.manager = manager
            access = try await requestAccess(manager)
            state = .connected
            return true
        } catch { return false }
    }

    func start(advertisedHost: String, uploadURL: URL?) async -> Bool {
        if state.isConnected, access != nil { return true }
        guard state != .starting else { return false }
        operationID &+= 1
        let operation = operationID
        state = .starting
        do {
            let manager = try await loadManager()
            guard operation == operationID else { return false }
            self.manager = manager
            if manager.connection.status != .connected {
                let configuration = NETunnelProviderProtocol()
                configuration.providerBundleIdentifier = "com.myrader.val.codev.tunnel"
                configuration.serverAddress = "Phoenix CodeV 本机游戏通道"
                var options: [String: Any] = ["advertisedHost": advertisedHost]
                if let uploadURL { options["uploadURL"] = uploadURL.absoluteString }
                configuration.providerConfiguration = options
                manager.protocolConfiguration = configuration
                manager.localizedDescription = "Phoenix CodeV 本机游戏通道"
                manager.isEnabled = true
                manager.isOnDemandEnabled = false
                try await saveAndReload(manager)
                try manager.connection.startVPNTunnel()
                guard await waitForConnected(manager) else {
                    throw GameTrafficError.connectionTimedOut(status: manager.connection.status.rawValue)
                }
            }
            guard operation == operationID else {
                manager.connection.stopVPNTunnel()
                return false
            }
            access = try await requestAccess(manager)
            guard operation == operationID else {
                manager.connection.stopVPNTunnel()
                return false
            }
            state = .connected
            return true
        } catch {
            guard operation == operationID else { return false }
            manager?.connection.stopVPNTunnel()
            // 普通重签包可能先成功保存配置、再在启动阶段被系统拒绝。
            // 失败后移除残留配置，避免用户在设置里留下一个永远打不开的 VPN。
            if (error as NSError).domain == "NEVPNErrorDomain", let manager {
                await removeFromPreferences(manager)
            }
            access = nil
            state = .failed(Self.describe(error))
            return false
        }
    }

    func stop() async {
        operationID &+= 1
        let operation = operationID
        let currentManager = manager
        currentManager?.connection.stopVPNTunnel()
        for _ in 0..<50 {
            guard let status = currentManager?.connection.status,
                  status != .disconnected, status != .invalid else { break }
            try? await Task.sleep(nanoseconds: UInt64(0.1 * 1_000_000_000))
        }
        guard operation == operationID else { return }
        manager = nil
        access = nil
        state = .idle
    }

    private func loadManager() async throws -> NETunnelProviderManager {
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        return managers.first { manager in
            (manager.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier
                == "com.myrader.val.codev.tunnel"
        } ?? NETunnelProviderManager()
    }

    private func saveAndReload(_ manager: NETunnelProviderManager) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.saveToPreferences { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.loadFromPreferences { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    private func removeFromPreferences(_ manager: NETunnelProviderManager) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            manager.removeFromPreferences { _ in continuation.resume() }
        }
    }

    private func waitForConnected(_ manager: NETunnelProviderManager) async -> Bool {
        for _ in 0..<120 {
            if manager.connection.status == .connected { return true }
            if manager.connection.status == .invalid { return false }
            try? await Task.sleep(nanoseconds: UInt64(0.1 * 1_000_000_000))
        }
        return manager.connection.status == .connected
    }

    private func requestAccess(_ manager: NETunnelProviderManager) async throws -> LocalCodeVAccess {
        guard let session = manager.connection as? NETunnelProviderSession else {
            throw GameTrafficError.noEngineAccess
        }
        for _ in 0..<5 {
            let data: Data? = await withCheckedContinuation { continuation in
                let reply = TunnelReply(continuation)
                do {
                    try session.sendProviderMessage(Data("access".utf8)) { reply.finish($0) }
                    DispatchQueue.global().asyncAfter(deadline: .now() + 1) { reply.finish(nil) }
                } catch { reply.finish(nil) }
            }
            if let data, let payload = String(data: data, encoding: .utf8),
               let access = try? LocalCodeVEngine.parse(payload) { return access }
        }
        throw GameTrafficError.noEngineAccess
    }

    private static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == "NEVPNErrorDomain" {
            return "系统拒绝启动本机游戏通道（错误 \(nsError.code)：\(nsError.localizedDescription)）。请安装带 packet-tunnel-provider 能力的包"
        }
        return error.localizedDescription
    }

}

private final class TunnelReply: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data?, Never>?
    init(_ continuation: CheckedContinuation<Data?, Never>) { self.continuation = continuation }
    func finish(_ data: Data?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: data)
    }
}

private enum GameTrafficError: LocalizedError {
    case connectionTimedOut(status: Int), noEngineAccess
    var errorDescription: String? {
        switch self {
        case let .connectionTimedOut(status): return "本机游戏通道未进入连接状态（系统状态 \(status)），请安装带 Network Extension 能力的测试包"
        case .noEngineAccess: return "本机通道已启动，但实时算法服务未就绪"
        }
    }
}
