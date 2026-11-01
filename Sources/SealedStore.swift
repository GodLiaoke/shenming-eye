import Foundation
import CryptoKit

/// 带 HMAC 完整性校验的存储：防止"直接往钥匙串/兜底文件里塞一个假卡密"。
///
/// 设计约束（与现有架构对齐）：
/// · 不改任何存储键名，只改变写入的字节布局：`[16字节 nonce][密文][32字节 HMAC]`
/// · 密钥 = SHA256(deviceID + 内置盐)。deviceID 本身在钥匙串里，换机就失效
/// · 校验失败一律当作"没存过"，让用户重新激活 —— 不给攻击者任何"半通过"状态
enum SealedStore {
    private static let salt = "phx.seal.v1.9f2a7c5d"
    private static let nonceLength = 16
    private static let tagLength = 32

    private static func key(deviceID: String) -> SymmetricKey {
        let material = Data((deviceID + salt).utf8)
        let digest = SHA256.hash(data: material)
        return SymmetricKey(data: Data(digest))
    }

    /// 写入：随机 nonce + XOR 流混淆 + HMAC-SHA256(nonce|payload)
    static func seal(_ payload: Data, deviceID: String) -> Data {
        var nonce = Data(count: nonceLength)
        _ = nonce.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, nonceLength, $0.baseAddress!) }
        let cipher = xor(payload, with: keystream(nonce: nonce, count: payload.count, key: key(deviceID: deviceID)))
        var out = Data()
        out.append(nonce); out.append(cipher)
        out.append(hmac(nonce: nonce, cipher: cipher, key: key(deviceID: deviceID)))
        return out
    }

    /// 读取：校验 HMAC 后才解密；任何异常返回 nil
    static func open(_ sealed: Data, deviceID: String) -> Data? {
        guard sealed.count > nonceLength + tagLength else { return nil }
        let nonce = sealed.prefix(nonceLength)
        let cipher = sealed.dropFirst(nonceLength).dropLast(tagLength)
        let tag = sealed.suffix(tagLength)
        let k = key(deviceID: deviceID)
        guard hmac(nonce: Data(nonce), cipher: Data(cipher), key: k) == Data(tag) else { return nil }
        return xor(Data(cipher), with: keystream(nonce: Data(nonce), count: cipher.count, key: k))
    }

    private static func hmac(nonce: Data, cipher: Data, key: SymmetricKey) -> Data {
        var msg = nonce; msg.append(cipher)
        return Data(HMAC<SHA256>.authenticationCode(for: msg, using: key))
    }

    /// 由 nonce+key 派生的确定性流（每块混入计数器，避免重复）
    private static func keystream(nonce: Data, count: Int, key: SymmetricKey) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(count + 32)
        var counter: UInt32 = 0
        while out.count < count {
            var block = nonce
            withUnsafeBytes(of: counter.bigEndian) { block.append(contentsOf: $0) }
            let mac = HMAC<SHA256>.authenticationCode(for: block, using: key)
            out.append(contentsOf: mac)
            counter &+= 1
        }
        return Array(out.prefix(count))
    }

    private static func xor(_ data: Data, with stream: [UInt8]) -> Data {
        var out = Data(capacity: data.count)
        var i = 0
        for byte in data { out.append(byte ^ stream[i]); i += 1 }
        return out
    }
}
