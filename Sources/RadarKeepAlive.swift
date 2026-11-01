import AVFoundation
import Foundation
import MediaPlayer
import UIKit

/// 后台保活：让 App 在**没有画中画**的时候也能继续跑（中继/引擎/ WS 都不掉）。
///
/// 现状问题（2026-10-20 客户反馈）：
///   · 开着悬浮窗（画中画）时，切到后台网络照常，游戏能连；
///   · 关掉悬浮窗再切后台，30 秒左右进程被挂起，2025 节点与面板一起断。
/// 原因：画中画自己会激活后台音频会话；一旦没有画中画，App 只剩
/// `beginBackgroundTask` 那点有限时间，到点就被系统挂起。
///
/// 这里做的是"常驻媒体"：只要引擎在跑，就一直维持一个静音的播放会话
/// （`UIBackgroundModes = audio` 已在 project.yml 里声明），并把 Now Playing
/// 登记成"正在播放"，让系统把它当成媒体类进程对待，不轻易挂起。
@MainActor
final class RadarKeepAlive {
    static let shared = RadarKeepAlive()

    private var player: AVAudioPlayer?
    private var observers: [NSObjectProtocol] = []
    private(set) var isRunning = false

    private init() {}

    /// 引擎起来之后调用。可重复调用（幂等）。
    func start() {
        guard !isRunning else {
            player?.play()
            return
        }
        isRunning = true
        activateSession()
        startSilentLoop()
        registerNowPlaying()
        observeInterruptions()
    }

    /// 引擎停了就调这里，别把无声播放一直挂着。
    func stop() {
        guard isRunning else { return }
        isRunning = false
        player?.stop()
        player = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        UIApplication.shared.endReceivingRemoteControlEvents()
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    // MARK: - 音频会话

    private func activateSession() {
        let session = AVAudioSession.sharedInstance()
        // .mixWithOthers：别把客户正在放的语音/音乐掐掉（开黑语音很常见）。
        try? session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
        try? session.setActive(true)
    }

    private func startSilentLoop() {
        if player == nil, let data = Self.silentWAV() {
            player = try? AVAudioPlayer(data: data)
            player?.numberOfLoops = -1
            player?.volume = 0
            player?.prepareToPlay()
        }
        player?.play()
    }

    private func registerNowPlaying() {
        UIApplication.shared.beginReceivingRemoteControlEvents()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: "神明之眼",
            MPMediaItemPropertyArtist: "实时雷达",
            MPNowPlayingInfoPropertyPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyIsLiveStream: true,
        ]
    }

    /// 来电/其它 App 抢走音频后，回到前台或中断结束要自动恢复静音播放。
    private func observeInterruptions() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            Task { @MainActor in
                guard let self, self.isRunning else { return }
                self.activateSession()
                self.player?.play()
            }
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRunning else { return }
                self.activateSession()
                self.player?.play()
            }
        })
        observers.append(center.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRunning else { return }
                self.activateSession()
                self.player?.play()
            }
        })
    }

    // MARK: - 静音 WAV

    private static func silentWAV(seconds: Double = 1.0, sampleRate: Int = 8000) -> Data? {
        let frames = Int(Double(sampleRate) * seconds)
        let dataSize = frames * 2
        var data = Data()
        func put(_ text: String) { data.append(contentsOf: Array(text.utf8)) }
        func put32(_ value: UInt32) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        func put16(_ value: UInt16) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        put("RIFF"); put32(UInt32(36 + dataSize)); put("WAVE")
        put("fmt "); put32(16); put16(1); put16(1)
        put32(UInt32(sampleRate)); put32(UInt32(sampleRate * 2)); put16(2); put16(16)
        put("data"); put32(UInt32(dataSize))
        data.append(Data(count: dataSize))
        return data
    }
}
