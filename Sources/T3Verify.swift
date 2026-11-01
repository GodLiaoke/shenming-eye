import CodevMobile
import Foundation

/// 客户端直连卡密平台（T3）——不再经过任何中间网关。
///
/// 真正的验证在 Rust 侧（`codev_verify_card`，与 Windows/桌面完全同一份协议实现），
/// Swift 只负责把卡密、设备号传进去、把结果翻成 `RoomGrant`。
///
/// 为什么放后台线程：这条链最坏要十几秒（lex → metadata → nettime → 签名登录），
/// 在主线程序列化会卡住界面，看起来就是"一直转圈"。
enum T3Verify {
    struct Grant {
        let expiresUnix: Int64
        let expiresAt: String
        let notice: String
    }

    enum Failure: LocalizedError {
        case rejected(String)
        case malformed

        var errorDescription: String? {
            switch self {
            case let .rejected(message): return message
            case .malformed: return "验证服务返回内容无法解析"
            }
        }
    }

    /// 验证卡密；`onStage` 每 300ms 回一次"现在跑到第几段"，界面直接显示。
    static func verify(
        card: String,
        deviceID: String,
        onStage: (@MainActor (String) -> Void)? = nil
    ) async throws -> Grant {
        let poller = onStage.map { callback in
            Task { @MainActor in
                while !Task.isCancelled {
                    if let raw = codev_verify_stage() {
                        callback(String(cString: raw))
                    }
                    try? await Task.sleep(nanoseconds: UInt64(0.3 * 1_000_000_000))
                }
            }
        }
        defer { poller?.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = perform(card: card, deviceID: deviceID)
                continuation.resume(with: result)
            }
        }
    }

    private static func perform(card: String, deviceID: String) -> Result<Grant, Error> {
        var output: UnsafeMutablePointer<CChar>?
        card.withCString { cardPtr in
            deviceID.withCString { devicePtr in
                output = codev_verify_card(cardPtr, devicePtr)
            }
        }
        guard let output else { return .failure(Failure.rejected("验证服务没有响应")) }
        defer { codev_engine_string_free(output) }
        let raw = String(cString: output)
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(Failure.malformed)
        }
        if (object["ok"] as? Bool) != true {
            let message = (object["error"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(Failure.rejected(message?.isEmpty == false ? message! : "卡密验证未通过"))
        }
        let expires = (object["expires_unix"] as? NSNumber)?.int64Value ?? 0
        let expiresAt = object["expires_at"] as? String ?? ""
        let notice = object["notice"] as? String ?? ""
        guard expires > 0 else { return .failure(Failure.malformed) }
        return .success(Grant(expiresUnix: expires, expiresAt: expiresAt, notice: notice))
    }
}
