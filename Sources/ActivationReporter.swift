import Foundation

/// 激活过程的实时状态（界面用）：现在跑到第几段。
/// Rust 侧每推进一步就更新 `CURRENT_STAGE`，这里由 T3Verify 轮询写入。
@MainActor
final class ActivationReporter: ObservableObject {
    static let shared = ActivationReporter()
    @Published private(set) var stage: String = ""

    private init() {}

    func update(_ stage: String) { self.stage = stage }
    func reset() { stage = "" }
}
