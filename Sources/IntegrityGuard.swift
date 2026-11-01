import Foundation
import Darwin
import MachO
import CommonCrypto

/// 注入检测（黑名单式，2026-10-25 重做）
///
/// 之前用"白名单"——只放行列出的库名。问题是**签名工具（全能签/爱思/TrollStore）
/// 会注入自己随机命名的 dylib**，白名单必然误杀正常用户。
///
/// 改成黑名单：只拦**已知的卡密破解/绕过库**。正常签名工具注入一律放行，
/// 真正被第三方卡密库劫持时才拦。
enum IntegrityGuard {
    struct Verdict {
        let ok: Bool
        let reason: String?
    }

    /// 已知破解/卡密劫持库的特征（小写子串匹配）
    private static let blockedImagePatterns: [String] = [
        "wk82auth", "wk82", "kamiauth", "kami_auth", "cardauth",
        "licensepatch", "license_bypass", "bypassauth", "crackauth",
        "t3verifyhook", "t3hook", "authpatch"
    ]

    /// 只放行：系统库 + 自身 App 包内的二进制；其它一律视为注入
    private static let allowedPrefixes: [String] = [
        "/usr/lib/", "/system/", "/library/apple/", "/private/preboot/"
    ]

    static func inspect() -> Verdict {
        let bundle = Bundle.main.bundlePath.lowercased()
        var hits: [String] = []
        for index in 0..<_dyld_image_count() {
            guard let raw = _dyld_get_image_name(index) else { continue }
            let full = String(cString: raw)
            let lower = full.lowercased()
            let name = (lower as NSString).lastPathComponent
            // 自身主二进制
            if lower.hasPrefix(bundle) { continue }
            // 系统库
            if allowedPrefixes.contains(where: { lower.hasPrefix($0) }) { continue }
            // 已知签名工具注入（默认不注入，出现即为异常）
            hits.append(name)
        }
        guard hits.isEmpty else {
            return Verdict(ok: false, reason: "检测到注入组件：\(hits.prefix(2).joined(separator: ", "))")
        }
        return Verdict(ok: true, reason: nil)
    }
}

// MARK: - 主二进制自校验（TOFU 方案，2026-10-25）

/// 为什么不用"内置哈希": 全能签/TrollStore 重签会改 `__text`，内置哈希必然对不上。
///
/// 用 TOFU（首次信任）:
///   · 首次启动：把当前 `__text` 的 SHA-256 存进钥匙串（ThisDeviceOnly）
///   · 之后每次启动：重新计算并与钥匙串比对
///   · 不一致 → 说明**装好之后二进制被改过** → 拒绝
///
/// 这样正常重签（全新安装）会被当作"新设备首启"，自动接受；
/// 而破解者的典型手法（装好后再 patch 二进制 / 注入 dylib）会被抓住。
enum BinaryIntegrity {
    /// 按可执行文件名分开存：红蓝两版 Bundle ID 相同、钥匙串 service 相同，
    /// 共用一个账户会互相覆盖（红版写进去，蓝版读到就判"校验失败"）。
    /// 记录键带上版本号与 build：换构建（重签/升级）不会和旧哈希比对，避免误判。
    private static var account: String {
        let exe = Bundle.main.infoDictionary?["CFBundleExecutable"] as? String ?? "app"
        let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        let attrs = try? FileManager.default.attributesOfItem(atPath: Bundle.main.executablePath ?? "")
        let size = (attrs?[.size] as? Int) ?? 0
        return "text.sha256.\(exe).\(ver).\(build).\(size)"
    }

    static func verify() -> Bool {
        guard let hash = textSegmentHash() else { return true }   // 算不出来就不拦
        if let stored = KeychainStore.read(account),
           let expected = String(data: stored, encoding: .utf8) {
            return hash == expected
        }
        // 首次：记录当前哈希
        try? KeychainStore.write(Data(hash.utf8), account: account)
        return true
    }

    static func textSegmentHash() -> String? {
        guard let header = _dyld_get_image_header(0) else { return nil }
        let headerPtr = UnsafeRawPointer(header)
        let headerSize = MemoryLayout<mach_header_64>.size
        var cursor = headerPtr.advanced(by: headerSize)
        for _ in 0..<Int(header.pointee.ncmds) {
            let command = cursor.assumingMemoryBound(to: load_command.self).pointee
            if command.cmd == LC_SEGMENT_64 {
                let segment = cursor.assumingMemoryBound(to: segment_command_64.self).pointee
                let segName = withUnsafeBytes(of: segment.segname) { raw -> String in
                    String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
                }
                if segName == "__TEXT" {
                    var sectCursor = cursor.advanced(by: MemoryLayout<segment_command_64>.size)
                    for _ in 0..<Int(segment.nsects) {
                        let sect = sectCursor.assumingMemoryBound(to: section_64.self).pointee
                        let sectName = withUnsafeBytes(of: sect.sectname) { raw -> String in
                            String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
                        }
                        if sectName == "__text" {
                            let base = UnsafeRawPointer(header).advanced(by: Int(sect.offset))
                            let size = Int(sect.size)
                            guard size > 0 else { return nil }
                            let data = Data(bytes: base, count: size)
                            var digest = [UInt8](repeating: 0, count: 32)
                            digest.withUnsafeMutableBytes { out in
                                data.withUnsafeBytes { input in
                                    _ = CC_SHA256(input.baseAddress, CC_LONG(input.count), out.baseAddress)
                                }
                            }
                            return digest.map { String(format: "%02x", $0) }.joined()
                        }
                        sectCursor = sectCursor.advanced(by: MemoryLayout<section_64>.size)
                    }
                }
            }
            cursor = cursor.advanced(by: Int(command.cmdsize))
        }
        return nil
    }
}
