import Foundation
import Darwin

// iOS SDK 不导出 ptrace 声明，这里按公开签名自己接上（等价于 sys/ptrace.h）
@_silgen_name("_dyld_image_count")
private func cv_dyld_image_count() -> UInt32
@_silgen_name("_dyld_get_image_name")
private func cv_dyld_get_image_name(_ index: UInt32) -> UnsafePointer<CChar>?
@_silgen_name("ptrace")
private func cv_ptrace(_ request: CInt, _ pid: pid_t,
                       _ addr: UnsafeMutableRawPointer?, _ data: CInt) -> CInt
private let CV_PT_DENY_ATTACH: CInt = 31

/// 启动期安全自检（2026-10-30 硬化）
///
/// 三个动作，全部**不阻塞启动**（避免误伤 TrollStore / 自签用户）：
///  1. 关闭调试器附着：`ptrace(PT_DENY_ATTACH)` —— lldb/`frida-server` 之后无法挂上
///  2. 越狱/注入痕迹探测：常见路径与 `libcycript`/`frida` 动态库名
///  3. 结果只记录在内存里（`SecurityBoot.risk`），界面与网络行为不变
///
/// 设计原则：**检测到就降级，不闪退**。闪退会误伤正常用户，而且暴露检测点。
enum SecurityBoot {
    /// 运行期探测到的风险项（空 = 未发现）
    private(set) static var risk: [String] = []

    static func boot() {
        denyDebugger()
        probeEnvironment()
        if !risk.isEmpty {
            NSLog("[security] 环境风险：%@", risk.joined(separator: ","))
        }
    }

    /// 关掉调试器附着（Apple 私有但公开 API，不会上架审核问题，仅自签分发）
    private static func denyDebugger() {
        _ = cv_ptrace(CV_PT_DENY_ATTACH, 0, nil, 0)
    }

    private static func probeEnvironment() {
        var found: [String] = []
        // 越狱常见路径
        let paths = [
            "/Applications/Cydia.app", "/Applications/Sileo.app",
            "/private/var/lib/apt", "/usr/sbin/sshd",
            "/Library/MobileSubstrate/MobileSubstrate.dylib",
            "/etc/apt", "/bin/bash", "/usr/bin/ssh",
        ]
        for path in paths where FileManager.default.fileExists(atPath: path) {
            found.append("path:" + (path as NSString).lastPathComponent)
        }
        // 注入库：遍历已加载 image
        let suspicious = ["frida", "cycript", "substitute", "libhooker", "ellekit", "flexdecrypt"]
        for index in 0..<cv_dyld_image_count() {
            guard let cName = cv_dyld_get_image_name(index) else { continue }
            let name = String(cString: cName).lowercased()
            for needle in suspicious where name.contains(needle) {
                found.append("dylib:" + needle)
            }
        }
        // 端口探测：frida 默认 27042
        found.append(contentsOf: probeFridaPort())
        risk = Array(Set(found)).sorted()
    }

    private static func probeFridaPort() -> [String] {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(27042).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var timeout = timeval(tv_sec: 0, tv_usec: 120_000)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var ok = false
        withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                ok = connect(fd, raw, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        return ok ? ["port:27042(frida)"] : []
    }
}
