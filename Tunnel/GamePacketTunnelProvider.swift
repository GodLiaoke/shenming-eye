import CodevMobile
import Darwin
import Foundation
import NetworkExtension

/// 单机链路完全驻留在扩展进程：系统 IP 包 → tun2proxy → 实时算法代理。
/// 代理出口由扩展发出，不经主 App 的 VPN 再绕回自身；不上传任何坐标。
final class GamePacketTunnelProvider: NEPacketTunnelProvider {
    private var bridgeFD: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var writeSuspended = true
    private var outputBuffer = Data()
    private var pendingInput = Data()
    private var accessPayload: Data?
    private let ioQueue = DispatchQueue(label: "com.phoenix.val.game-tunnel.io")
    private var sessionID: UInt64 = 0
    private var startCompletion: ((Error?) -> Void)?
    private var startFinishedID: UInt64?

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        let configuration = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration ?? [:]
        let host = configuration["advertisedHost"] as? String ?? "127.0.0.1"
        ioQueue.async {
            self.sessionID &+= 1
            let sessionID = self.sessionID
            self.startCompletion = completionHandler
            self.startFinishedID = nil
            do {
                let directory = try FileManager.default.url(for: .applicationSupportDirectory,
                    in: .userDomainMask, appropriateFor: nil, create: true)
                    .appendingPathComponent("GameTunnel", isDirectory: true)
                guard let raw = codev_engine_start(directory.path, host) else { throw TunnelError.engineFailed }
                let payload = String(cString: raw)
                codev_engine_string_free(raw)
                guard let object = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
                      object["ok"] as? Bool == true,
                      let username = object["username"] as? String,
                      let password = object["password"] as? String,
                      let token = object["panelToken"] as? String,
                      let rawURL = object["panelURL"] as? String,
                      let panelURL = URL(string: rawURL) else { throw TunnelError.engineFailed }
                self.accessPayload = Data(payload.utf8)
                var fds = [Int32](repeating: 0, count: 2)
                guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw TunnelError.socketPairFailed }
                let result = codev_tunnel_start(fds[0], username, password)
                // -2 表示 Rust 尚未接管 fd；其它失败码表示 Rust 已经接管并
                // 负责关闭它。这样不会在 from_std 失败时双重 close。
                guard result == 0 else {
                    if result == -2 { close(fds[0]) }
                    close(fds[1])
                    throw TunnelError.bridgeFailed
                }
                self.bridgeFD = fds[1]
                guard fcntl(self.bridgeFD, F_SETFL, fcntl(self.bridgeFD, F_GETFL) | O_NONBLOCK) == 0 else {
                    throw TunnelError.bridgeFailed
                }
                // A peer shutdown must be an error, not a SIGPIPE terminating the extension.
                var noSignal: Int32 = 1
                setsockopt(self.bridgeFD, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
                self.setTunnelNetworkSettings(Self.networkSettings()) { error in
                    self.ioQueue.async {
                        guard self.sessionID == sessionID else { return }
                        if let error {
                            self.stopBridge()
                            self.finishStart(sessionID, error: error)
                            return
                        }
                        self.startPacketFlowBridge()
                        Task { @MainActor in
                            PanelStreamMonitor.shared.start(panelURL: panelURL, panelToken: token)
                        }
                        self.finishStart(sessionID, error: nil)
                    }
                }
            } catch {
                self.stopBridge()
                self.finishStart(sessionID, error: error)
            }
        }
    }

    /// 主 App 通过系统 IPC 取扩展的当前凭据；不把凭据写进共享磁盘或 UI。
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        ioQueue.async {
            completionHandler?(messageData == Data("access".utf8) ? self.accessPayload : nil)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        ioQueue.async {
            self.sessionID &+= 1
            if let pending = self.startCompletion {
                self.startCompletion = nil
                pending(TunnelError.cancelled)
            }
            self.stopBridge()
            completionHandler()
        }
    }

    /// `setTunnelNetworkSettings` completes asynchronously. A stop/restart can
    /// arrive before that callback; only the matching session may publish a
    /// running bridge or call the start completion.
    private func finishStart(_ sessionID: UInt64, error: Error?) {
        guard self.sessionID == sessionID, startFinishedID != sessionID else { return }
        startFinishedID = sessionID
        let completion = startCompletion
        startCompletion = nil
        completion?(error)
    }

    private static func networkSettings() -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "10.55.0.1")
        let ipv4 = NEIPv4Settings(addresses: ["10.55.0.2"], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        ipv4.excludedRoutes = [
            NEIPv4Route(destinationAddress: "127.0.0.0", subnetMask: "255.0.0.0"),
            NEIPv4Route(destinationAddress: "10.0.0.0", subnetMask: "255.0.0.0"),
            NEIPv4Route(destinationAddress: "172.16.0.0", subnetMask: "255.240.0.0"),
            NEIPv4Route(destinationAddress: "192.168.0.0", subnetMask: "255.255.0.0"),
        ]
        let ipv6 = NEIPv6Settings(addresses: ["fd55::2"], networkPrefixLengths: [64])
        ipv6.includedRoutes = [NEIPv6Route.default()]
        ipv6.excludedRoutes = [
            NEIPv6Route(destinationAddress: "::1", networkPrefixLength: 128),
            NEIPv6Route(destinationAddress: "fc00::", networkPrefixLength: 7),
            NEIPv6Route(destinationAddress: "fe80::", networkPrefixLength: 10),
        ]
        settings.ipv4Settings = ipv4
        settings.ipv6Settings = ipv6
        settings.dnsSettings = NEDNSSettings(servers: ["1.1.1.1", "8.8.8.8"])
        settings.mtu = 1500
        return settings
    }

    private func startPacketFlowBridge() {
        let fd = bridgeFD
        let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: ioQueue)
        reader.setEventHandler { [weak self] in self?.drainOutputFrames() }
        reader.setCancelHandler { close(fd) }
        readSource = reader
        let writer = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: ioQueue)
        writer.setEventHandler { [weak self] in self?.flushInputFrames() }
        writeSource = writer // remains suspended until the first queued packet
        writeSuspended = true
        reader.resume()
        readPacketsFromSystem()
    }

    private func readPacketsFromSystem() {
        guard bridgeFD >= 0 else { return }
        packetFlow.readPackets { [weak self] packets, _ in
            guard let self else { return }
            self.ioQueue.async {
                guard self.bridgeFD >= 0 else { return }
                for packet in packets {
                    guard (20...65_535).contains(packet.count) else { continue }
                    guard self.pendingInput.count + packet.count + 4 <= 4 * 1024 * 1024 else {
                        self.cancelTunnelWithError(TunnelError.bridgeFailed)
                        return
                    }
                    var length = UInt32(packet.count).bigEndian
                    self.pendingInput.append(Data(bytes: &length, count: 4))
                    self.pendingInput.append(packet)
                }
                if !self.pendingInput.isEmpty, self.writeSuspended {
                    self.writeSuspended = false
                    self.writeSource?.resume()
                }
                self.readPacketsFromSystem()
            }
        }
    }

    private func flushInputFrames() {
        while bridgeFD >= 0, !pendingInput.isEmpty {
            let count = pendingInput.withUnsafeBytes { Darwin.write(bridgeFD, $0.baseAddress, $0.count) }
            if count > 0 { pendingInput.removeFirst(count); continue }
            if count < 0, errno == EINTR { continue }
            if count < 0, errno == EAGAIN || errno == EWOULDBLOCK { return }
            cancelTunnelWithError(TunnelError.bridgeFailed)
            return
        }
        if !writeSuspended { writeSource?.suspend(); writeSuspended = true }
    }

    private func drainOutputFrames() {
        guard bridgeFD >= 0 else { return }
        var bytes = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = Darwin.read(bridgeFD, &bytes, bytes.count)
            if count > 0 { outputBuffer.append(contentsOf: bytes.prefix(count)); continue }
            if count < 0, errno == EINTR { continue }
            if count < 0, errno == EAGAIN || errno == EWOULDBLOCK { break }
            cancelTunnelWithError(TunnelError.bridgeFailed)
            return
        }
        while outputBuffer.count >= 4 {
            let length = outputBuffer.withUnsafeBytes { Int(UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self))) }
            guard (20...65_535).contains(length) else { cancelTunnelWithError(TunnelError.bridgeFailed); return }
            guard outputBuffer.count >= length + 4 else { return }
            let start = outputBuffer.startIndex
            let packet = Data(outputBuffer[(start + 4)..<(start + length + 4)])
            outputBuffer.removeFirst(length + 4)
            let version = packet.first.map { $0 >> 4 } ?? 4
            packetFlow.writePackets([packet], withProtocols: [NSNumber(value: version == 6 ? AF_INET6 : AF_INET)])
        }
    }

    /// Always called on ioQueue: no descriptor can be closed while another callback uses it.
    private func stopBridge() {
        if let writer = writeSource {
            if writeSuspended { writer.resume() }
            writer.cancel()
        }
        if let reader = readSource { reader.cancel() }
        else if bridgeFD >= 0 { close(bridgeFD) }
        readSource = nil
        writeSource = nil
        bridgeFD = -1
        accessPayload = nil
        pendingInput.removeAll()
        outputBuffer.removeAll()
        Task { @MainActor in PanelStreamMonitor.shared.stop() }
        codev_tunnel_stop()
        codev_engine_stop()
    }
}

private enum TunnelError: LocalizedError {
    case engineFailed, socketPairFailed, bridgeFailed, cancelled
    var errorDescription: String? {
        switch self {
        case .engineFailed: return "算法服务启动失败"
        case .socketPairFailed: return "本机游戏通道无法创建数据桥"
        case .bridgeFailed: return "本机游戏数据桥已断开"
        case .cancelled: return "本机游戏通道已取消"
        }
    }
}
