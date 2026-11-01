import SwiftUI
import UIKit

/// **主界面 = 先选使用方式，再配置与连接。**
///
/// ## 它和"连接面板"的关系（旧版是一件事，现在拆成两件）
/// 旧版把连接面板做成一个 sheet，从雷达页底部那条状态带上推出来 ——
/// 于是"配置"和"看雷达"挤在同一屏，两边都不好：状态带吃掉 60pt，面板打开后
/// 雷达还在下面继续画（白烧电），客户在面板里改完还得手动关掉才看得到雷达。
///
/// 现在：**开局前看到的就是这一页**，它回答三个问题 ——
///   ① 现在通没通（顶部状态面）；
///   ② 当前模式怎么用（只有选定模式后才显示对应节点二维码）；
///   ③ 出问题去哪看（引擎健康 + 折叠的诊断）。
/// 配完按底部那颗「雷达」进全屏，之后整局都不用再回来。
///
/// ## 视觉语言
/// 「控制台」而不是「状态墙」：一张主卡（配对）吃满宽度、上下两组窄卡（状态 / 引擎健康），
/// 每张卡只有一条 1px 描边和一层极淡的内高光，靠**间距**而不是靠色块分组。
/// 青蓝只出现在"可以按的东西"上：模式按钮、节点二维码框、复制动作。
struct MainConsoleView: View {
    @EnvironmentObject private var model: AppModel
    let grant: RoomGrant
    let pip: PiPPump
    /// 主界面上的画中画入口需要真正的 WKWebView（爬帧用）——
    /// 全屏雷达那颗在 `RadarContainerView` 里直接拿得到，这里由外面传进来。
    let webBox: WebViewBox
    var onEnterRadar: () -> Void
    /// 一键进入当前选定模式：单机模式预热画中画，双机模式只进入雷达。
    var onEnterSelectedMode: () -> Void
    var onOpenConnection: () -> Void
    var onStartConnection: () -> Void

    @State private var toast: String?
    @State private var selectedMode: RadarUsageMode?
    @AppStorage("phoenix.usageMode") private var storedMode = ""

    private var flow: AppModel.DataFlow { model.dataFlow }

    /// 本机引擎/面板可用，允许用户进入雷达看“等待本机游戏流量”空状态。
    private var engineReady: Bool {
        switch flow {
        case .waiting, .streaming: return true
        case .starting, .fault: return false
        }
    }

    /// 本机已经有坐标流。不能用 `engineReady` 代替，否则引擎空闲时会误报“已连接”。
    private var deviceConnected: Bool {
        if case .streaming = flow { return true }
        return false
    }

    private var capabilities: RadarCapabilitySnapshot {
        RadarCapabilitySnapshot(
            flow: flow,
            panelStreamStatus: model.panelStreamStatus,
            pipSupported: RadarPiPController.isSupported,
            pipActive: pip.isActive,
            usageMode: selectedMode ?? .singleDevice
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 14) {
                    tacticalHeader
                    RadarModeChooser(selectedMode: selectedMode, onSelect: selectMode)
                    if let selectedMode {
                        ModeGuideCard(mode: selectedMode)
                        localRadarHero
                        capabilityStrip
                        ModeNodeCard(mode: selectedMode)
                        LanShareButton(toast: $toast)
                        Button(action: onOpenConnection) {
                            HStack(spacing: 8) {
                                Image(systemName: "slider.horizontal.3")
                                Text("连接详情与排障")
                                    .font(PhoenixType.captionStrong)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 14)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("打开连接状态、代理自检和授权操作")
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 12)
                // 底部启动栏固定在 ScrollView 外；把它的 56pt 高度和安全区留在内容里，
                // 最后一张卡滚到底时不会被启动栏压住。
                .padding(.bottom, 112)
            }

            if selectedMode != nil { tacticalLauncher }
        }
        .background(PhoenixBackground())
        .overlay(alignment: .bottom) { toastOverlay }
        .onAppear {
            guard selectedMode == nil,
                  let mode = RadarUsageMode(rawValue: storedMode) else { return }
            selectedMode = mode
            model.selectUsageMode(mode)
        }
    }

    private func selectMode(_ mode: RadarUsageMode) {
        withAnimation(.easeInOut(duration: 0.22)) {
            selectedMode = mode
            model.selectUsageMode(mode)
            storedMode = mode.rawValue
        }
        // PiP 是本机模式专属能力；切到双机时立即关掉旧小窗，
        // 同时撤销可能残留的系统游戏通道状态。
        if mode == .dualDevice {
            pip.stop()
            Task { await model.stopGameTraffic() }
        }
    }

    private var tacticalHeader: some View {
        HStack(alignment: .top, spacing: 12) {
            PhoenixMark(size: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text("神明之眼 / 本机雷达")
                    .font(PhoenixType.monoSmall)
                    .foregroundStyle(PhoenixTheme.accent)
                Text("战术雷达")
                    .font(.system(size: 34, design: .rounded).weight(.bold))
                    .foregroundStyle(.primary)
                Text("实时算法 · 低延迟 · 浏览器共享按需开启")
                    .font(PhoenixType.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Text(BuildInfo.shortLine)
                .font(PhoenixType.monoSmall)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.trailing)
                .lineLimit(3)
                .minimumScaleFactor(0.75)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("神明之眼 战术雷达。实时算法，低延迟，浏览器共享按需开启")
    }

    private var localRadarHero: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                SignalLamp(level: flow.lampLevel, size: 13)
                Text("本机雷达")
                    .font(PhoenixType.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("LOCAL")
                    .font(PhoenixType.monoSmall)
                    .foregroundStyle(PhoenixTheme.accent)
            }
            HStack(spacing: 8) {
                Image(systemName: deviceConnected ? "checkmark.seal.fill" : "link.badge.plus")
                    .foregroundStyle(deviceConnected ? PhoenixTheme.signalGo : PhoenixTheme.signalWait)
                Text(connectionBadgeTitle)
                    .font(PhoenixType.statusLine)
                    .foregroundStyle(deviceConnected ? PhoenixTheme.signalGo : PhoenixTheme.signalWait)
                Spacer()
                Text(connectionBadgeDetail)
                    .font(PhoenixType.captionStrong)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .background(
                (deviceConnected ? PhoenixTheme.signalGo : PhoenixTheme.warm).opacity(0.10),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            Text(capabilities.localTitle)
                .font(.system(size: 22, design: .rounded).weight(.bold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Text(localDetail)
                .font(PhoenixType.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [PhoenixTheme.consoleGlow, PhoenixTheme.panel.opacity(0.96)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(PhoenixTheme.consoleStroke, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("本机雷达，\(capabilities.localTitle)。\(localDetail)")
    }

    private var localDetail: String {
        if model.shadowrocketFallback {
            return "普通签名模式：请让小火箭连接 127.0.0.1:\(LocalRelay.port)，再回到游戏"
        }
        switch flow {
        case .streaming:
            return "游戏通道已启用 · 算法服务正在出图 · 已收到 \(model.positionCount) 帧"
        case .waiting:
            return "节点已就绪 · 进入对应模式后，坐标会自动出现"
        case .starting:
            return "正在连接节点 · 连接成功后才能进入雷达"
        case .fault:
            return model.relayError ?? "节点连接失败 · 打开连接详情重试"
        }
    }

    private var capabilityStrip: some View {
        HStack(spacing: 8) {
            ForEach(capabilities.capabilityChips, id: \.title) { chip in
                CapabilityChip(chip: chip)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var tacticalLauncher: some View {
        HStack(spacing: 10) {
            Button(action: engineReady ? onEnterSelectedMode : onStartConnection) {
                HStack(spacing: 10) {
                    Image(systemName: engineReady ? "gamecontroller.fill" : "link.badge.plus")
                        .font(.system(size: 20, weight: .bold))
                    Text(engineReady ? launcherTitle : "启动节点")
                        .font(.system(size: 17, design: .rounded).weight(.bold))
                    Spacer(minLength: 6)
                    Text(launcherDetail)
                        .font(PhoenixType.captionStrong)
                        .opacity(0.72)
                    Image(systemName: engineReady ? (selectedMode == .singleDevice ? "pip.enter" : "arrow.right") : "arrow.clockwise")
                        .font(.system(size: 12, weight: .bold))
                }
                .foregroundStyle(Color.white)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 56)
                .background(
                    engineReady
                        ? AnyShapeStyle(LinearGradient(colors: [PhoenixTheme.accent, PhoenixTheme.auroraViolet], startPoint: .topLeading, endPoint: .bottomTrailing))
                        : AnyShapeStyle(LinearGradient(colors: [PhoenixTheme.auroraViolet, PhoenixTheme.auroraPink], startPoint: .topLeading, endPoint: .bottomTrailing)),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(engineReady ? launcherTitle : "启动节点")
            .accessibilityHint(engineReady ? launcherHint : "先启动算法服务")

            if selectedMode == .singleDevice && RadarPiPController.isSupported {
                Button { pip.toggle(webView: webBox.webView) } label: {
                    Image(systemName: pip.isActive ? "pip.exit" : "pip.enter")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(pip.isActive ? PhoenixTheme.signalGo : Color.primary)
                        .frame(width: 56, height: 56)
                        .glassPanel(cornerRadius: 18)
                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(PhoenixTheme.hairline, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(pip.isActive ? "退出画中画" : "画中画")
                .accessibilityHint("在其他 App 上方继续查看本机雷达")
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 10)
        .background(
            LinearGradient(colors: [.clear, PhoenixTheme.background], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .bottom)
        )
    }

    private var connectionBadgeTitle: String {
        if model.shadowrocketFallback { return "等待小火箭接管游戏" }
        switch flow {
        case .streaming: return "本机游戏通道已启用"
        case .waiting: return "本机游戏通道尚未启动"
        case .starting: return "正在连接节点"
        case .fault: return "节点连接失败"
        }
    }

    private var connectionBadgeDetail: String {
        if model.shadowrocketFallback { return "127.0.0.1:\(LocalRelay.port)" }
        switch flow {
        case .streaming: return "坐标正在进入"
        case .waiting: return "点击进入游戏模式"
        case .starting: return "连接成功后进入"
        case .fault: return "打开连接详情"
        }
    }

    private var launcherDetail: String {
        if !engineReady { return "连接成功后进入" }
        if selectedMode == .dualDevice { return model.lanIPAddress.map { "B 设备连接 \($0)" } ?? "等待局域网地址" }
        if model.shadowrocketFallback { return "小火箭已就绪" }
        return deviceConnected ? "全屏低延迟" : "等待游戏流量"
    }

    private var launcherTitle: String {
        selectedMode == .dualDevice ? "进入双机雷达" : "进入本机雷达"
    }

    private var launcherHint: String {
        selectedMode == .dualDevice
            ? "打开 A 手机雷达，B 手机通过节点运行游戏"
            : "进入雷达并预热画中画，然后切换到横屏游戏"
    }

    // MARK: - 顶栏

    /// 顶栏只放"这是什么"：品牌标记 + 名字，右边一行构建/服务器标识。
    /// 不放状态 —— 状态在下面那张状态面上，一个界面里只允许有一处说"通没通"。
    /// 顶栏只放"这是什么"：品牌标记 + 名字；右边一行构建/服务器标识。
    /// 不放状态 —— 状态在下面那张状态面上，一个界面里只允许有一处说"通没通"。
    ///
    /// 构建标识（给客服念的那一行）有两种摆法，由 `ViewThatFits` 按**系统量出来的尺寸**选：
    ///   · 常规字号：贴着右边缘一行（省高度）；
    ///   · 辅助功能大字号：挪到副标题下面单独一行（不截断、不挤压标题）。
    /// 上一版在辅助功能大字号下被截成"构建 dev · …"，而排障恰恰要靠这一行。
    private var header: some View {
        Group {
            HStack(alignment: .center, spacing: 10) {
                brandBlock
                Spacer(minLength: 8)
                buildLine
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .center, spacing: 10) {
                    brandBlock
                    Spacer(minLength: 0)
                }
                buildLine.padding(.leading, 40)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }

    private var brandBlock: some View {
        HStack(alignment: .center, spacing: 10) {
            PhoenixMark(size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("神明之眼")
                    .font(PhoenixType.title)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("无畏契约 · 实时雷达")
                    .font(PhoenixType.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// ⚠️ 不写 `fixedSize()`：那一行在辅助功能大字号下比屏幕还宽，
    /// 会把整张卡顶出屏幕（实测）。这里允许它自己换行 / 按比例缩一点，
    /// 宁可占两行 —— 排障时要念的就是这一行，截断等于没有。
    private var buildLine: some View {
        Text(BuildInfo.shortLine)
            .font(PhoenixType.monoSmall)
            .foregroundStyle(.tertiary)
            .lineLimit(2)
            .minimumScaleFactor(0.7)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - 底部：进入全屏雷达

    /// 这一条是整个 App 里**第二重要**的东西（第一是雷达本身），所以：
    /// 通栏一颗 56pt 高的主按钮，青蓝描边 + 极淡的青蓝底，右边挂画中画。
    /// 它不属于滚动区 —— 任何时候都在手指底下。
    private var launcher: some View {
        HStack(spacing: 10) {
            Button(action: onEnterRadar) {
                HStack(spacing: 10) {
                    RadarGlyph(size: 22, color: PhoenixTheme.accent)
                    Text("雷达")
                        .font(.system(size: 17, design: .rounded).weight(.semibold))
                    Spacer(minLength: 6)
                    Text("全屏")
                        .font(PhoenixType.caption)
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 56)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(PhoenixTheme.accent.opacity(0.13))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(PhoenixTheme.accent.opacity(0.42), lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("进入全屏雷达")
            .accessibilityHint("地图铺满整屏，视图和目标控制收在网页控制抽屉里")

            if RadarPiPController.isSupported {
                Button {
                    pip.toggle(webView: webBox.webView)
                } label: {
                    Image(systemName: pip.isActive ? "pip.exit" : "pip.enter")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(pip.isActive ? PhoenixTheme.signalGo : Color.primary)
                        .frame(width: 56, height: 56)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(.ultraThinMaterial)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .strokeBorder(PhoenixTheme.hairline, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(pip.isActive ? "退出画中画" : "画中画")
                .accessibilityHint("先进雷达，再从左下角画中画按钮打开小窗")
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 10)
        .background(
            LinearGradient(
                colors: [PhoenixTheme.background.opacity(0), PhoenixTheme.background],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .bottom)
        )
    }

    @ViewBuilder
    private var toastOverlay: some View {
        if let toast {
            Text(toast)
                .font(PhoenixType.captionStrong)
                .foregroundStyle(.primary)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.bottom, 84)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .allowsHitTesting(false)
        }
    }
}

private struct CapabilityChip: View {
    let chip: RadarCapabilityChip

    private var isPrimary: Bool { chip.emphasis == .primary }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Circle()
                    .fill(isPrimary ? PhoenixTheme.accent : PhoenixTheme.muted.opacity(0.75))
                    .frame(width: 6, height: 6)
                Text(chip.title)
                    .font(PhoenixType.captionStrong)
                    .foregroundStyle(isPrimary ? .primary : .secondary)
                    .lineLimit(1)
            }
            if isPrimary {
                Text(chip.value)
                    .font(PhoenixType.monoSmall)
                    .foregroundStyle(PhoenixTheme.accent)
                    .lineLimit(2)
                    .minimumScaleFactor(0.78)
            } else {
                Text(chip.value)
                    .font(PhoenixType.monoSmall)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.78)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isPrimary ? PhoenixTheme.accent.opacity(0.12) : PhoenixTheme.ink.opacity(0.05),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isPrimary ? PhoenixTheme.accent.opacity(0.34) : PhoenixTheme.hairline, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(chip.title)：\(chip.value)")
    }
}

/// 首页第一步：让用户先选清楚自己是哪种设备关系。
private struct RadarModeChooser: View {
    let selectedMode: RadarUsageMode?
    let onSelect: (RadarUsageMode) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("先选择使用方式")
                .font(PhoenixType.section)
                .foregroundStyle(.primary)
            Text("选定后才会显示对应教程和节点配置")
                .font(PhoenixType.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                ForEach(RadarUsageMode.allCases) { mode in
                    Button { onSelect(mode) } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Image(systemName: mode == .singleDevice ? "iphone" : "rectangle.2.swap")
                                .font(.system(size: 22, weight: .semibold))
                            Text(mode.title)
                                .font(PhoenixType.callout)
                            Text(mode.subtitle)
                                .font(PhoenixType.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .foregroundStyle(selectedMode == mode ? Color.white : .primary)
                        .frame(maxWidth: .infinity, minHeight: 108, alignment: .topLeading)
                        .padding(14)
                        .background(
                            selectedMode == mode
                                ? AnyShapeStyle(LinearGradient(colors: [PhoenixTheme.accent, PhoenixTheme.auroraViolet], startPoint: .topLeading, endPoint: .bottomTrailing))
                                : AnyShapeStyle(PhoenixTheme.ink.opacity(0.05)),
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .strokeBorder(selectedMode == mode ? PhoenixTheme.accent : PhoenixTheme.hairline, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(mode.title)
                    .accessibilityHint(mode.subtitle)
                }
            }
        }
        .padding(16)
        .glassPanelElevated(cornerRadius: 22)
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(PhoenixTheme.hairline, lineWidth: 1))
    }
}

/// 选择模式后才出现的教程，文案直接回答“谁玩游戏、谁看雷达”。
private struct ModeGuideCard: View {
    let mode: RadarUsageMode

    private var steps: [String] {
        switch mode {
        case .singleDevice:
            return [
                "1. 在本机小火箭中连接 127.0.0.1:2025",
                "2. 返回 Phoenix，点击“进入本机雷达”",
                "3. 横屏进入游戏，需要时开启画中画"
            ]
        case .dualDevice:
            return [
                "1. A 手机启动节点并保持 Phoenix 运行",
                "2. B 手机小火箭导入下面的双机节点",
                "3. B 手机进入游戏，A 手机打开雷达查看"
            ]
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: mode == .singleDevice ? "bolt.horizontal.circle.fill" : "arrow.left.arrow.right.circle.fill")
                    .foregroundStyle(PhoenixTheme.accent)
                Text(mode.guideTitle)
                    .font(PhoenixType.section)
                    .foregroundStyle(.primary)
                Spacer()
                Text(mode == .singleDevice ? "单设备" : "A / B 设备")
                    .font(PhoenixType.monoSmall)
                    .foregroundStyle(.secondary)
            }
            ForEach(steps, id: \.self) { step in
                HStack(alignment: .top, spacing: 8) {
                    Circle().fill(PhoenixTheme.accent).frame(width: 6, height: 6).padding(.top, 6)
                    Text(step)
                        .font(PhoenixType.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text(mode == .singleDevice
                ? "本模式支持画中画；不需要第二台手机。"
                : "本模式不使用画中画；A 手机是雷达端，B 手机是游戏端。")
                .font(PhoenixType.captionStrong)
                .foregroundStyle(PhoenixTheme.accent)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [PhoenixTheme.consoleGlow, PhoenixTheme.panel], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(PhoenixTheme.consoleStroke, lineWidth: 1))
    }
}

/// 模式专属节点二维码。浏览器雷达不再使用二维码。
private struct ModeNodeCard: View {
    @EnvironmentObject private var model: AppModel
    let mode: RadarUsageMode
    @State private var copied = false

    private var link: String? {
        mode == .singleDevice ? model.localSocksLink : model.lanSocksLink
    }

    private var nodeTitle: String {
        mode == .singleDevice ? "本机小火箭节点" : "双机游戏节点"
    }

    private var nodeHint: String {
        mode == .singleDevice
            ? "用于本机小火箭连接；不需要第二台手机"
            : "请用 B 手机的小火箭扫描或导入此节点"
    }

    private var addressText: String {
        if mode == .singleDevice { return "127.0.0.1:\(String(LocalRelay.port))" }
        if let address = model.lanIPAddress { return "\(address):\(String(LocalRelay.port))" }
        return "等待局域网地址"
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "qrcode")
                    .foregroundStyle(PhoenixTheme.accent)
                Text(nodeTitle)
                    .font(PhoenixType.section)
                Spacer()
                Text("节点配置")
                    .font(PhoenixType.monoSmall)
                    .foregroundStyle(.secondary)
            }
            Text(nodeHint)
                .font(PhoenixType.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let link {
                QRCodeView(text: link, size: 176)
                    .padding(12)
                    .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .accessibilityLabel("\(nodeTitle)二维码")
                    .accessibilityHint(nodeHint)
            } else {
                HStack(spacing: 10) {
                    ProgressView().tint(PhoenixTheme.accent)
                    Text(model.relayError ?? "正在准备节点…")
                        .font(PhoenixType.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 70)
                .glassPanel(cornerRadius: 16)
            }

            HStack(spacing: 10) {
                Text(addressText)
                    .font(PhoenixType.mono)
                    .foregroundStyle(PhoenixTheme.accent)
                    .textSelection(.enabled)
                Spacer()
                Button {
                    guard let link else { return }
                    UIPasteboard.general.string = link
                    withAnimation(.easeOut(duration: 0.18)) { copied = true }
                    Task {
                        try? await Task.sleep(nanoseconds: UInt64(1.3 * 1_000_000_000))
                        await MainActor.run { withAnimation(.easeOut(duration: 0.18)) { copied = false } }
                    }
                } label: {
                    Label(copied ? "已复制" : "复制配置", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(PhoenixType.captionStrong)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(PhoenixTheme.accent)
                .disabled(link == nil)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .glassPanel(cornerRadius: 20)
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(PhoenixTheme.hairline, lineWidth: 1))
    }
}

/// 局域网共享雷达：只复制链接（同 Wi-Fi 可用，不出网）。
private struct LanShareButton: View {
    @EnvironmentObject private var model: AppModel
    @Binding var toast: String?

    var body: some View {
        Button {
            guard let link = model.lanRadarShareLink else { return }
            UIPasteboard.general.string = link.absoluteString
            withAnimation { toast = "局域网雷达链接已复制：同一个 Wi-Fi 的其它设备用浏览器打开即可" }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(2.2 * 1_000_000_000))
                withAnimation { toast = nil }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "wifi")
                VStack(alignment: .leading, spacing: 2) {
                    Text("局域网共享雷达").font(PhoenixType.section)
                    Text("同一个WIFI下才可访问 延迟为0 不可异地")
                        .font(PhoenixType.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "doc.on.doc").foregroundStyle(PhoenixTheme.accent)
            }
            .foregroundStyle(.primary)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PhoenixTheme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(PhoenixTheme.accent.opacity(0.30), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(model.lanRadarShareLink == nil)
        .accessibilityIdentifier("lan-radar")
        .accessibilityHint("把局域网雷达链接复制到剪贴板，同一个 Wi-Fi 的设备可直接打开")
    }
}

// MARK: - 引擎健康（真实信号，不编造）

/// 引擎健康卡：**只显示 App 真的观测到的东西**。
///
/// 三行分别来自三条独立的真实信号：
///   · 本机引擎 —— `LocalRelay.isHealthy()` 真发一次 HTTP 探测（`panelProbe`）；
///   · 坐标流   —— `PanelStreamMonitor` 读的就是雷达页同一条 WS 的帧计数。
/// 「已接入设备台数」**永远不显示**：引擎没有等价的瞬时 gauge（`relayClientCount` 恒为 0）。
struct EngineHealthCard: View {
    @EnvironmentObject private var model: AppModel
    let flow: AppModel.DataFlow
    var onOpenConnection: () -> Void

    private var engineOK: Bool {
        if case .fault = flow { return false }
        return true
    }

    private var engineText: String {
        switch flow {
        case .starting: return "启动中"
        case .waiting: return "运行中"
        case .streaming: return "运行中"
        case .fault: return model.relayError ?? "未运行"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            row(
                title: "本机引擎",
                value: engineText,
                level: engineOK ? .go : .fault
            )
            divider
            row(
                title: "坐标流",
                value: flow.isStreaming ? "已收到 \(model.positionCount) 帧" : "等待中",
                level: flow.isStreaming ? .go : (engineOK ? .waiting : .fault)
            )
            divider

            Button(action: onOpenConnection) {
                HStack {
                    Text("连接详情与配对步骤")
                        .font(PhoenixType.captionStrong)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("打开完整的连接面板")
        }
        .glassPanel(cornerRadius: 20)
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(PhoenixTheme.hairline, lineWidth: 1)
        )
    }

    private func row(title: String, value: String, level: SignalLamp.Level) -> some View {
        HStack(spacing: 10) {
            SignalLamp(level: level, size: 10)
            Text(title)
                .font(PhoenixType.callout)
                .foregroundStyle(.primary)
            Spacer(minLength: 10)
            Text(value)
                .font(PhoenixType.counter)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
        .accessibilityValue(value)
    }

    private var divider: some View {
        Divider().overlay(PhoenixTheme.hairline).padding(.leading, 38)
    }
}

// MARK: - 连接详情（配对步骤 / 诊断 / 危险动作）

/// 「连接详情」—— 从主界面的引擎健康卡点进来，也可以单独当一页用。
///
/// 它是旧 `ConnectionSheet` 的正文，但**去掉了"状态墙"的部分**：
/// 状态面、二维码、复制节点都已经在主界面上常驻了，这里只留
/// 「四步配对清单（含 App 观测不到的那两步的诚实说明）」+「诊断」+「危险动作」。
struct ConnectionConsole: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let grant: RoomGrant

    @State private var toast: String?
    @State private var showingRevokeConfirm = false

    private var flow: AppModel.DataFlow { model.dataFlow }

    var body: some View {
        ZStack {
            PhoenixBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ConnectionStatusBanner(flow: flow)

                    SetupChecklist(
                        steps: steps,
                        // 只在真的收到坐标时才说这句 —— 它是一个从观测事实推出来的结论，
                        // 不是"我们觉得你应该已经做完了"。
                        footnote: flow.isStreaming
                            ? "已经收到坐标：本机游戏通道正在工作。"
                            : nil
                    )

                    LanShareButton(toast: $toast)

                    DiagnosticsDisclosure(rows: diagnostics)

                    Button(role: .destructive) {
                        showingRevokeConfirm = true
                    } label: {
                        Text("解除本机授权")
                            .font(PhoenixType.callout)
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(PhoenixTheme.signalFault)
                }
                .padding(.horizontal, 18)
                .padding(.top, 16)
                // 底部留白放在内容里而不是 ScrollView 上：内容短到不用滚动时，
                // 最后一个按钮才不会贴着 home indicator（回收站手势区）。
                .padding(.bottom, 52)
            }
        }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(PhoenixType.captionStrong)
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 14)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .confirmationDialog(
            "解除本机授权？",
            isPresented: $showingRevokeConfirm,
            titleVisibility: .visible
        ) {
            Button("解除授权", role: .destructive) {
                dismiss()
                model.forgetAuthorization()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("解除后需要重新输入卡密才能使用。卡密本身不会被作废。")
        }
    }

    /// 四步清单。**每一步的状态都必须来自本机真实的观测**，观测不到的不许打勾。
    ///
    /// 本机能真正知道的只有两件事：
    ///   ① 引擎起没起、面板可不可达 —— `panelProbe`（真发请求探的）；
    ///   ② 有没有坐标在流 —— `PanelStreamMonitor` 读的就是雷达页同一条 WS。
    /// A 的游戏通道由系统 Network Extension 返回 connected 后才算成功；
    /// 额外设备观看只走局域网地址（不出网），不是主链路前置条件。
    private var steps: [SetupChecklist.Step] {
        let engineOK: Bool
        if case .fault = flow { engineOK = false } else { engineOK = true }
        let streaming = flow.isStreaming

        return [
            .init(
                id: 1,
                title: "本机引擎已启动",
                detail: engineOK ? nil : (model.relayError ?? "引擎没有运行，正在自动重试"),
                state: engineOK ? .observed("已启动") : .observedFault("未运行")
            ),
            .init(
                id: 2,
                title: model.shadowrocketFallback ? "小火箭游戏通道" : "本机游戏通道已连接",
                detail: model.shadowrocketFallback
                    ? "在小火箭连接 127.0.0.1:\(String(LocalRelay.port))，App 无法代替小火箭报告 VPN 状态"
                    : (model.gameTrafficError ?? "点击首页“进入游戏模式”后由系统建立"),
                state: model.shadowrocketFallback
                    ? .observedWaiting("待小火箭连接")
                    : (model.gameTrafficState.isConnected ? .observed("已连接") : .observedWaiting("未启动"))
            ),
            .init(
                id: 3,
                title: "可选：额外设备打开局域网雷达",
                detail: "同一 Wi‑Fi 下扫码或打开局域网地址，不影响 A 自己玩游戏",
                state: .instruction
            ),
            .init(
                id: 4,
                title: "A 横屏进入游戏",
                detail: streaming ? nil : "进入对局后坐标会实时出现在 PiP 雷达上",
                state: streaming ? .observed("正在接收") : .observedWaiting("等待中")
            ),
        ]
    }

    /// 折叠的诊断：这几行是**排障时唯一能看清现场的东西**（历史踩过"静默回退云端"的坑），
    /// 但它们是给客服和研发看的，不是给打游戏的客户看的。收起 = 还在，只是不占视线。
    private var diagnostics: [(String, String)] {
        var rows: [(String, String)] = [
            ("算法服务", model.decodePath),
            ("本机面板", model.panelProbe),
            ("本机中继", model.relayRunning ? "运行中" : "未运行"),
            ("后台状态", model.backgroundStatus),
            ("构建", BuildInfo.shortLine),
        ]
        if let proxy = model.proxyDiagnostics {
            let layers: [(String, ProxyDiagnosticsSnapshot.Layer)] = [
                ("监听", proxy.listener),
                ("SOCKS 握手", proxy.socksHandshake),
                ("DNS", proxy.dns),
                ("TCP", proxy.tcp),
                ("UDP", proxy.udp),
            ]
            for (name, layer) in layers {
                rows.append(("代理 · \(name)", layer.ok ? "正常 · \(layer.detail)" : "失败 · \(layer.detail)"))
            }
            if let interfaceSummary = proxy.interfaceSummary {
                rows.append(("出口接口", interfaceSummary))
            }
        }
        if let detail = model.panelProbeDetail {
            rows.append(("面板状态", detail))
        }
        return rows
    }

    private func copy(_ text: String, message: String) {
        UIPasteboard.general.string = text
        withAnimation { toast = message }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(1.4 * 1_000_000_000))
            withAnimation { toast = nil }
        }
    }
}
