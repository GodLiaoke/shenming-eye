import Foundation

/// 打包时写进 Info.plist 的构建标识与网关地址。
///
/// 为什么要有：客户报"激活不了"时，第一件事是确认他装的是哪一版、连的是哪台服务器。
/// 以前这两个信息在界面上完全看不到，只能靠猜（今天就被坑了一次：手机上装的其实是旧包）。
enum BuildInfo {
    static let tag: String =
        (Bundle.main.object(forInfoDictionaryKey: "PhoenixBuildTag") as? String) ?? "dev"

    static let gateway: String =
        (Bundle.main.object(forInfoDictionaryKey: "PhoenixGatewayOrigin") as? String)
        ?? "T3 直连"

    /// 界面上显示的一行：**日期 + 更新公告**（打包脚本用 `PhoenixBuildNote` 写进 Info.plist）。
    /// 例子：`正版10.27 升级绘制 大幅提高流畅度`；没注入时退回只显示日期。
    static let note: String =
        (Bundle.main.object(forInfoDictionaryKey: "PhoenixBuildNote") as? String) ?? ""

    static var shortLine: String {
        if !note.isEmpty { return note }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
}
