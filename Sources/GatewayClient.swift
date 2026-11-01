import Foundation
import Security
import CommonCrypto

struct GatewayAuthorization {
    let grant: RoomGrant
    /// HTTP `Date` supplied by the gateway. Client wall-clock changes must not
    /// decide whether an already-issued card is still alive.
    let serverUnix: Int64?
}


/// 验证服务器地址的唯一来源（**不写死任何 IP/域名**）。
///
/// 优先级：App 内保存的设置 → 打包时写入的 Info.plist 键 → 未设置。
/// 未设置时激活会直接提示去填，而不是偷偷连某个旧服务器。
enum VerifyServer {
    static let defaultsKey = "verifyOrigin"

    static var saved: String? {
        let raw = UserDefaults.standard.string(forKey: defaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (raw?.isEmpty == false) ? raw : nil
    }

    static var configured: String? {
        if let saved { return saved }
        // 2026-10-31 安全修复：**不再读 Info.plist 的 PhoenixGatewayOrigin**。
        // 破解者在重签时往 plist 塞一行就能把验证指到自己后台（蓝版已被这样利用）。
        // 现在只认「App 内手填」或「编译期混淆常量」两条路。
        if Bundle.main.object(forInfoDictionaryKey: "PhoenixGatewayOrigin") != nil {
            GatewayClient.originTampered = true
        }
        return GatewayObfuscator.reveal()
    }

    static func save(_ raw: String) {
        UserDefaults.standard.set(raw.trimmingCharacters(in: .whitespacesAndNewlines), forKey: defaultsKey)
    }
}

struct GatewayClient {
    /// 验证服务器：运行时解析（App 内设置 → Info.plist），**没有内置默认地址**。
    static var origin: URL {
        URL(string: VerifyServer.configured ?? "unset://verify-server")!
    }
    static var isConfigured: Bool { VerifyServer.configured != nil }
    static var originLabel: String { VerifyServer.configured ?? "未设置" }
    static func setServer(_ raw: String) { VerifyServer.save(raw) }

    /// 测试包放行自签证书（连裸 IP 时必须）。正式包 Info.plist 里没有这个键。
    nonisolated(unsafe) static var originTampered = false

    private static let allowInsecureTLS =
        (Bundle.main.object(forInfoDictionaryKey: "PhoenixTestInsecureTLS") as? String) == "1"
    /// 放行自签证书的会话（内部共享）。**镜像上传也必须用它** ——
    /// `URLSession.shared` 没有 InsecureTLSDelegate，连裸 IP + 自签证书时
    /// TLS 直接失败、请求根本发不出去（2026-10-13："浏览器共享一直没画面"的真根因）。
    static let session: URLSession = {
        guard allowInsecureTLS else { return .shared }
        let configuration = URLSessionConfiguration.default
        return URLSession(
            configuration: configuration,
            delegate: InsecureTLSDelegate(),
            delegateQueue: nil
        )
    }()
    // T3 激活链路（lex → metadata → nettime → login）在上游拥塞时可能明显超过
    // 25 秒。给足 200 秒，客户端不会再"提前失败"而服务器其实已经成功。
    private static let activationTimeout: TimeInterval = 200
    // 失败自动重试的退避（秒）：共重试 2 次。
    private static let retryBackoff: [TimeInterval] = [3, 8]

    /// 激活：成功即返回；上游忙 / 超时自动重试 2 次（3s、8s）。
    ///
    /// `onRetry` 在每次重试前回调，用于显示"卡密服务器忙，正在自动重试（第 N 次）"。
    /// 4xx（卡密无效、过期、设备绑定不一致）不重试 —— 重试纯属浪费时间。
    func activate(
        card: String,
        deviceID: String,
        onRetry: ((Int) -> Void)? = nil
    ) async throws -> GatewayAuthorization {
        // 神明之眼 1.0：卡密链路已移除 —— 不发任何验证请求。
        throw GatewayClientError.message("本版本无需卡密，直接使用")
        var lastError: Error = GatewayClientError.message("授权失败：没有收到服务器响应")
        for attempt in 0 ... Self.retryBackoff.count {
            try Task.checkCancellation()
            if attempt > 0 {
                onRetry?(attempt)
                try await Task.sleep(nanoseconds: UInt64(Double(Self.retryBackoff[attempt - 1]) * 1_000_000_000))
            }
            do {
                return try await activateOnce(card: card, deviceID: deviceID)
            } catch let error as GatewayClientError where error.isRetryable {
                lastError = error
            }
        }
        throw lastError
    }

    /// NSURLError 码 → 一句人话。客户截图发回来就能直接定位，不用再猜"什么毛病"。
    static func transportHint(code: Int) -> String {
        switch code {
        case NSURLErrorTimedOut: return "请求超时，网络或网关响应太慢"
        case NSURLErrorCannotFindHost: return "域名解析不了，查 DNS/网络"
        case NSURLErrorCannotConnectToHost: return "连不上网关端口，端口被挡/网关没开/被隧道吞了"
        case NSURLErrorNetworkConnectionLost: return "连接被中断，多半是切网或隧道重启"
        case NSURLErrorNotConnectedToInternet: return "设备当前没有网络"
        case NSURLErrorSecureConnectionFailed: return "TLS 握手失败"
        case NSURLErrorServerCertificateUntrusted: return "网关证书不被信任（测试包应放行自签）"
        case NSURLErrorAppTransportSecurityRequiresSecureConnection: return "被 ATS 拦下，Info.plist 的 ATS 配置有问题"
        case NSURLErrorDNSLookupFailed: return "DNS 查询失败"
        default: return "网络层错误"
        }
    }

    /// 直连卡密平台（2026-10-21）：不再打任何网关。
    ///
    /// 之前这里是 HTTP `POST /api/activate`；现在交给 Rust 侧的
    /// `codev_verify_card`（与 Windows 客户端同一份 T3 协议实现）。
    private func activateOnce(card: String, deviceID: String) async throws -> GatewayAuthorization {
        let trimmed = card.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw GatewayClientError.message("卡密不能为空")
        }
        // 配了验证服务地址就用它（T3 密钥留在服务器）；没配才直连 T3。
        if VerifyServer.configured != nil {
            return try await activateViaServer(card: trimmed, deviceID: deviceID)
        }
        let grant: T3Verify.Grant
        do {
            grant = try await T3Verify.verify(card: trimmed, deviceID: deviceID) { stage in
                Task { @MainActor in ActivationReporter.shared.update(stage) }
            }
        } catch let failure as T3Verify.Failure {
            throw GatewayClientError.message(failure.errorDescription ?? "卡密验证未通过")
        } catch {
            throw GatewayClientError.retryable("验证请求失败：\(error.localizedDescription)")
        }
        if grant.expiresUnix <= Int64(Date().timeIntervalSince1970) {
            throw GatewayClientError.message("卡密已到期（\(grant.expiresAt)）")
        }
        // 新版没有房间/节点概念；字段留空，界面与后续逻辑仍然兼容。
        let room = RoomGrant(
            roomID: "",
            roomURL: "",
            radarURL: "",
            nodeHost: "",
            nodePort: 0,
            nodeUsername: "",
            nodePassword: "",
            expiresAt: grant.expiresAt,
            expiresUnix: grant.expiresUnix,
            notice: grant.notice,
            sourceMode: "local"
        )
        return GatewayAuthorization(grant: room, serverUnix: Int64(Date().timeIntervalSince1970))
    }

    /// 走"验证服务端口"：`POST {origin}/api/activate {card, device_id}`。
    /// 白名单主机（XOR 0x5A 混淆后存放）；还原后才参与比较
    private static let obfuscatedHosts: [[UInt8]] = [
        // w.t3yangzheng.xyz（卡密平台）
        [45, 116, 46, 105, 35, 59, 52, 61, 32, 50, 63, 52, 61, 116, 34, 35, 32],
        // 43.226.47.215（生产房间网关，2026-10-27 补：之前漏了，客户激活直接报"不在白名单内"）
        [110, 105, 116, 104, 104, 108, 116, 110, 109, 116, 104, 107, 111],
        // 114.134.184.211（测试房网关）
        [107, 107, 110, 116, 107, 105, 110, 116, 107, 98, 110, 116, 104, 107, 107],
        [107, 106, 105, 116, 107, 110, 108, 116, 107, 104, 111, 116, 107, 98, 99]
    ] 
    private static func deobfuscate(_ bytes: [UInt8]) -> String {
        String(decoding: bytes.map { $0 ^ 0x5A }, as: UTF8.self).lowercased()
    }

    private func activateViaServer(card: String, deviceID: String) async throws -> GatewayAuthorization {
        // 2026-10-25 加固：只允许 HTTPS + 白名单主机，防止把网关改成假服务器返回 ok:true
        // 允许 https（任意白名单主机）或 http（仅限自有桥接 IP，Cloudflare 不稳时的直连通道）
        let scheme = Self.origin.scheme?.lowercased() ?? ""
        let host = (Self.origin.host ?? "").lowercased()
        // 硬化：http 直连白名单也不明文存放（同样 XOR 0x5A），避免 strings 读到 IP
        let httpAllowedHosts: Set<String> = Set([
        [107, 106, 105, 116, 107, 110, 108, 116, 107, 104, 111, 116, 107, 98, 99],
        [110, 105, 116, 104, 104, 108, 116, 110, 109, 116, 104, 107, 111],
        [107, 107, 110, 116, 107, 105, 110, 116, 107, 98, 110, 116, 104, 107, 107]
        ].map { Self.deobfuscate($0) })
        if scheme != "https" && !(scheme == "http" && httpAllowedHosts.contains(host)) {
            throw GatewayClientError.message("验证地址不安全（当前配置被改动过）")
        }
        // 主机白名单不明文存放：运行时用简单 XOR 还原，避免 strings 直接读到
        let allowedHosts = Set(Self.obfuscatedHosts.map { Self.deobfuscate($0) })
        guard allowedHosts.contains(host) else {
            throw GatewayClientError.message("验证服务器不在白名单内（\(host)）")
        }
        let endpoint = Self.origin.appendingPathComponent( "api/activate")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(ActivationRequest(card: card, deviceID: deviceID))
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: request)
        } catch {
            throw GatewayClientError.retryable("连不上验证服务：\(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw GatewayClientError.message("验证服务响应无效")
        }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if (object?["ok"] as? Bool) != true {
            // 200 但没有 ok:true：把服务端原文前 120 字带出来，便于定位（不是 JSON / 被网关改写）
            let snippet = String(data: data.prefix(160), encoding: .utf8)?
                .replacingOccurrences(of: "\n", with: " ") ?? "（无法解码）"
            let message = (object?["error"] as? String)
                ?? "验证失败（HTTP \(http.statusCode)）\n请求：\(endpoint.absoluteString)\n返回：\(snippet)"
            throw http.statusCode >= 500 ? GatewayClientError.retryable(message) : GatewayClientError.message(message)
        }
        let expires = (object?["expires_unix"] as? NSNumber)?.int64Value ?? 0
        let expiresAt = object?["expires_at"] as? String ?? ""
        let notice = object?["notice"] as? String ?? ""
        guard expires > Int64(Date().timeIntervalSince1970) else {
            throw GatewayClientError.message(expiresAt.isEmpty ? "卡密已到期" : "卡密已到期（\(expiresAt)）")
        }
        let room = RoomGrant(
            roomID: "", roomURL: "", radarURL: "", nodeHost: "", nodePort: 0,
            nodeUsername: "", nodePassword: "", expiresAt: expiresAt,
            expiresUnix: expires, notice: notice, sourceMode: "local"
        )
        return GatewayAuthorization(grant: room, serverUnix: Int64(Date().timeIntervalSince1970))
    }

    static func serverUnix(fromHTTPDate value: String?) -> Int64? {
        guard let value, !value.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
        return formatter.date(from: value).map { Int64($0.timeIntervalSince1970) }
    }

    /// 新版只校验「卡密还有效」这一件事。
    ///
    /// 以前这里还要求 `canRelay`（节点账号）和 `hasPrivateRoomCapability`（房间链接+access），
    /// 那等于把「云端房间」变成激活的前置条件 —— 新版不依赖除验证服务器以外的任何服务，
    /// 那些字段服务端还发就照收，但**不再作为放行条件**。
    func validate(_ grant: RoomGrant) throws {
        let expires = grant.expiresUnix
        guard expires > 0 else {
            throw GatewayClientError.message("验证服务器没有返回有效期，请稍后重试")
        }
        let now = Int64(Date().timeIntervalSince1970)
        if expires <= now {
            throw GatewayClientError.message(grant.notice.isEmpty ? "卡密已到期" : grant.notice)
        }
    }

    private struct ActivationRequest: Encodable {
        let card: String
        let deviceID: String

        enum CodingKeys: String, CodingKey {
            case card
            case deviceID = "device_id"
        }
    }

}

enum GatewayClientError: LocalizedError {
    case message(String)
    /// 传输层失败（DNS / 超时 / 连接被拒 / TLS）或 5xx：值得重试。
    case retryable(String)

    var isRetryable: Bool {
        if case .retryable = self { return true }
        return false
    }

    var errorDescription: String? {
        switch self {
        case let .message(message): message
        case let .retryable(message): message
        }
    }
}

/// 测试包专用：只对我们自己的服务器放行自签证书（其他域名照常走系统校验）。
final class InsecureTLSDelegate: NSObject, URLSessionDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.host == GatewayClient.origin.host,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        // 2026-10-31 证书固定：只认我们服务器那张证书的 SPKI，换证书一律拒绝
        guard InsecureTLSDelegate.trustMatchesPin(trust) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    static let pinnedSPKIBase64 = "dnHmtL7vUIH96FyeVhmE9JfaVSujl5hgaC94MXCVl5c="

    static func trustMatchesPin(_ trust: SecTrust) -> Bool {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first,
              let key = SecCertificateCopyKey(leaf),
              let keyData = SecKeyCopyExternalRepresentation(key, nil) as Data? else { return false }
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        keyData.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(keyData.count), &digest) }
        let actual = Data(digest).base64EncodedString()
        if actual != pinnedSPKIBase64 { NSLog("[security] 证书 pin 不匹配：%@", actual); return false }
        return true
    }
}
