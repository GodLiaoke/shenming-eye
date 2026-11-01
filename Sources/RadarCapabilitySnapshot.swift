import Foundation

enum RadarUsageMode: String, CaseIterable, Identifiable {
    case singleDevice
    case dualDevice

    var id: String { rawValue }

    var title: String {
        switch self {
        case .singleDevice: return "本机雷达模式"
        case .dualDevice: return "双机雷达模式"
        }
    }

    var subtitle: String {
        switch self {
        case .singleDevice: return "一台手机完成游戏与雷达"
        case .dualDevice: return "一台手机玩游戏，一台手机显示雷达"
        }
    }

    var guideTitle: String {
        switch self {
        case .singleDevice: return "本机模式使用指南"
        case .dualDevice: return "双机模式使用指南"
        }
    }

    var supportsPiP: Bool { self == .singleDevice }
    var requiresSecondDevice: Bool { self == .dualDevice }
}

/// 原生外壳的三条能力状态。它们故意分开：算法服务是主链，浏览器共享和 PiP 是辅助链。
enum LocalRadarState: Equatable {
    case starting
    case waiting
    case streaming(frames: Int)
    case failed(message: String)
}

enum BrowserShareState: Equatable {
    case off
    case waiting
    case sharing
    case failed
}

enum PiPState: Equatable {
    case unavailable
    case ready
    case active
}

enum CapabilityEmphasis: Equatable {
    case primary
    case secondary
}

struct RadarCapabilityChip: Equatable {
    let title: String
    let value: String
    let emphasis: CapabilityEmphasis
}

struct RadarCapabilitySnapshot: Equatable {
    let local: LocalRadarState
    let browser: BrowserShareState
    let pip: PiPState
    let usageMode: RadarUsageMode

    init(
        flow: AppModel.DataFlow,
        panelStreamStatus: String,
        pipSupported: Bool,
        pipActive: Bool,
        usageMode: RadarUsageMode = .singleDevice
    ) {
        self.usageMode = usageMode
        switch flow {
        case .starting:
            local = .starting
        case .waiting:
            local = .waiting
        case let .streaming(count):
            local = .streaming(frames: count)
        case let .fault(reason):
            local = .failed(message: reason)
        }

        let normalizedStream = panelStreamStatus.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedStream.isEmpty || normalizedStream == "未开启" {
            browser = .off
        } else if normalizedStream.contains("失败") || normalizedStream.contains("异常") {
            browser = .failed
        } else if normalizedStream.contains("已收到") || normalizedStream.contains("共享") {
            browser = .sharing
        } else {
            browser = .waiting
        }

        if !pipSupported || !usageMode.supportsPiP {
            pip = .unavailable
        } else if pipActive {
            pip = .active
        } else {
            pip = .ready
        }
    }

    var isLocalLive: Bool {
        if case .streaming = local { return true }
        return false
    }

    var localTitle: String {
        switch local {
        case .starting: return "正在启动算法服务"
        case .waiting: return "等待游戏数据"
        case .streaming: return "正在接收坐标"
        case let .failed(message): return message
        }
    }

    var browserTitle: String {
        switch browser {
        case .off: return "按需开启"
        case .waiting: return "准备中"
        case .sharing: return "已共享"
        case .failed: return "连接失败"
        }
    }

    var pipTitle: String {
        switch pip {
        case .unavailable: return usageMode.supportsPiP ? "不可用" : "本模式不使用"
        case .ready: return "可用"
        case .active: return "运行中"
        }
    }

    /// 主界面第一句固定讲算法链路，避免辅助能力抢走实时雷达的主叙事。
    var primaryCopy: String {
        switch local {
        case .starting: return "算法服务正在启动"
        case .waiting: return "算法服务已就绪，等待游戏数据"
        case .streaming: return "算法服务正在实时出图"
        case .failed: return "算法服务需要检查"
        }
    }

    var capabilityChips: [RadarCapabilityChip] {
        [
            RadarCapabilityChip(title: "算法服务", value: primaryCopy, emphasis: .primary),
            RadarCapabilityChip(title: "浏览器共享", value: browserTitle, emphasis: .secondary),
            RadarCapabilityChip(title: "画中画", value: pipTitle, emphasis: .secondary)
        ]
    }
}
