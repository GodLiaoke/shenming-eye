import Foundation

/// 网关地址混淆（2026-10-30）
///
/// 目的：成品二进制里 `strings` 搜不到 `43.226.47.215` / `8443` 这类明文，
/// 别人拿到 IPA 也拿不到直连入口。
///
/// 做法：明文逐字节 XOR（密钥与位置相关），密文以十六进制分片分散存放，
/// 运行时按顺序拼起来再按同一算法解出明文。**不改变任何功能行为**。
enum GatewayObfuscator {
    /// 混淆后的地址片段（每个元素是十六进制密文，按序拼接后解码）
    private static let fragments: [String] = [
        "eeaba40f", "ae10ad96", "c0aa44be", "7139ebe4", "28dd520d", "379a6393", "863e",
    ]

    /// 与 encode 侧一致的密钥（seeded xorshift）
    private static func key(_ count: Int) -> [UInt8] {
        var seed = UInt64(count) &* 0x9E37_79B9_7F4A_7C15 ^ 0x0DDB_1A5E_5BAD_5EED
        var out: [UInt8] = []
        out.reserveCapacity(max(64, count))
        while out.count < max(64, count) {
            seed ^= seed << 13
            seed ^= seed >> 7
            seed ^= seed << 17
            out.append(UInt8(seed & 0xFF))
        }
        return out
    }

    /// 解出明文地址
    static func reveal() -> String {
        let hex = fragments.joined()
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            if let value = UInt8(hex[index..<next], radix: 16) { bytes.append(value) }
            index = next
        }
        let k = key(bytes.count)
        let plain = bytes.enumerated().map { UInt8($0.element ^ k[$0.offset % k.count]) }
        return String(decoding: plain, as: UTF8.self)
    }
}
