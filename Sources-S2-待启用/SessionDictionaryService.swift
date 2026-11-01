import CodevMobile
import Foundation

/// S2：会话密钥 + 按会话加密的字段字典。
///
/// 职责：向云端换取短期会话密钥 → 本地解开字典 → 注入引擎 → 到期续期。
///
/// 为什么必须存在这个服务：引擎里那份字段字典是**编译期内嵌、单字节异或保护**的。
/// 只要 App 带着它跑，字典就等于明文躺在客户手机上。这个服务让引擎改用
/// **云端按会话加密下发**的字典，密钥 35 分钟轮换一次 —— 抄走密文也没用。
///
/// 安全属性（由 Rust 侧测试覆盖）：
///  · 会话密钥只存内存，不落盘、不进钥匙串；
///  · 错误密钥解不开（HMAC 校验失败）；
///  · 32 字节密钥 + 12 字节 nonce 每次下发都不同。
@MainActor
final class SessionDictionaryService {
    static let shared = SessionDictionaryService()

    /// 与引擎侧 `SESSION_TTL_SECS` 保持一致。
    static let sessionTTL: TimeInterval = 35 * 60
    /// 提前多久续期（留出网络往返与重试余地）。
    static let renewalLead: TimeInterval = 5 * 60

    enum ServiceError: LocalizedError {
        case notActivated
        case badResponse(String)
        case decryptFailed(String)

        var errorDescription: String? {
            switch self {
            case .notActivated:
                return "尚未激活，无法获取解密材料"
            case let .badResponse(detail):
                return "解密材料获取失败：\(detail)"
            case let .decryptFailed(detail):
                return "解密材料无效：\(detail)"
            }
        }
    }

    private var renewalTask: Task<Void, Never>?
    private var expiresAt: Date?
    private(set) var lastError: String?

    private init() {}

    /// 引擎当前用的是"云端下发的字典"还是"内嵌字典"。
    var isUsingCloudDictionary: Bool { codev_dictionary_is_injected() == 1 }

    /// 取一次解密材料并注入引擎；随后按 TTL 自动续期。
    func start(panelURL: URL, deviceID: String) async throws {
        try await refresh(panelURL: panelURL, deviceID: deviceID)
        scheduleRenewal(panelURL: panelURL, deviceID: deviceID)
    }

    /// 停止续期，并让引擎回退到内嵌字典（会话到期且续不上时的止损路径）。
    func stop() {
        renewalTask?.cancel()
        renewalTask = nil
        expiresAt = nil
        codev_clear_dictionary()
    }

    // MARK: - 单次刷新

    private func refresh(panelURL: URL, deviceID: String) async throws {
        let endpoint = panelURL.appendingPathComponent("api/v1/session/key")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 8
        request.httpBody = try JSONSerialization.data(withJSONObject: ["device_id": deviceID])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw ServiceError.badResponse("HTTP \(code)")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["ok"] as? Bool) == true,
              let key = object["session_key"] as? String,
              let nonce = object["nonce"] as? String,
              let blob = object["dictionary_blob"] as? String,
              let tag = object["dictionary_tag"] as? String,
              let expires = object["expires_unix"] as? NSNumber else {
            throw ServiceError.badResponse("返回字段不完整")
        }

        // 用会话密钥在本地解开字典 —— 解密材料只在内存里走一趟。
        let opened = try openDictionary(key: key, nonce: nonce, blob: blob, tag: tag)

        // 注入引擎（可重复调用：35 分钟轮换后必须重新注入）。
        let injected = opened.withCString { pointer in
            codev_set_dictionary(pointer, opened.utf8.count)
        }
        guard injected == 1 else {
            throw ServiceError.decryptFailed("注入引擎失败（返回 \(injected)）")
        }

        expiresAt = Date(timeIntervalSince1970: expires.doubleValue)
        lastError = nil
    }

    /// 调 Rust 侧的 C ABI 解字典。失败时返回的是 `{"ok":false,...}`，这里必须识别出来，
    /// **绝不能把错误 JSON 当成字典注入引擎**。
    private func openDictionary(key: String, nonce: String, blob: String, tag: String) throws -> String {
        let raw = key.withCString { k in
            nonce.withCString { n in
                blob.withCString { b in
                    tag.withCString { t in
                        codev_open_dictionary(k, n, b, t)
                    }
                }
            }
        }
        guard let raw else { throw ServiceError.decryptFailed("返回空指针") }
        let text = String(cString: raw)
        codev_engine_string_free(raw)

        if text.hasPrefix("{\"ok\":false") {
            throw ServiceError.decryptFailed(text)
        }
        return text
    }

    // MARK: - 续期

    private func scheduleRenewal(panelURL: URL, deviceID: String) {
        renewalTask?.cancel()
        let delay = max(30, Self.sessionTTL - Self.renewalLead)
        renewalTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                do {
                    try await self?.refresh(panelURL: panelURL, deviceID: deviceID)
                } catch {
                    // 续期失败：**立刻让引擎回退到内嵌字典**，而不是继续用可能已失效的旧字典。
                    // 生产上这里应同时提示用户"授权即将到期，请检查网络"。
                    self?.lastError = error.localizedDescription
                    codev_clear_dictionary()
                }
            }
        }
    }
}
