//
//  RadarPiPController.swift
//  MyraderVal
//
//  画中画悬浮窗：把雷达画面以系统画中画小窗浮在其它 App（含全屏游戏）上层，
//  支持「一台手机同时玩游戏 + 看雷达」。
//
//  画面来源是 **原生绘制**（见 PiPRadarSource）：直接连本机面板的 WebSocket，
//  自己用 Core Graphics 画。之所以不用 WebView 截图 —— App 切到后台后 WebKit
//  停止绘制，截图只能拿到黑帧，悬浮窗会变黑。
//
//  纯客户端实现：不新增、不修改任何服务端接口与请求。
//

import AVFoundation
import AVKit
import CoreGraphics
import Foundation
import MediaPlayer
import UIKit
import WebKit

/// 承载 `AVSampleBufferDisplayLayer` 的视图，作为画中画的内容源。
final class PiPFrameHostView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }

    var displayLayer: AVSampleBufferDisplayLayer? { layer as? AVSampleBufferDisplayLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        displayLayer?.videoGravity = .resizeAspect
        displayLayer?.backgroundColor = UIColor.black.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// 负责抓帧、编码成 `CMSampleBuffer`、驱动系统画中画。
final class RadarPiPController: NSObject, ObservableObject {
    static let shared = RadarPiPController()

    /// 画中画窗口的输出分辨率。
    ///
    /// 系统画中画的窗口比例 = 出帧画面的比例，所以这里按**当前底图的宽高比**
    /// 出图：现有地图纹理都是 1024×1024，于是窗口就是一个正方形，地图刚好铺满、
    /// 不留黑边（之前固定 16:9，地图两边全是黑边）。
    private var targetSize = CGSize(width: 512, height: 512)
    private let canvasWidth: CGFloat = 512
    private let canvasMinHeight: CGFloat = 224
    private let canvasMaxHeight: CGFloat = 768
    /// 出图帧率。数据约 10Hz，但**视点要 30fps 才顺**（跟随朝向时整张图在转，
    /// 12fps 就是"一格一格跳"——客户报的"明显不流畅"）。
    /// 视点本身带平滑+外推（见 PiPRadarSource.updateSmoothedView），
    /// 所以 30fps 出来的每一帧都是插值过的，不是把 10Hz 原样画 3 遍。
    /// 2026-10-29：30 → 60（客户要求画中画与大屏都 60fps）
    private let frameRate: Double = 60

    @Published private(set) var isActive = false
    @Published private(set) var isPossible = false
    @Published private(set) var statusText = "悬浮窗未开启"
    @Published private(set) var measuredFPS: Double = 0

    var onActiveChanged: ((Bool) -> Void)?
    var onFailure: ((String) -> Void)?

    static var isSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }
    var isActiveNow: Bool { pipController?.isPictureInPictureActive ?? false }

    private let hostView = PiPFrameHostView(frame: CGRect(x: 0, y: 0, width: 480, height: 270))
    private let source = PiPRadarSource()
    private var pipController: AVPictureInPictureController?
    private var possibleObservation: NSKeyValueObservation?
    private var panelURL: URL?
    private var panelToken: String = ""
    private weak var panelWebView: WKWebView?

    private var pumpTimer: DispatchSourceTimer?
    private var meterTimer: DispatchSourceTimer?
    /// 运行中每 2 秒把面板显示开关重新镜像一次（见 startSettingsMirror）
    private var settingsTimer: DispatchSourceTimer?
    private var pixelBufferPool: CVPixelBufferPool?
    private var poolSize: CGSize = .zero
    /// 画中画出帧不能依赖主线程 RunLoop：App 切到游戏后主 RunLoop 可能被系统节流。
    /// 独立队列只负责生成 CVPixelBuffer，再交给 AVSampleBufferDisplayLayer。
    private let pumpQueue = DispatchQueue(label: "com.myrader.pip.frames", qos: .userInitiated)
    private var framesThisSecond = 0
    private var pendingStart = false

    private var silentPlayer: AVAudioPlayer?

    override init() {
        super.init()
    }

    // MARK: - 视图接入

    /// 交给 SwiftUI 作为最底层背景挂载；被上层 WebView 完全遮住，用户看不到。
    func hostRepresentable() -> PiPFrameHostView { hostView }

    func makeHostView() -> PiPFrameHostView { hostView }

    /// 雷达面板地址（http://127.0.0.1:18080/）。画中画的数据来自这个地址，
    /// 它是进程内的 Rust 服务，切后台后照常工作。

    func attachPanel(_ url: URL, token: String, webView: WKWebView?) {
        panelURL = url
        panelToken = token
        panelWebView = webView
        if !isActive {
            statusText = "雷达面板已就绪，可开启悬浮窗"
        }
    }

    func detachPanel() {
        panelURL = nil
        panelToken = ""
        panelWebView = nil
        if isActive { stop() }
    }

    // MARK: - 开关

    func toggle() {
        if pipController?.isPictureInPictureActive == true {
            stop()
        } else {
            start()
        }
    }

    func start() {
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            statusText = "本机不支持画中画"
            return
        }
        guard let panelURL else {
            statusText = "雷达面板尚未就绪"
            return
        }
        if pipController == nil { buildController() }
        guard pipController != nil else {
            onFailure?("悬浮窗初始化失败")
            statusText = "悬浮窗初始化失败"
            return
        }
        activateBackgroundAudio()
        startNowPlaying()
        mirrorPanelDisplaySettings()
        source.start(panelURL: panelURL, panelToken: panelToken)
        statusText = "正在开启悬浮窗…"
        pendingStart = true
        startPump()
        startSettingsMirror()
    }

    func stop() {
        stopPump()
        stopSettingsMirror()
        source.stop()
        stopNowPlaying()
        deactivateBackgroundAudio()
        pendingStart = false
        pipController?.stopPictureInPicture()
        hostView.displayLayer?.flushAndRemoveImage()
        isActive = false
        measuredFPS = 0
        statusText = "悬浮窗未开启"
    }

    // MARK: - 内部搭建

    /// 把面板「显示」设置镜像到悬浮窗，保持一致：人物开关、威胁提示、标记大小、跟随朝向。
    ///
    /// 两处直接决定小窗能不能用：
    ///  · `lockNorth` **只在面板显式设过时才覆盖**小窗默认值 —— 没设过（localStorage 无值）
    ///    小窗保持「角色朝向朝上」（`Settings.lockNorth` 默认 false）；面板点过
    ///    「北向朝上 / 跟随朝向」就以面板为准。
    ///  · 自己是谁要带上 `track_id` + `gen`（面板同代做法）：只按槽位认人，槽位一重排
    ///    小窗就会认到别人身上。
    ///
    /// 面板把这些开关存在 WebView 的 localStorage 里，所以要在前台读；运行中由
    /// `startSettingsMirror()` 每 2 秒再读一次（切后台后 WebView 可能不再执行 JS，
    /// 这时保留上一次的值，不覆盖、不清空）。
    private func mirrorPanelDisplaySettings() {
        guard let webView = panelWebView else { return }
        let script = """
        JSON.stringify({
          players: localStorage.getItem('codev.display.players'),
          threats: localStorage.getItem('codev.display.threats'),
          labels: localStorage.getItem('codev.display.labels'),
          markerScale: localStorage.getItem('codev.display.markerScale'),
          lockNorth: localStorage.getItem('codev.radar.lockNorth'),
          follow: localStorage.getItem('codev.display.follow'),
          selfSlot: localStorage.getItem('codev.display.selfSlot'),
          selfCamp: localStorage.getItem('codev.display.selfCamp'),
          selfTrack: localStorage.getItem('codev.display.selfTrack'),
          selfGen: localStorage.getItem('codev.display.selfGen'),
          campFilter: localStorage.getItem('codev.display.campFilter'),
          pageStatus: (document.querySelector('.status') || {}).textContent || '',
          pageWarning: (document.querySelector('.map-warning') || {}).textContent || '',
          pageEmpty: document.body.classList.contains('is-empty'),
          pageQuery: location.search.replace(/[0-9a-f]{16,}/gi, 'TOKEN')
        })
        """
        webView.evaluateJavaScript(script) { [weak self] value, _ in
            guard let self, let text = value as? String,
                  let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            func flag(_ key: String, _ fallback: Bool) -> Bool {
                guard let raw = object[key] as? String else { return fallback }
                return raw == "1"
            }
            var settings = PiPRadarSource.Settings()
            settings.players = flag("players", true)
            settings.threats = flag("threats", true)
            settings.labels = flag("labels", true)
            // ⚠️ 悬浮窗**一律**「角色朝向朝上」（地图跟着我转）。面板那颗「北向朝上」
            // 只影响网页，不再影响小窗 —— 客户明确要求小窗默认就是"我朝上"。
            // 2026-10-29：小窗**固定跟随视角**（客户要求去掉开关，默认就跟随）。
            // 面板的 lockNorth/follow 只影响网页，不再影响小窗。
            settings.lockNorth = false
            settings.follow = true
            _ = object["lockNorth"]
            _ = object["follow"]
            if let raw = object["markerScale"] as? String, let percent = Double(raw), percent > 5 {
                settings.markerScale = percent / 100
            }
            if let raw = object["selfSlot"] as? String, let slot = Int(raw) {
                settings.selfSlotPreference = slot
            }
            if let raw = object["selfCamp"] as? String, let camp = Int(raw) {
                settings.selfCamp = camp
            }
            if let raw = object["selfTrack"] as? String, !raw.isEmpty {
                settings.selfTrackID = raw
            }
            if let raw = object["selfGen"] as? String, !raw.isEmpty {
                settings.selfTrackGen = raw
            }
            if let raw = object["campFilter"] as? String,
               let data = raw.data(using: .utf8),
               let filter = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let value = filter["self"] as? Bool { settings.filterSelf = value }
                if let value = filter["team"] as? Bool { settings.filterTeam = value }
                if let value = filter["enemy"] as? Bool { settings.filterEnemy = value }
                if let value = filter["dead"] as? Bool { settings.filterDead = value }
            }
            // 网页自己的状态（客户只看小窗，得让小窗把网页的情况也带出来）
            let status = (object["pageStatus"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let warning = (object["pageWarning"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let empty = (object["pageEmpty"] as? Bool) ?? false
            var parts: [String] = []
            if !status.isEmpty { parts.append(status) }
            if empty { parts.append("空态") }
            if let query = object["pageQuery"] as? String, !query.isEmpty {
                parts.append("址" + String(query.prefix(40)))
            }
            if !warning.isEmpty { parts.append(String(warning.prefix(18))) }
            settings.pageState = parts.isEmpty ? nil : parts.joined(separator: "/")
            if let state = settings.pageState, self.isActive {
                self.statusText = "悬浮窗运行中 · 网页:" + state
            }
            self.source.setSettings(settings)
        }
    }

    /// 运行中重镜像：面板上点「跟随朝向 / 北向朝上 / 人物 / 威胁 / 标记大小」2 秒内生效，
    /// 不用关掉重开悬浮窗。切后台后 WKWebView 常常不再执行 JS —— 那一次读不回来就
    /// **保持原设置**（两侧都只在拿到完整 JSON 时才写），界面不会因此变化。
    private func startSettingsMirror() {
        guard settingsTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 2, repeating: 2.0, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in
            guard let self, self.isActive || self.pendingStart else { return }
            self.mirrorPanelDisplaySettings()
        }
        timer.resume()
        settingsTimer = timer
    }

    private func stopSettingsMirror() {
        settingsTimer?.setEventHandler {}
        settingsTimer?.cancel()
        settingsTimer = nil
    }

    private func buildController() {
        guard let layer = hostView.displayLayer else { return }
        let contentSource = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: layer,
            playbackDelegate: self
        )
        let controller = AVPictureInPictureController(contentSource: contentSource)
        controller.delegate = self
        controller.canStartPictureInPictureAutomaticallyFromInline = false
        pipController = controller

        possibleObservation = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] _, change in
            let value = change.newValue ?? false
            DispatchQueue.main.async { self?.isPossible = value }
        }
    }

    /// 画中画要在切到后台后继续出图，必须有后台音频权限；
    /// 这里顺带播一段静音，把音频会话稳住，避免系统把进程挂起。
    private func activateBackgroundAudio() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
        try? session.setActive(true)

        if silentPlayer == nil {
            if let data = Self.silentWAV() {
                silentPlayer = try? AVAudioPlayer(data: data)
                silentPlayer?.numberOfLoops = -1
                silentPlayer?.volume = 0
            }
        }
        silentPlayer?.play()
    }

    private func deactivateBackgroundAudio() {
        silentPlayer?.stop()
        silentPlayer = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    /// 只有「看起来在放媒体」的 App，后台音频模式才稳定保住进程；
    /// 登记一条正在播放的信息，进一步降低被挂起的概率。
    private func startNowPlaying() {
        UIApplication.shared.beginReceivingRemoteControlEvents()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: "Myrader Val",
            MPMediaItemPropertyArtist: "实时雷达",
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyPlaybackRate: 1.0
        ]
    }

    private func stopNowPlaying() {
        UIApplication.shared.endReceivingRemoteControlEvents()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

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
        put("RIFF")
        put32(UInt32(36 + dataSize))
        put("WAVE")
        put("fmt ")
        put32(16)
        put16(1)
        put16(1)
        put32(UInt32(sampleRate))
        put32(UInt32(sampleRate * 2))
        put16(2)
        put16(16)
        put("data")
        put32(UInt32(dataSize))
        data.append(Data(count: dataSize))
        return data
    }

    // MARK: - 出帧

    private func startPump() {
        guard pumpTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: pumpQueue)
        timer.schedule(deadline: .now(), repeating: 1.0 / frameRate, leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.renderFrame() }
        timer.resume()
        pumpTimer = timer

        let meter = DispatchSource.makeTimerSource(queue: pumpQueue)
        meter.schedule(deadline: .now() + 1, repeating: 1.0, leeway: .milliseconds(30))
        meter.setEventHandler { [weak self] in
            guard let self else { return }
            let fps = Double(self.framesThisSecond)
            self.framesThisSecond = 0
            DispatchQueue.main.async {
                self.measuredFPS = fps
                if self.isActive {
                    self.statusText = self.source.connected
                        ? "悬浮窗运行中 · 已连面板 · 点位 \(self.source.positionsSeen)"
                        : "悬浮窗运行中 · 未连上本机面板（消息 \(self.source.messagesReceived)）"
                }
            }
        }
        meter.resume()
        meterTimer = meter
    }

    private func stopPump() {
        pumpTimer?.setEventHandler {}
        pumpTimer?.cancel()
        pumpTimer = nil
        meterTimer?.setEventHandler {}
        meterTimer?.cancel()
        meterTimer = nil
    }

    /// 让出帧比例跟随当前底图；底图换成非正方形的图时窗口也会跟着变。
    private func refreshCanvasSize() {
        let aspect = min(3.0, max(0.4, source.contentAspect))
        let height = min(canvasMaxHeight, max(canvasMinHeight, (canvasWidth / aspect).rounded()))
        if abs(height - targetSize.height) > 0.5 {
            targetSize = CGSize(width: canvasWidth, height: height)
        }
    }

    private func renderFrame() {
        refreshCanvasSize()
        guard let layer = hostView.displayLayer else { return }
        guard let buffer = makePixelBuffer() else { return }
        guard let sample = makeSampleBuffer(from: buffer) else { return }
        if layer.status == .failed { layer.flush() }
        guard layer.isReadyForMoreMediaData else { return }
        layer.enqueue(sample)
        framesThisSecond += 1
        guard pendingStart else { return }
        DispatchQueue.main.async { [weak self] in self?.startWhenPossible(retries: 30) }
    }

    private func startWhenPossible(retries: Int) {
        guard pendingStart, !isActive else { return }
        guard let pipController else { return }
        guard pipController.isPictureInPicturePossible else {
            if retries > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.startWhenPossible(retries: retries - 1)
                }
            } else {
                pendingStart = false
                onFailure?("画中画启动超时：宿主视图尚未就绪")
            }
            return
        }
        pendingStart = false
        pipController.startPictureInPicture()
    }

    private func makePixelBuffer() -> CVPixelBuffer? {
        let width = Int(targetSize.width)
        let height = Int(targetSize.height)
        // 复用缓冲池：30fps 下每帧新建 1MB 的 CVPixelBuffer 会把出帧节奏打散
        // （分配 + IOSurface 抖动）——这也是"不流畅"的一半。
        if pixelBufferPool == nil || poolSize != targetSize {
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferCGImageCompatibilityKey: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
            ]
            var pool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault,
                                    [kCVPixelBufferPoolMinimumBufferCountKey: 4] as CFDictionary,
                                    attributes as CFDictionary,
                                    &pool)
            pixelBufferPool = pool
            poolSize = targetSize
        }
        guard let pool = pixelBufferPool else { return nil }
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer) == kCVReturnSuccess,
              let buffer = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }

        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let context = CGContext(
            data: base,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        ) else { return nil }

        source.draw(into: context, size: targetSize)
        return buffer
    }

    private func makeSampleBuffer(from pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
        var formatDescription: CMFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        ) == noErr, let format = formatDescription else { return nil }

        let now = CMClockGetTime(CMClockGetHostTimeClock())
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(frameRate)),
            presentationTimeStamp: now,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: format,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sample = sampleBuffer else { return nil }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dictionary,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }
        return sample
    }
}

// MARK: - AVPictureInPictureControllerDelegate

extension RadarPiPController: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        isActive = true
        onActiveChanged?(true)
        statusText = "悬浮窗运行中，可切到游戏"
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        stopPump()
        stopSettingsMirror()
        source.stop()
        stopNowPlaying()
        deactivateBackgroundAudio()
        isActive = false
        onActiveChanged?(false)
        measuredFPS = 0
        statusText = "悬浮窗已关闭"
    }

    func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        stopPump()
        stopSettingsMirror()
        source.stop()
        stopNowPlaying()
        deactivateBackgroundAudio()
        isActive = false
        onFailure?("画中画启动失败：\(error.localizedDescription)")
        statusText = "悬浮窗开启失败：\(error.localizedDescription)"
    }

    func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(true)
    }
}

// MARK: - AVPictureInPictureSampleBufferPlaybackDelegate

extension RadarPiPController: AVPictureInPictureSampleBufferPlaybackDelegate {
    /// 雷达是实时流，没有时间轴，给一个无限区间让系统按「直播」样式显示。
    func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool {
        false
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController, setPlaying playing: Bool) {
        // 实时画面不响应暂停/继续，保持一直出图。
    }

    func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping () -> Void
    ) {
        completionHandler()
    }

    func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {
        // 每帧都按目标分辨率重画，尺寸变化无需额外处理。
    }

    func pictureInPictureControllerShouldProhibitBackgroundAudioPlayback(_ controller: AVPictureInPictureController) -> Bool {
        false
    }
}
