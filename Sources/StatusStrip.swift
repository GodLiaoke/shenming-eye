import SwiftUI

/// 面板顶部的**醒目状态面**：整块底色的状态横幅，不是一张"图标 + 标题 + 正文"的卡。
///
/// 用户明确要的"连上并有数据时加一个显示"就落在这里：
/// 绿底 + 绿勾 + 一句话 + 会跳的帧数。在还没数据时它显示琥珀色的"下一步该做什么"，
/// 所以这个位置任何时候都不空着，也不说谎。
struct ConnectionStatusBanner: View {
    let flow: AppModel.DataFlow

    private var tint: Color {
        switch flow.lampLevel {
        case .go: return PhoenixTheme.signalGo
        case .waiting: return PhoenixTheme.signalWait
        case .fault: return PhoenixTheme.signalFault
        }
    }

    private var icon: String {
        switch flow.lampLevel {
        case .go: return "checkmark.circle.fill"
        case .waiting: return "clock.fill"
        case .fault: return "exclamationmark.triangle.fill"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 26)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(flow.headline)
                    .font(PhoenixType.section)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                if let detail = flow.detail {
                    Text(detail)
                        .font(PhoenixType.counter)
                        .foregroundStyle(.primary.opacity(0.78))
                        
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        // 整块底色：状态占满一条面，而不是一个小圆点藏在角落
        .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(tint.opacity(0.32), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }
}

/// 一步在界面上怎么呈现。
///
/// **这个枚举存在的唯一理由，是把「App 观测到的」和「App 观测不到的」分开。**
/// 上一版给四步一律打绿勾，其中「手机 B 接入同一 Wi-Fi 或热点」「手机 B 用 Shadowrocket 扫码」
/// 两条是**发生在另一台手机上**的操作说明 —— 本机没有任何信号能观测到它们
/// （引擎没有活跃会话 gauge，`relayClientCount` 恒为 0，这也是"接入台数"宁可不显示的原因）。
/// 给观测不到的东西打勾就是编造状态，与 PRODUCT.md 原则 5「状态说真话」直接冲突。
enum SetupStepState {
    /// App **真的观测到了**：这一步已经成。`label` 是给客户看的短词。
    case observed(String)
    /// App 观测到"还没到"，但也没出错（例：引擎在跑，只是还没收到坐标）。
    case observedWaiting(String)
    /// App 观测到出问题了。`label` 就是给客户看的那句话。
    case observedFault(String)
    /// **只是操作说明**：这一步发生在手机 B 上，本机观测不到 —— 永远中性，永不打勾。
    case instruction
}

/// 配对清单：编号步骤 + 说明；**只有 App 真的观测到的步骤才带状态胶囊**。
///
/// 编号永远是编号（1/2/3/4），状态用右侧胶囊单独表达。这样"没有胶囊"只表示
/// "这一步本机看不见"，不会被误读成"没做完"或"出错了"。
struct SetupChecklist: View {
    struct Step: Identifiable {
        /// 既是 ForEach 的标识，也是显示给客户的步骤号（1 起）。
        let id: Int
        let title: String
        let detail: String?
        let state: SetupStepState
    }

    let steps: [Step]
    /// 有坐标在流时才给的一句实话：那两步（在手机 B 上做的）已经生效了。
    var footnote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("配对步骤")
                .font(PhoenixType.captionStrong)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 13)
                .padding(.bottom, 9)
                .accessibilityAddTraits(.isHeader)

            ForEach(steps) { step in
                row(step)
                if step.id != steps.last?.id {
                    Divider().overlay(PhoenixTheme.hairline).padding(.leading, 48)
                }
            }

            if let footnote {
                Text(footnote)
                    .font(PhoenixType.caption)
                    .foregroundStyle(.primary.opacity(0.82))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(PhoenixTheme.signalGo.opacity(0.10))
            }
        }
        .glassPanel(cornerRadius: 18)
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(PhoenixTheme.hairline, lineWidth: 1)
        )
    }

    private func row(_ step: Step) -> some View {
        HStack(alignment: .top, spacing: 12) {
            numberBadge(step.id)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(step.title)
                    .font(PhoenixType.callout)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = step.detail {
                    Text(detail)
                        .font(PhoenixType.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            statusChip(for: step.state)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
        .accessibilityValue(step.state.accessibilityValue)
    }

    private func numberBadge(_ number: Int) -> some View {
        Text("\(number)")
            .font(PhoenixType.captionStrong)
            .foregroundStyle(.secondary)
            .frame(width: 22, height: 22)
            .background(Circle().fill(PhoenixTheme.ink.opacity(0.06)))
            .overlay(Circle().strokeBorder(PhoenixTheme.hairline, lineWidth: 1))
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func statusChip(for state: SetupStepState) -> some View {
        switch state {
        case let .observed(label):
            chip(label, icon: "checkmark", tint: PhoenixTheme.signalGo)
        case let .observedWaiting(label):
            chip(label, icon: "ellipsis", tint: PhoenixTheme.signalWait)
        case let .observedFault(label):
            chip(label, icon: "exclamationmark", tint: PhoenixTheme.signalFault)
        case .instruction:
            EmptyView()
        }
    }

    private func chip(_ label: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))
            Text(label)
                .font(PhoenixType.captionStrong)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(tint.opacity(0.14), in: Capsule())
        .overlay(Capsule().strokeBorder(tint.opacity(0.30), lineWidth: 1))
        .fixedSize()
    }
}

private extension SetupStepState {
    var accessibilityValue: String {
        switch self {
        case let .observed(label): return "本机已观测到：\(label)"
        case let .observedWaiting(label): return "本机观测到：\(label)"
        case let .observedFault(label): return "本机观测到有问题：\(label)"
        case .instruction: return "操作说明；这一步在另一台手机上，本机检测不到"
        }
    }
}

/// 折叠的诊断区：把"算法服务、面板探到没有、数据流通不通、装的是哪一版"
/// 收进一个默认收起的分组里。
///
/// 为什么不是删掉：这几行是**排障时唯一能看清现场的东西**（历史踩过静默回退的坑），
/// 但它们是给客服和研发看的，不是给打游戏的客户看的。收起 = 还在，只是不占视线。
struct DiagnosticsDisclosure: View {
    @State private var expanded = false
    let rows: [(String, String)]

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.22)) { expanded.toggle() }
            } label: {
                HStack {
                    // 控件要说出它会做什么：这是"查看诊断信息"，不是标题"诊断信息"。
                    Text(expanded ? "收起诊断信息" : "查看诊断信息")
                        .font(PhoenixType.captionStrong)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 0 : -90))
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(expanded ? "收起诊断信息" : "展开诊断信息")

            if expanded {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(row.0)
                                .font(PhoenixType.caption)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            Text(row.1)
                                .font(PhoenixType.monoSmall)
                                .foregroundStyle(.primary.opacity(0.82))
                                .multilineTextAlignment(.trailing)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .frame(minHeight: 36)

                        if index != rows.count - 1 {
                            Divider().overlay(PhoenixTheme.hairline).padding(.leading, 14)
                        }
                    }
                }
            }
        }
        .glassPanel(cornerRadius: 18)
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(PhoenixTheme.hairline, lineWidth: 1)
        )
    }
}
