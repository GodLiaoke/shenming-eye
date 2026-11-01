import Foundation
import UIKit

/// 诊断录制（2026-10-27，客户要求「B 方案」）
///
/// 目的：真人局的**原始数据**我们看不到，只能从小窗的推导结果反推，容易改错。
/// 这里把收到的原始 WebSocket 消息（`map_roster` / `position_delta` / `snapshot` …）
/// 原样落到 App 沙盒的 `Documents/pip-diag.jsonl`，客户用「文件」App 直接导出。
///
/// 设计取舍：
///  · **不逐条写盘**（30Hz × 10 行会把闪存写爆）：内存里留最近 600 条，每 15 秒批量追加；
///  · 进后台时立刻 flush（一局结束切出去就有完整数据）；
///  · 文件超过 4MB 轮转成 `pip-diag.1.jsonl`，最多留两份；
///  · 原始 JSON 用 **base64** 存（`raw_b64`），不担心转义/中文/换行；
///  · 解析方式：`base64 -d` 或我给的小脚本。
final class DiagRecorder {
    static let shared = DiagRecorder()
    /// 关掉就完全不记录（正式版可以改成 false）
    static let enabled = true

    private let queue = DispatchQueue(label: "myrader.pip.diag")
    private var pending: [String] = []
    /// 关键消息（roster/hello/snapshot/session_status）单独存，永不淘汰
    private var pinned: [String] = []
    private var timer: DispatchSourceTimer?
    private let maxPending = 600
    private let maxFileSize = 4 * 1024 * 1024

    private static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private init() {
        guard Self.enabled else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 15, repeating: 15)
        t.setEventHandler { [weak self] in self?.flushLocked() }
        t.resume()
        timer = t
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.flushLocked() }
        }
    }

    /// 记录一条原始消息（`kind` 只用于检索，正文原样 base64）
    /// 这几类消息**永不淘汰**（数量极少但决定一切：谁是"我"、地图是哪张、引擎状态）
    private static let keepAlways: Set<String> = ["hello", "map_roster", "snapshot", "session_status"]

    func record(kind: String, text: String) {
        guard Self.enabled else { return }
        let line = "{\"t\":\"\(Self.stamp.string(from: Date()))\",\"kind\":\"\(kind)\","
            + "\"bytes\":\(text.utf8.count),\"raw_b64\":\"\(Data(text.utf8).base64EncodedString())\"}"
        queue.async {
            // 2026-10-27 修正：上一版把整个环形缓冲按条数淘汰，**开局那条 map_roster 被挤掉了**，
            // 结果拿到一整份数据也判断不了"谁是本机"。现在：关键消息单独留，只淘汰高频的坐标流。
            if Self.keepAlways.contains(kind) {
                self.pinned.append(line)
                if self.pinned.count > 120 { self.pinned.removeFirst(self.pinned.count - 120) }
            } else {
                self.pending.append(line)
                if self.pending.count > self.maxPending {
                    self.pending.removeFirst(self.pending.count - self.maxPending)
                }
            }
        }
    }

    /// 立刻落盘（诊断包导出前也可以调它）
    func flush() { queue.async { self.flushLocked() } }

    // MARK: - 内部

    private var documents: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }

    private var fileURL: URL? { documents?.appendingPathComponent("pip-diag.jsonl") }
    private var rotatedURL: URL? { documents?.appendingPathComponent("pip-diag.1.jsonl") }

    /// 调用方必须已经在 `queue` 上
    private func flushLocked() {
        guard Self.enabled, !(pending.isEmpty && pinned.isEmpty), let fileURL else { return }
        // 关键消息先写，坐标流随后（顺序对外层无影响，都是一条一行的 JSONL）
        let chunk = (pinned + pending).joined(separator: "\n") + "\n"
        pending.removeAll(keepingCapacity: true)
        pinned.removeAll(keepingCapacity: true)
        guard let data = chunk.data(using: .utf8) else { return }
        let fm = FileManager.default
        // 轮转：超过 4MB 就把当前文件挪成 .1（覆盖旧的 .1）
        if let size = try? fm.attributesOfItem(atPath: fileURL.path)[.size] as? Int,
           size + data.count > maxFileSize, let rotatedURL {
            try? fm.removeItem(at: rotatedURL)
            try? fm.moveItem(at: fileURL, to: rotatedURL)
        }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL)
        }
    }
}
