import Foundation

struct RoomGrant: Codable, Equatable {
    let roomID: String
    let roomURL: String
    let radarURL: String
    let nodeHost: String
    let nodePort: Int
    let nodeUsername: String
    let nodePassword: String
    let expiresAt: String
    let expiresUnix: Int64
    let notice: String
    let sourceMode: String

    enum CodingKeys: String, CodingKey {
        case roomID = "room_id"
        case roomURL = "room_url"
        case radarURL = "radar_url"
        case nodeHost = "node_host"
        case nodePort = "node_port"
        case nodeUsername = "node_username"
        case nodePassword = "node_password"
        case expiresAt = "expires_at"
        case expiresUnix = "expires_unix"
        case notice
        case sourceMode = "source_mode"
    }

    var canRelay: Bool {
        sourceMode == "proxy" && !nodeHost.isEmpty
            && (1...Int(UInt16.max)).contains(nodePort)
            && !nodeUsername.isEmpty && !nodePassword.isEmpty
    }

    var socksLink: String {
        var components = URLComponents()
        components.scheme = "socks5"
        components.host = nodeHost
        components.port = nodePort
        components.user = nodeUsername
        components.password = nodePassword
        return components.url?.absoluteString
            ?? "socks5://\(nodeUsername):\(nodePassword)@\(nodeHost):\(nodePort)"
    }
}

extension RoomGrant {
    /// 这份凭据是不是**当前服务器**签发的。
    ///
    /// 为什么必须有：老版本（旧部署/140 那批）把 grant 存在同一个钥匙串条目里，
    /// 新客户端启动时会把老凭据读回来 → 侧栏节点显示 140、雷达页也去连老服务器。
    /// 2026-10-04 老板就是踩了这个（新包显示 140 的节点）。
    var matchesCurrentGateway: Bool {
        guard let host = URL(string: radarURL)?.host ?? URL(string: roomURL)?.host else { return false }
        return host == GatewayClient.origin.host
    }
}

struct GatewayErrorPayload: Decodable {
    let error: String?
}
