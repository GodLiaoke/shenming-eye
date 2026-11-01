import Foundation
import UIKit

/// Coordinates the finite iOS background task used while the radar page is
/// active. A Packet Tunnel extension remains the durable path; ordinary
/// signing only gets a finite recovery window and may need node resync after
/// the OS suspends the process.
@MainActor
final class BackgroundRuntime {
    enum Status: Equatable {
        case foreground
        case backgroundTask
        case extensionManaged

        var displayText: String {
            switch self {
            case .foreground: return "前台运行"
            case .backgroundTask: return "后台恢复已安排 · 可能需要重新同步节点"
            case .extensionManaged: return "网络扩展后台运行"
            }
        }

        var preservesRelayCredentials: Bool {
            switch self {
            case .foreground, .extensionManaged: return true
            case .backgroundTask: return false
            }
        }
    }

    static let shared = BackgroundRuntime()

    private(set) var status: Status = .foreground
    private var task: UIBackgroundTaskIdentifier = .invalid

    private init() {}

    func enterBackground(extensionManaged: Bool = false) {
        if extensionManaged {
            status = .extensionManaged
            endTask()
            return
        }
        guard task == .invalid else { return }
        let identifier = UIApplication.shared.beginBackgroundTask(withName: "Phoenix radar relay") { [weak self] in
            self?.finishExpiredTask()
        }
        guard identifier != .invalid else {
            status = .foreground
            return
        }
        task = identifier
        status = .backgroundTask
    }

    func enterForeground() {
        endTask()
        status = .foreground
    }

    private func finishExpiredTask() {
        endTask()
        status = .foreground
    }

    private func endTask() {
        guard task != .invalid else { return }
        UIApplication.shared.endBackgroundTask(task)
        task = .invalid
    }
}
