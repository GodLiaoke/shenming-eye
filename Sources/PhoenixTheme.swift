import SwiftUI

/// 设计系统 v3（2026-10-09 · 主界面 / 全屏雷达两界面重构）。
///
/// ## 这一版为什么改
/// v2 的世界是「雷达全屏 + 一条常驻状态带」。它解决了"客户看不出通没通"，
/// 但结构上仍然是**一屏里既画雷达又放原生 chrome**：状态带占掉 60pt，
/// 雷达页自己也还留着一条顶栏 —— 两边都在抢地图的地方。
///
/// v3 把职责彻底分开：
///   · **主界面（MainConsoleView）= 配置与连接**，只在开局前用一次；
///   · **全屏雷达（RadarStageView）= 只有雷达**，整局 30 分钟一直看。
/// 于是雷达页上的原生元素只剩状态点、画中画入口，其余控制全部交给网页抽屉。
///
/// ## 颜色分工（本世界的核心规则，改代码前先读这一段）
/// - **烈焰红 `accent`** 只属于「App 提供的动作与信息」：按钮、二维码框、卡密计数达标、
///   主界面的仪表标签。它**不表示连接状态** —— 雷达画面本身就有红橙色块，
///   用同一个颜色表达状态，余光扫过去分不清"这是 UI 还是数据"。
/// - **信号灯三色 `signalGo` / `signalWait` / `signalFault`** 只表示连接状态，
///   取自路由器面板上的指示灯语汇：绿=有数据在流、琥珀=在等、红=坏了。
///   雷达页上它被压到最小：一颗 9pt 的点，形状跟着状态一起变
///   （实心圆 / 空心环 / 实心方），色觉障碍用户读形状就能读出状态。
enum PhoenixTheme {
    /// 不死鸟·烈焰红：近黑底 + 烈焰红主色，红/橙承担层级与动作，绿/琥珀/玫红承担真实连接状态。
    /// 所有原生页面都只从这里取色，避免每个页面再各自拼一套单调的蓝。
    /// 神明之眼 1.0 · 白色液态玻璃皮。
    ///
    /// 底色是**纸白**（近白微冷），层级靠三件事表达：
    ///   ① 半透明白面板 + `.ultraThinMaterial`（真材质模糊，背后光晕会透上来）
    ///   ② 1px 的**镜面描边**（左上更亮、右下更淡，模拟玻璃棱边受光）
    ///   ③ 极轻的墨色投影（白底上没有阴影就没有厚度）
    /// 与旧红黑版共享同一批 token 名：所有页面不用改代码就换了皮。
    static let background = Color(red: 0.937, green: 0.949, blue: 0.973)   // #EFF2F8
    static let backgroundRaised = Color(red: 0.976, green: 0.984, blue: 0.996)
    /// 面板 = 半透明白（配合玻璃修饰器时是它的"染色层"）。
    static let panel = Color.white.opacity(0.58)
    static let panelRaised = Color.white.opacity(0.80)
    /// 主色：墨蓝。白底上要有足够对比，金色只做点缀。
    static let accent = Color(red: 0.169, green: 0.192, blue: 0.376)        // #2B3160
    static let violet = Color(red: 0.486, green: 0.404, blue: 0.965)        // #7C67F6
    static let auroraViolet = Color(red: 0.451, green: 0.439, blue: 0.965)  // #7370F6
    static let auroraPink = Color(red: 0.945, green: 0.541, blue: 0.776)    // #F18AC6
    static let warm = Color(red: 0.902, green: 0.729, blue: 0.361)          // 神金 #E6BA5C
    static let cyan = Color(red: 0.443, green: 0.780, blue: 0.965)          // #71C7F6
    /// 文字：墨色。所有 `.primary`/`.secondary` 在浅色方案下由系统给出，这里是显式取色口。
    static let text = Color(red: 0.078, green: 0.090, blue: 0.145)          // #141725
    static let ink = Color(red: 0.078, green: 0.090, blue: 0.145)
    static let muted = Color(red: 0.427, green: 0.459, blue: 0.529)         // #6D7587
    /// 分隔线/描边：浮动元素用 `hairline`，静态分组用系统 `separator`。
    static let hairline = Color(red: 0.078, green: 0.090, blue: 0.145).opacity(0.10)
    /// 全屏雷达上那两件原生控件共用的"玻璃"底色 —— 浮在深色地图上，保持半透明白。
    static let hudGlass = Color.white.opacity(0.34)
    /// 控制台英雄卡的低亮度光晕；不把雷达地图的青色误当成连接状态。
    static let consoleGlow = auroraViolet.opacity(0.20)
    static let consoleStroke = accent.opacity(0.16)

    // MARK: - 信号灯（只表示连接状态）

    /// 有数据在流。
    static let signalGo = Color(red: 0.078, green: 0.639, blue: 0.412)     // #14A369
    /// 在等（引擎好了但还没数据 / 正在启动）。
    static let signalWait = Color(red: 0.847, green: 0.549, blue: 0.078)   // #D88C14
    /// 坏了（引擎未启动、面板不可达、转发异常）。
    static let signalFault = Color(red: 0.878, green: 0.231, blue: 0.341)  // #E03B57
    /// 危险/错误色。macOS 端历史上叫 `danger`（MacRootView 用它），
    /// 这里留一个别名 —— 之前 macOS target 因为找不到 `danger` **编译不过**，
    /// 而它的构建脚本把 xcodebuild 输出丢进了 /dev/null，所以一直没被发现。
    static let danger = signalFault
    /// 未点亮的灯位：保留色相、压到几乎没有亮度，只提示"这里有一个灯"。
    static func lampOff(_ color: Color) -> Color { color.opacity(0.16) }
    /// 点亮灯位的外发光，透明度克制（深色底上不能糊成一团）。
    static func lampGlow(_ color: Color) -> Color { color.opacity(0.45) }
}

/// 字号体系：全部走系统文字样式，跟随 Dynamic Type（HIG：不要写死 pt）。
enum PhoenixType {
    static let display = Font.system(size: 34, design: .rounded).weight(.bold)
    static let title = Font.system(size: 22, design: .rounded).weight(.bold)
    static let section = Font.system(size: 17, design: .rounded)
    /// 主界面上那句状态 —— 全界面唯一需要"余光可读"的文字，用 `.subheadline` 加粗。
    static let statusLine = Font.system(size: 15, design: .rounded).weight(.semibold)
    static let body = Font.system(.subheadline)
    static let callout = Font.system(.callout).weight(.medium)
    static let caption = Font.system(.caption)
    static let captionStrong = Font.system(.caption).weight(.semibold)
    static let mono = Font.system(size: 12, design: .monospaced).weight(.semibold)
    static let monoSmall = Font.system(size: 11, design: .monospaced)
    /// 会自己跳动的计数（位置数、秒数）：等宽数字，位数变化时整行不抖。
    static let counter = Font.system(size: 15, design: .rounded)
        .weight(.semibold)
        .monospacedDigit()
}

// MARK: - 液态玻璃（Liquid Glass）

/// 一块玻璃面板：真材质 + 白色染色 + 镜面描边 + 墨色软投影。
///
/// 为什么不用单纯的 `Color.white.opacity(0.6)`：白底上的白卡片会"糊"在一起，
/// 只有 `.ultraThinMaterial` 的模糊能把它和背后的光晕分开，再叠一层斜向白渐变，
/// 才有玻璃那种"一角更亮"的棱边感。
struct GlassPanel: ViewModifier {
    var cornerRadius: CGFloat = 22
    var elevated: Bool = false

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: elevated
                                    ? [Color.white.opacity(0.66), Color.white.opacity(0.30)]
                                    : [Color.white.opacity(0.46), Color.white.opacity(0.18)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
            }
            .overlay {
                // 镜面棱边：左上高光 → 中段几乎无色 → 右下再提一点，模拟玻璃厚度
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.95),
                                PhoenixTheme.ink.opacity(0.06),
                                Color.white.opacity(0.55),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
            .shadow(color: PhoenixTheme.ink.opacity(0.10),
                    radius: elevated ? 24 : 14,
                    x: 0,
                    y: elevated ? 12 : 7)
    }
}

extension View {
    /// 玻璃卡片（列表/表单里的静态面板）。
    func glassPanel(cornerRadius: CGFloat = 22) -> some View {
        modifier(GlassPanel(cornerRadius: cornerRadius, elevated: false))
    }

    /// 抬升的玻璃卡片（英雄区、主操作区）。
    func glassPanelElevated(cornerRadius: CGFloat = 24) -> some View {
        modifier(GlassPanel(cornerRadius: cornerRadius, elevated: true))
    }

    /// 玻璃胶囊（次级按钮、标签）。
    func glassCapsule() -> some View {
        self
            .background(Capsule().fill(.ultraThinMaterial))
            .background(Capsule().fill(Color.white.opacity(0.42)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.85), lineWidth: 1))
            .shadow(color: PhoenixTheme.ink.opacity(0.06), radius: 6, y: 3)
    }
}

/// 连接状态 → 颜色的唯一映射。界面任何地方都不许自己拼颜色。
enum PhoenixStatus {
    static let live = PhoenixTheme.signalGo
    static let waiting = PhoenixTheme.signalWait
    static let offline = PhoenixTheme.signalFault
}

/// 状态 → 形状。**这是色觉障碍用户的第二条通道**：
/// 把颜色整个去掉，三个形状仍然互相分得开（HIG：状态不能只靠颜色区分）。
enum StatusShape {
    case solidCircle      // 有数据在流
    case hollowRing       // 在等
    case solidSquare      // 坏了

    init(_ level: SignalLamp.Level) {
        switch level {
        case .go: self = .solidCircle
        case .waiting: self = .hollowRing
        case .fault: self = .solidSquare
        }
    }
}

/// 一颗状态灯：**一个形状 + 一种颜色**，旁边永远跟着一句话说清它是什么意思。
///
/// 说明（历史）：v2 之前这里是一排「红—琥珀—绿」三颗小点，想表达"现在处于三段里的哪一段"；
/// 可客户要的是"现在通没通"。三颗并排、两颗永远是灭的，扫一眼就是三个装饰点 ——
/// 评审时被直接点了出来。状态灯只有一个，亮着的那颗就是现在的状态，没有歧义。
struct SignalLamp: View {
    enum Level { case fault, waiting, go }

    let level: Level
    var size: CGFloat = 13

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false

    private var color: Color {
        switch level {
        case .go: return PhoenixTheme.signalGo
        case .waiting: return PhoenixTheme.signalWait
        case .fault: return PhoenixTheme.signalFault
        }
    }

    var body: some View {
        shape
            .frame(width: size, height: size)
            // 有心跳（有数据在流）时，灯外面套一圈慢慢扩散的环：
            // 余光扫过去能看出"它在动"，而不只是"它是绿的"。
            .overlay {
                if level == .go && !reduceMotion {
                    Circle()
                        .strokeBorder(color.opacity(breathing ? 0 : 0.55), lineWidth: 1.5)
                        .scaleEffect(breathing ? 2.1 : 0.9)
                        .animation(
                            .easeOut(duration: 1.8).repeatForever(autoreverses: false),
                            value: breathing
                        )
                }
            }
            .shadow(color: level == .go ? PhoenixTheme.lampGlow(color) : .clear, radius: 6)
            .onAppear { if level == .go { breathing = true } }
            .accessibilityHidden(true)   // 状态由紧挨着的文字念出来，避免 VoiceOver 读两遍
    }

    @ViewBuilder
    private var shape: some View {
        switch level {
        case .go:
            Circle().fill(color)
        case .waiting:
            Circle().strokeBorder(color, lineWidth: max(2, size * 0.17))
        case .fault:
            RoundedRectangle(cornerRadius: size * 0.2, style: .continuous).fill(color)
        }
    }
}

struct PhoenixMark: View {
    var size: CGFloat = 72

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [PhoenixTheme.accent, PhoenixTheme.auroraViolet, PhoenixTheme.auroraPink],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .shadow(color: PhoenixTheme.accent.opacity(0.32), radius: size * 0.28, y: size * 0.12)
            Circle()
                .stroke(.white.opacity(0.9), lineWidth: max(2, size * 0.045))
                .frame(width: size * 0.48, height: size * 0.48)
            Circle()
                .fill(PhoenixTheme.warm)
                .frame(width: size * 0.12, height: size * 0.12)
            Capsule()
                .fill(.white.opacity(0.9))
                .frame(width: size * 0.25, height: max(2, size * 0.045))
                .rotationEffect(.degrees(-47))
                .offset(x: size * 0.11, y: -size * 0.18)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// 页面底：深蓝底 + 两团极淡的方向光。
/// 说明：这是**底色的材质**，不是给卡片加的装饰渐变；雷达页在上层，看不见它。
struct PhoenixBackground: View {
    var body: some View {
        ZStack {
            // 纸白底
            PhoenixTheme.background
            // 三团极淡的虹彩光晕：玻璃面板会把这层光"磨"开，透上来的就是它
            RadialGradient(
                colors: [PhoenixTheme.auroraViolet.opacity(0.30), .clear],
                center: .topTrailing,
                startRadius: 10, endRadius: 460
            )
            RadialGradient(
                colors: [PhoenixTheme.auroraPink.opacity(0.20), .clear],
                center: .init(x: 0.12, y: 0.72),
                startRadius: 10, endRadius: 420
            )
            RadialGradient(
                colors: [PhoenixTheme.cyan.opacity(0.24), .clear],
                center: .bottomTrailing,
                startRadius: 10, endRadius: 380
            )
            // 高光：左上角一团白，让"光从右上打过来"这件事成立
            RadialGradient(
                colors: [Color.white.opacity(0.90), .clear],
                center: .init(x: 0.25, y: 0.06),
                startRadius: 10, endRadius: 340
            )
        }
        .ignoresSafeArea()
    }
}

// MARK: - 全屏雷达上的 HUD

/// 浮在地图上的圆形控件（46pt），用于画中画入口。
///
/// 为什么是圆形而不是胶囊：地图铺满之后，屏幕四角是**底图之外**的空区
/// （底图是居中的正方形，竖屏由屏宽封顶），控件落在角上就不压地图内容。
struct RadarHUDButtonStyle: ButtonStyle {
    var tinted: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 46, height: 46)
            .background(
                Circle()
                    .fill(.ultraThinMaterial)
                    .overlay(
                        Circle().fill(
                            tinted
                                ? PhoenixTheme.accent.opacity(0.16)
                                : PhoenixTheme.hudGlass
                        )
                    )
            )
            .overlay(
                Circle().strokeBorder(
                    tinted ? PhoenixTheme.accent.opacity(0.42) : PhoenixTheme.hairline,
                    lineWidth: 1
                )
            )
            .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// 雷达页右下角那颗"雷达"图标：同心弧 + 一枚扫过去的点。
/// 用 Shape 画而不是 SF Symbol —— 它要跟品牌标记（准星/圆环）同一套笔画语言。
struct RadarGlyph: View {
    var size: CGFloat = 20
    var color: Color = .primary

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(color.opacity(0.85), lineWidth: max(1.2, size * 0.075))
                .frame(width: size * 0.30, height: size * 0.30)
            ForEach(0..<3, id: \.self) { ring in
                Circle()
                    .trim(from: 0.06, to: 0.44)
                    .stroke(
                        color.opacity(ring == 0 ? 0.85 : (ring == 1 ? 0.55 : 0.30)),
                        style: StrokeStyle(lineWidth: max(1.1, size * 0.07), lineCap: .round)
                    )
                    .frame(width: size * (0.56 + CGFloat(ring) * 0.22),
                           height: size * (0.56 + CGFloat(ring) * 0.22))
                    .rotationEffect(.degrees(-24 + Double(ring) * 6))
            }
        }
        .frame(width: size, height: size)
    }
}

/// 雷达页左上角那颗状态点 —— 全屏雷达上**唯一**的常驻状态。
///
/// 它承担两件事：**说真话**（现在通没通）与**回主界面**（点一下就回去）。
/// 视觉是 44pt 的紧凑圆形热区（HIG 最小可点尺寸），不再用一条大胶囊挡地图。
///
/// 为什么不做成一条状态带：那正是本次重构要拆掉的东西 ——
/// 一条带会重新占掉地图的地方，而"通没通"在雷达画面上本来就有更直接的证据
/// （地图上有人在动就是在流）。点只负责在**没动**的时候说清为什么。
struct RadarStatusDot: View {
    let level: SignalLamp.Level
    let label: String
    var onTap: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false

    private var color: Color {
        switch level {
        case .go: return PhoenixTheme.signalGo
        case .waiting: return PhoenixTheme.signalWait
        case .fault: return PhoenixTheme.signalFault
        }
    }

    private var shape: StatusShape { StatusShape(level) }

    static let statusLabelPrefix = "连接状态："

    /// 状态点的无障碍标签。**用函数返回而不是直接传属性** —— 见上面调用处的注释。
    static func statusLabel(for headline: String) -> String {
        statusLabelPrefix + headline
    }
    static let backToConnectionLabel = "返回连接节点"
    static let backToConsoleHint = "回到连接节点界面"
    /// 无障碍标识。它同时是一道**构建门禁的锚点**：
    /// `RadarStatusDot` 一度被 Swift 优化器整块消掉（编译/链接全过、App 能跑、
    /// 只有那个视图不见了），而"只被 SwiftUI 泛型间接引用"的类型在产物里
    /// 既不留下符号也不留下字符串，肉眼与日志都查不出来。
    /// 这里用一个非泛型可达的常量把它钉住，`build-release-hardened.sh` 会核对它。
    static let accessibilityIdentifier = "radar-status-dot"
    /// 紧凑 HUD 的视觉样式标识，供 UI 回归门禁确认没有回退成大胶囊。
    static let compactStyleIdentifier = "radar-status-compact"

    var body: some View {
        Button(action: onTap) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: "arrow.left")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(color.opacity(0.44), lineWidth: 1))
                    .shadow(color: .black.opacity(0.30), radius: 10, y: 4)
                dot
                    .padding(4)
            }
            .frame(width: 52, height: 52)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier(Self.accessibilityIdentifier)
        // 这两行是 VoiceOver 唯一能念出来的内容（客服排障要靠它），所以：
        //  ① 用 `+` 拼而不是插值字面量；
        //  ② 句子本身放在**返回值**里拼 —— 实测：只作为属性传入时，
        //     优化器会把那个静态常量的字面量整块消掉，二进制里查不到。
        .accessibilityLabel(Self.backToConnectionLabel + "，" + Self.statusLabel(for: label))
        .accessibilityHint(Self.backToConsoleHint)
    }

    @ViewBuilder
    private var dot: some View {
        ZStack {
            // 有数据在流：一圈慢慢扩散的环，余光能看出"它在动"
            if level == .go && !reduceMotion {
                Circle()
                    .strokeBorder(color.opacity(breathing ? 0 : 0.5), lineWidth: 1.2)
                    .frame(width: 9, height: 9)
                    .scaleEffect(breathing ? 2.6 : 1)
                    .animation(
                        .easeOut(duration: 2.0).repeatForever(autoreverses: false),
                        value: breathing
                    )
            }
            switch shape {
            case .solidCircle:
                Circle().fill(color).frame(width: 9, height: 9)
            case .hollowRing:
                Circle().strokeBorder(color, lineWidth: 2).frame(width: 9, height: 9)
            case .solidSquare:
                RoundedRectangle(cornerRadius: 1.8, style: .continuous)
                    .fill(color)
                    .frame(width: 8, height: 8)
            }
        }
        .shadow(color: PhoenixTheme.lampGlow(color), radius: 5)
        .onAppear { if level == .go { breathing = true } }
    }
}

/// 全屏雷达上的视图模式。**这是真实需求，不能搬到主界面**：
/// 2D 看全局、双视看高低差、3D 看朝向与掩体关系，一局里会来回切。
enum RadarViewMode: String, CaseIterable, Identifiable {
    case twoD
    case both
    case threeD

    var id: String { rawValue }

    var title: String {
        switch self {
        case .twoD: return "2D"
        case .both: return "双视"
        case .threeD: return "3D"
        }
    }

    /// 交给雷达页的 `?view=` 深链值（页面里既有的能力，不新增 JS）。
    var deepLink: String {
        switch self {
        case .twoD: return "2d"
        case .both: return "both"
        case .threeD: return "3d"
        }
    }

    var storageKey: String { "phoenix.radar.viewMode" }
}
