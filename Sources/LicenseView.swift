import SwiftUI
import UIKit

/// 激活页 —— 卡片 A 的入口面。
///
/// 改动要点（对应评审里的问题）：
///  · 删掉标题上方的 "PHOENIX" 装饰小字（craft-floor 明令禁止的 kicker）；
///  · 全部字号改走系统文字样式，跟随 Dynamic Type；
///  · 输入框只收 0-9 A-Z、自动大写、限 24 位并显示位数 —— 客户只需要那 24 位可见字符；
///  · 等待过程显示已用秒数 + 取消入口，不再让人以为程序卡死；
///  · 失败给具体原因与重试，不再是一次性死胡同。
struct LicenseView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var reporter = ActivationReporter.shared
    @State private var card = ""
    @State private var task: Task<Void, Never>?
    @State private var startedAt: Date?
    /// 上一次解析的结果：用来把"被丢掉的字符码位"显示出来（不再静默丢）
    @State private var lastParse: LicenseInput?
    @FocusState private var focused: Bool

    private var input: String { Self.normalize(card) }
    /// T3 侧接受 8–40 位可见字符；不再因为"不是 24 位"就把按钮锁死。
    private var ready: Bool { (8...40).contains(input.count) }

    /// 输入被改写时的提示：只报**码位**，不打印卡密本身。
    private var inputNote: String? {
        guard let parse = lastParse else { return nil }
        var parts: [String] = []
        if parse.truncated { parts.append("有效字符超过 24 位，已取前 24 位") }
        if !parse.droppedCodePoints.isEmpty {
            var unique: [UInt32] = []
            for code in parse.droppedCodePoints where !unique.contains(code) { unique.append(code) }
            let codes = unique.map { String(format: "U+%04X", $0) }.joined(separator: "、")
            parts.append("已忽略 \(parse.droppedCodePoints.count) 个非字母数字字符（\(codes)）—— 卡密按可见字母数字校验，忽略的不影响验证")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        ZStack {
            PhoenixBackground()
            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: 44)
                    PhoenixMark(size: 96)

                    Text("神明之眼")
                        .font(PhoenixType.display)
                        .foregroundStyle(.primary)
                        .padding(.top, 20)

                    Text("无畏契约 · 实时雷达")
                        .font(PhoenixType.body)
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)

                    panel
                        .padding(.horizontal, 20)
                        .padding(.top, 34)

                    Spacer(minLength: 32)
                }
            }
        }
    }

    // MARK: - 输入面板

    private var panel: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("输入卡密")
                    .font(PhoenixType.section)
                    .foregroundStyle(.primary)
                Text("24 位字母和数字，大小写不限")
                    .font(PhoenixType.caption)
                    .foregroundStyle(.secondary)
            }

            field

            // 主按钮必须**一直可见**：之前只有键盘上的 → 和失败后的「重试」，
            // 客户输完卡密找不到能点的地方（2026-10-21 实拍反馈）。
            Button {
                start()
            } label: {
                HStack(spacing: 8) {
                    if model.activating { ProgressView().tint(.white) }
                    Text(model.activating ? "正在验证…" : "开始验证")
                        .font(PhoenixType.section)
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: 50)
                .foregroundStyle(model.activating || ready ? Color.white : Color.white.opacity(0.45))
                .background(
                    LinearGradient(
                        colors: [PhoenixTheme.accent, PhoenixTheme.warm],
                        startPoint: .leading, endPoint: .trailing
                    ),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
                .opacity(model.activating || ready ? 1 : 0.5)
            }
            .buttonStyle(.plain)
            .disabled(!ready || model.activating)
            .accessibilityIdentifier("activate-primary")

            if model.activating {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .foregroundStyle(PhoenixStatus.waiting)
                    Text(reporter.stage.isEmpty ? "正在验证…" : "正在验证 · \(reporter.stage)")
                        .font(PhoenixType.caption)
                        .foregroundStyle(PhoenixStatus.waiting)
                }
            }

            if let note = model.activationNote, model.activating {
                Label(note, systemImage: "arrow.triangle.2.circlepath")
                    .font(PhoenixType.caption)
                    .foregroundStyle(PhoenixStatus.waiting)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let error = model.errorMessage, !model.activating {
                VStack(alignment: .leading, spacing: 8) {
                    Label(error, systemImage: "exclamationmark.circle.fill")
                        .font(PhoenixType.caption)
                        .foregroundStyle(PhoenixStatus.offline)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("重试") { start() }
                        .font(PhoenixType.captionStrong)
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 44)
                        .glassCapsule()
                        .buttonStyle(.plain)
                }
            }

            Divider().overlay(PhoenixTheme.hairline)

            VStack(alignment: .leading, spacing: 6) {
                Label("授权只绑定当前设备，换机需要重新验证", systemImage: "lock.shield")
                    .font(PhoenixType.caption)
                    .foregroundStyle(.secondary)
                // 客服排障用：客户念这一行就知道装的是哪一版、连的哪台服务器
                Text(BuildInfo.shortLine)
                    .font(PhoenixType.monoSmall)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(20)
        .glassPanelElevated(cornerRadius: 22)
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(PhoenixTheme.hairline, lineWidth: 1)
        )
    }

    private var field: some View {
        HStack(spacing: 10) {
            Image(systemName: "key.fill")
                .font(PhoenixType.body)
                .foregroundStyle(.secondary)

            TextField("粘贴或输入卡密", text: $card)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .textContentType(.oneTimeCode)
                .font(PhoenixType.mono)
                .foregroundStyle(.primary)
                .keyboardType(.asciiCapable)
                .submitLabel(.go)
                .focused($focused)
                .disabled(model.activating)
                .onSubmit { if ready { start() } }

            // 输入框右侧的黄色字数提示：满 24 位高亮，提示"够了，可以点验证"
            Text("\(card.count)/24")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(card.count == 24 ? Color.yellow : Color.yellow.opacity(0.55))
                .monospacedDigit()
                .accessibilityLabel("已输入 \(card.count) 位，共 24 位")
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("首次验证通常需要 30–90 秒，请保持 App 在前台、不要锁屏。")
                .font(PhoenixType.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button("取消") { cancel() }
                .font(PhoenixType.captionStrong)
                .foregroundStyle(.primary)
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .glassCapsule()
                .buttonStyle(.plain)
        }
    }

    // MARK: - 动作

    private func start() {
        guard ready, !model.activating else { return }
        focused = false
        model.errorMessage = nil
        startedAt = Date()
        let value = input
        task = Task { await model.activate(card: value) }
    }

    private func cancel() {
        task?.cancel()
        task = nil
        startedAt = nil
        model.errorMessage = "已取消。可以修改卡密后重新验证。"
    }

    /// 卡密解析结果：规范值 + **被丢掉了什么**（关键：不许静默丢字符）。
    struct LicenseInput: Equatable {
        /// 规范后的卡密（只含 0-9A-Z，最多 24 位）
        var value: String
        /// 粘贴进来的原始字符数
        var originalLength: Int
        /// 被丢掉的字符码位（按出现顺序，含重复）
        var droppedCodePoints: [UInt32]
        /// 有效字符超过 24 位被截断
        var truncated: Bool
    }

    /// 卡密规范化。
    ///
    /// 官方卡密的真身是 24 位可见字符 + 4 个由网关重算补回的不可见字符，
    /// 客户端只收可见部分；零宽字符与空格丢掉。
    ///
    /// ⚠️ 旧实现是 `filter { isASCII && isLetter || isNumber }` 后**静默** `prefix(24)`：
    /// 只要卡密里混进 1~2 个全角字符（微信/短信/第三方输入法复制出来极常见：
    /// `Ａ`=U+FF21、`１`=U+FF10），就会被整块吃掉 —— 客户看到的是
    /// "24 位粘进去只剩 22 位"，而且界面上没有任何提示。
    /// 现在：先按**宽度/兼容**折叠成半角（全角→半角是确定映射，可以放心做），
    /// 再过滤，并把丢弃的码位报给界面显示。
    static func parse(_ raw: String) -> LicenseInput {
        // 恢复官方原版逻辑（与蓝色版一致）：宽度/兼容折叠 → 只留 ASCII 字母数字 → 取前 24 位
        let folded = raw.folding(options: [.widthInsensitive, .diacriticInsensitive], locale: nil)
        var kept = ""
        var dropped: [UInt32] = []
        for scalar in folded.unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
                kept.unicodeScalars.append(scalar)
            } else {
                dropped.append(scalar.value)
            }
        }
        let upper = kept.uppercased()
        return LicenseInput(value: String(upper.prefix(24)),
                            originalLength: raw.count,
                            droppedCodePoints: dropped,
                            truncated: upper.count > 24)
    }

    static func normalize(_ raw: String) -> String { parse(raw).value }

    /// 常见同形字 → ASCII（只做确定的一对一映射，不做任何猜测）。
    static let homoglyphMap: [Character: Character] = [
        "А": "A", "В": "B", "Е": "E", "К": "K", "М": "M", "Н": "H", "О": "O",
        "Р": "P", "С": "C", "Т": "T", "У": "Y", "Х": "X", "І": "I", "Ј": "J",
        "а": "A", "е": "E", "о": "O", "р": "P", "с": "C", "у": "Y", "х": "X",
        "Α": "A", "Β": "B", "Ε": "E", "Ζ": "Z", "Η": "H", "Ι": "I", "Κ": "K",
        "Μ": "M", "Ν": "N", "Ο": "O", "Ρ": "P", "Τ": "T", "Υ": "Y", "Χ": "X",
    ]
}
