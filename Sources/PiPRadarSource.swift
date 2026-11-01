//
//  PiPRadarSource.swift
//  MyraderVal
//
//  画中画的原生画面来源。
//
//  为什么不用 WebView 截图：App 切到后台后 WebKit 不再绘制，
//  `takeSnapshot` 拿不到画面 → 悬浮窗变黑。本文件改为直接连本机面板的
//  WebSocket（127.0.0.1:18080，进程内 Rust 服务，后台照常工作），
//  拿到归一化坐标后自己用 Core Graphics 画。
//
//  坐标：`PositionView.map.u / .v` 已经是 0..1 的地图归一化坐标，
//  与面板网页用的是同一套（world → u = 0.5 - (x-cx)/sx）。
//

import CoreGraphics
import Foundation
import UIKit

final class PiPRadarSource {
    /// 从面板「显示」设置里镜像过来的开关。默认值与面板一致。
    struct Settings {
        var players = true
        var threats = true
        var labels = true
        var markerScale = 1.0
        /// 「北向锁定」＝底图固定不转（面板里的「北向朝上」）。
        ///
        /// ⚠️ 默认 **false**：画中画小窗自己的默认形态是**角色朝向朝上**
        /// （地图转、人不转）。面板若显式设置过这个开关，以面板为准（见 RadarPiP 的镜像）。
        var lockNorth = false
        /// 面板「玩家中心跟随」：默认开。开启时把自己摆到中心并做 90° 组合旋转，
        /// 与网页观感一致。
        var follow = true
        /// 面板里存的自身槽位/阵营（引擎 roster 没给时的兜底）
        var selfSlotPreference: Int?
        var selfCamp: Int?
        /// 面板 localStorage `codev.display.selfTrack`：按 track_id 认自己（槽位重排不影响）。
        /// 面板从 v1.1.x 起就是这套绑定，小窗一直只用槽位 → 认错人/认不到人。
        var selfTrackID: String?
        /// 配套的 `codev.display.selfGen`：只在与**本局** channel_generation 相同时有效。
        var selfTrackGen: String?
        var filterSelf = true
        var filterTeam = true
        var filterEnemy = true
        var filterDead = true
        /// 小窗底部那行状态（地图/自己是谁/点位数/面板是否连着）。排障用，默认开。
        var diagnostics = true
        /// 网页自己的状态（连接/空态/警告），由 RadarPiP 每 2 秒从页面读回来。
        /// 为什么塞进小窗：网页"没数据"时只有网页自己知道卡在哪，而小窗是客户一直在看的那块。
        var pageState: String?
    }

    /// 与面板 `markerColors` 完全一致，保证悬浮窗和网页颜色一样。
    ///
    /// 非 private：像素级测试要拿**同一批颜色对象**去量真实落盘值
    /// （generic RGB → DeviceRGB 有色彩空间转换，测试里硬编码常量会误判）。
    enum Palette {
        /// 深色描边（面板 `rgba(3,10,15,.94)` 那圈 halo）：小窗背后是**浅灰底图**，
        /// 只靠浅色填充会糊在图上（客户原话"颜色有点淡看不清"）。
        static let halo = CGColor(red: 0.012, green: 0.039, blue: 0.059, alpha: 0.95)
        // 悬浮窗专用高饱和色：比面板网页更浓一档，小窗里对比度优先
        static let selfColour = CGColor(red: 1.0, green: 0.843, blue: 0.0, alpha: 1)        // #ffd700
        static let teamColour = CGColor(red: 0.118, green: 0.525, blue: 1.0, alpha: 1)      // #1e86ff
        static let enemyColour = CGColor(red: 1.0, green: 0.176, blue: 0.271, alpha: 1)     // #ff2d45
        static let unknownColour = CGColor(red: 0.596, green: 0.635, blue: 0.702, alpha: 1) // #98a2b3
        /// 标记边缘那圈亮描边（面板 `rgba(238,248,250,.82)`）
        static let edge = CGColor(red: 0.933, green: 0.973, blue: 0.980, alpha: 0.85)
        /// 底图压暗比例：底图是浅灰的，不压暗标记再亮也糊在图上（客户："对比度依旧不高"）
        static let mapDimAlpha: CGFloat = 0.0    // 2026-10-30：底图换成引擎自带的白色成品图，不再压暗
    }

    private enum Role { case own, team, enemy, unknown }

    struct Entity {
        var slot: Int
        var u: Double
        var v: Double
        var yaw: Double
        var updatedNS: UInt64
        var campID: Int?
        var name: String?
        /// 英雄 id（面板同名字段）。小窗没有头像资源，用「英雄名」当默认标签。
        var agentID: Int?
        var fresh: Bool
        /// 引擎的稳定身份：槽位会重排，track_id 不会。
        var trackID: String?
        /// 世界坐标（厘米）。威胁距离按面板口径 `/(100)` 换成米，不用像素估。
        var world: (x: Double, y: Double, z: Double)?
    }

    private(set) var entities: [Entity] = []
    /// 当前会话已应用的名单指纹；名单修订时清除槽位上的旧英雄 id，避免旧头像残留。
    private var rosterFingerprint: String?
    private(set) var selfSlot: Int?
    private(set) var localSlots: Set<Int> = []
    private(set) var mapImage: CGImage?
    private(set) var mapID: Int?
    private(set) var mapName: String = ""
    private(set) var rotationDegrees: Double = 0
    private(set) var assetRotationDegrees: Double = 0
    private(set) var connected = false
    private(set) var lastMessageAt: Date?
    /// 面板设置镜像。读取方（出帧队列）与写入方（主线程镜像）不同线程，
    /// 所以赋值**只能**走 `setSettings`，别直接写这个属性。
    private(set) var settings = Settings()

    /// 线程安全地换一整套面板设置（悬浮窗运行中还会被定时重镜像调用）。
    func setSettings(_ value: Settings) {
        stateLock.lock(); defer { stateLock.unlock() }
        settings = value
    }
    /// 诊断计数：面板连上了没有、收到多少条消息、其中多少条带点位。
    private(set) var messagesReceived = 0
    private(set) var snapshotsReceived = 0
    private(set) var deltasReceived = 0
    private(set) var positionsSeen = 0

    private var socket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var baseURL: URL?
    private var panelToken: String = ""
    private var reconnectDelay: TimeInterval = 1
    private var lifecycleID: UInt64 = 0
    private var running = false
    private var tickTimer: DispatchSourceTimer?
    private let refreshQueue = DispatchQueue(label: "com.myrader.pip.source", qos: .utility)
    private var manifest: [[String: Any]] = []
    private var loadingTextureFor: Int?
    /// 每个槽位最后一次真正更新的时间，用来复刻面板的 TTL（敌方 25s / 我方 12s）。
    private var lastSeen: [Int: (updatedNS: UInt64, at: Date)] = [:]
    private var latestSelfCamp: Int?
    private var wireSessionID: String?
    private var channelGeneration: Int64?
    // ── 生死判定（客户 2026-10-27 规则 + 2026-10-29 自己多活）───────────────
    private static let lifeFreezeAll: TimeInterval = 1.5
    private static let lifeFreezePos: TimeInterval = 3.0
    private static let lifeGhostHold: TimeInterval = 1.0
    private static let lifeSmallHold: TimeInterval = 0.5
    private static let lifeBigMoveUV: Double = 0.006
    private static let lifeBigYaw: Double = 20
    private static let lifeSelfLingerExtra: TimeInterval = 8.0

    private struct LifeClock {
        var prevU = 0.0, prevV = 0.0, prevYaw = 0.0
        var hasPrev = false
        var lastChangeAt = Date.distantPast
        var lastPosChangeAt = Date.distantPast
        var ghostRef: (Double, Double, Double)?
    }
    private var lifeClocks: [Int: LifeClock] = [:]

    private enum Life { case live, ghost, dead }

    private func updateLifeClock(slot: Int, u: Double, v: Double, yaw: Double, now: Date) {
        var clock = lifeClocks[slot] ?? {
            var fresh = LifeClock()
            fresh.prevU = u; fresh.prevV = v; fresh.prevYaw = yaw; fresh.hasPrev = true
            fresh.lastChangeAt = now; fresh.lastPosChangeAt = now
            return fresh
        }()
        if clock.hasPrev {
            let moved = max(abs(u - clock.prevU), abs(v - clock.prevV))
            let turned = abs(((yaw - clock.prevYaw + 540).truncatingRemainder(dividingBy: 360)) - 180)
            if moved > 1e-9 { clock.lastPosChangeAt = now }
            if moved > 1e-9 || turned > 0.05 { clock.lastChangeAt = now }
        }
        clock.prevU = u; clock.prevV = v; clock.prevYaw = yaw; clock.hasPrev = true
        lifeClocks[slot] = clock
    }

    private func lifeState(u: Double, v: Double, yaw: Double, slot: Int, isSelf: Bool, now: Date) -> Life {
        var clock = lifeClocks[slot] ?? LifeClock()
        let linger: TimeInterval = isSelf ? Self.lifeSelfLingerExtra : 0
        let anyAge = now.timeIntervalSince(clock.lastChangeAt)
        if clock.ghostRef == nil, anyAge >= Self.lifeFreezeAll + linger {
            clock.ghostRef = (u, v, yaw)
        }
        if let ref = clock.ghostRef {
            let moved = max(abs(u - ref.0), abs(v - ref.1))
            let turned = abs(((yaw - ref.2 + 540).truncatingRemainder(dividingBy: 360)) - 180)
            if moved >= Self.lifeBigMoveUV || turned >= Self.lifeBigYaw {
                clock.ghostRef = nil
                lifeClocks[slot] = clock
                return .live
            }
        }
        let result: Life
        if anyAge >= Self.lifeFreezeAll + Self.lifeGhostHold + linger { result = .dead }
        else if anyAge >= Self.lifeFreezeAll + linger { result = .ghost }
        else if now.timeIntervalSince(clock.lastPosChangeAt) >= Self.lifeFreezePos + linger { result = .ghost }
        else { result = .live }
        lifeClocks[slot] = clock
        return result
    }

    private var yawWindows: [Int: [Double]] = [:]
    private var yawStamps: [Int: UInt64] = [:]
    /// 底图标定：`map` 字段缺失时用它把世界坐标换算成归一化坐标
    /// （与面板网页 `worldToMap` 同一套公式）。
    private var levelCenter: CGPoint?
    private var levelSize: CGSize?
    /// 本局是否认到过自己（＝面板 `hasBoundSelfThisSession`）。一旦认到，+90° 组合旋转
    /// 本局不再随「这一刻有没有自己」开关 —— 否则丢包瞬间整图会跳 90° 再跳回来。
    private var hasBoundSelfThisSession = false
    /// 粘性"自己"（面板 resolveBoundSelf 的三个状态量）
    private var boundSelfKey: String?
    private var boundSelfEntity: Entity?
    private var boundSelfSlot: Int?
    private var boundSelfSince = Date.distantPast
    private var boundSelfLastSeen = Date.distantPast
    /// 视点平滑/外推（面板 VIEW_TAU_MS / VIEW_EXTRAPOLATE_MAX_MS 那套）。
    /// 数据约 10Hz、出帧 30fps：不补这一步，转身就是"一格一格跳"。
    private var previousViewSample: (u: Double, v: Double, yaw: Double, ns: UInt64, at: Date)?
    private var currentViewSample: (u: Double, v: Double, yaw: Double, ns: UInt64, at: Date)?
    private var smoothedView: (u: Double, v: Double, yaw: Double)?
    /// 自己是怎么认出来的：轨道 / 引擎 / 面板槽（排障行直接显示）
    private enum BindingSource: String { case track = "轨道", engine = "引擎", panelSlot = "面板槽" }
    private var bindingSource: BindingSource?
    private var lastRenderAt: Date?
    private static let viewTau: TimeInterval = 0.090
    private static let viewExtrapolateMax: TimeInterval = 0.140
    private static let viewYawDeadZone: Double = 0.15
    private static let viewMaxYawRate: Double = 1080
    private static let selfSwitchDebounce: TimeInterval = 0.4
    private static let selfResolveHold: TimeInterval = 8.0
    /// 引擎给的 `self_slot` 连续报到同一个人几次才采纳。
    /// 面板同款（它要求 2 条一致）：开局准备阶段引擎偶尔先指到队友身上，
    /// 不加这条就会"刚进游戏把队友画成我"，过一会儿才自己纠回来。
    private static let engineSelfConfirmHits = 2
    private var pendingEngineSelfSlot: Int?
    private var pendingEngineSelfSlotHits = 0
    /// ＝面板 `followHold`：自己短暂消失（丢包/换局瞬间）时沿用上一帧视点，画面不许猛跳。
    private var lastSelfView: (u: Double, v: Double, yaw: Double)?
    /// URLSession 回调和后台出帧队列并行；所有可见帧状态统一用这把锁保护。
    private let stateLock = NSLock()

    var onUpdate: (() -> Void)?

    init() {
        // PiP 的底图必须能够在切到游戏后独立工作；先读包内清单，网络只负责补充/更新。
        if let url = Bundle.main.url(forResource: "manifest", withExtension: "json", subdirectory: "Maps")
            ?? Bundle.main.url(forResource: "manifest", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let maps = object["maps"] as? [[String: Any]] {
            manifest = maps
        }
    }

    /// 当前底图的宽高比。画中画出图尺寸按它调整，底图就能刚好铺满、不留黑边。
    /// 底图还没加载出来时按正方形处理（现有地图纹理都是 1024×1024）。
    var contentAspect: CGFloat {
        stateLock.lock(); defer { stateLock.unlock() }
        if let image = mapImage, image.height > 0 {
            return CGFloat(image.width) / CGFloat(image.height)
        }
        return 1
    }

    // MARK: - 生命周期

    func start(panelURL: URL, panelToken: String) {
        stateLock.lock()
        lifecycleID &+= 1
        let id = lifecycleID
        running = true
        baseURL = panelURL
        self.panelToken = panelToken

        // 面板的 WebSocket 有来源校验：必须带 Origin 且与 Host 同源；
        // 非 public 模式还要 ?token=。原生客户端两者都不带，会被 403 拒掉
        // （表现就是：地图画得出来，但一个人都没有）。这里两样都补上。
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = true
        configuration.httpShouldSetCookies = true
        configuration.httpCookieStorage = HTTPCookieStorage()
        session = URLSession(configuration: configuration)

        if tickTimer == nil {
            let timer = DispatchSource.makeTimerSource(queue: refreshQueue)
            timer.schedule(deadline: .now() + 2, repeating: 2.0, leeway: .milliseconds(100))
            timer.setEventHandler { [weak self] in self?.refreshSession() }
            timer.resume()
            tickTimer = timer
        }
        stateLock.unlock()
        connect(id: id)
        refreshSession()
    }

    func stop() {
        stateLock.lock(); defer { stateLock.unlock() }
        lifecycleID &+= 1
        running = false
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        session?.invalidateAndCancel()
        session = nil
        tickTimer?.setEventHandler {}
        tickTimer?.cancel()
        tickTimer = nil
        baseURL = nil
        panelToken = ""
        mapID = nil
        mapImage = nil
        loadingTextureFor = nil
        levelCenter = nil
        levelSize = nil
        connected = false
        entities = []
        lastSeen.removeAll()
        wireSessionID = nil
        channelGeneration = nil
        yawWindows.removeAll()
        yawStamps.removeAll()
        hasBoundSelfThisSession = false
        lastSelfView = nil
        boundSelfKey = nil
        boundSelfEntity = nil
        boundSelfSlot = nil
        onUpdate?()
    }

    // MARK: - WebSocket

    private func connect(id: UInt64) {
        guard let base = baseURL else { return }
        exchangeTokenIfPossible(base: base) { [weak self] in
            guard let self, self.isCurrent(id) else { return }
            self.openSocket(base, id: id)
        }
    }

    private func isCurrent(_ id: UInt64) -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return running && lifecycleID == id
    }

    /// public 模式下面板用一次性 token 换会话 cookie；非 public 模式会返回 404，
    /// 这时直接靠 URL 上的 ?token= 通过校验，两条路都留着。
    private func exchangeTokenIfPossible(base: URL, completion: @escaping () -> Void) {
        guard let session, !panelToken.isEmpty else {
            completion()
            return
        }
        let url = base.appendingPathComponent("api/v1/auth/exchange")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(originHeader(for: base), forHTTPHeaderField: "Origin")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["token": panelToken])
        session.dataTask(with: request) { _, _, _ in
            // 不把建 WS 的关键路径投回主 RunLoop；进入 PiP 后主线程可能被系统节流。
            completion()
        }.resume()
    }

    private func originHeader(for base: URL) -> String {
        "http://\(base.host ?? "127.0.0.1"):\(base.port ?? 80)"
    }

    private func openSocket(_ panelURL: URL, id: UInt64) {
        guard isCurrent(id) else { return }
        guard let session else { return }
        var components = URLComponents(url: panelURL, resolvingAgainstBaseURL: false)
        components?.scheme = "ws"
        components?.path = "/api/v1/ws"
        components?.query = panelToken.isEmpty ? nil : "token=\(panelToken)"
        guard let url = components?.url else { return }

        var request = URLRequest(url: url)
        request.setValue(originHeader(for: panelURL), forHTTPHeaderField: "Origin")
        let task = session.webSocketTask(with: request)
        socket = task
        task.resume()
        receiveLoop(task, id: id)
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask, id: UInt64) {
        task.receive { [weak self] result in
            guard let self else { return }
            guard self.isCurrent(id) else { return }
            switch result {
            case let .failure(error):
                self.connected = false
                self.socket = nil
                self.onUpdate?()
                // 面板重启（引擎重启）后会断开，退避重连。
                let delay = min(self.reconnectDelay, 8)
                self.reconnectDelay = min(self.reconnectDelay * 2, 8)
                self.refreshQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self, self.isCurrent(id) else { return }
                    self.connect(id: id)
                }
                _ = error
            case let .success(message):
                self.reconnectDelay = 1
                self.connected = true
                self.lastMessageAt = Date()
                switch message {
                case let .string(text):
                    self.handle(text)
                case let .data(data):
                    if let text = String(data: data, encoding: .utf8) { self.handle(text) }
                @unknown default:
                    break
                }
                self.receiveLoop(task, id: id)
            }
        }
    }

    func handle(_ text: String) {
        stateLock.lock(); defer { stateLock.unlock() }
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kind = object["kind"] as? String else { return }
        messagesReceived += 1

        if let sessionID = object["session_id"] as? String {
            if let previous = wireSessionID, previous != sessionID {
                clearPositionState()
            }
            wireSessionID = sessionID
        }

        switch kind {
        case "hello":
            let payload = object["payload"] as? [String: Any] ?? [:]
            applyRoster(payload["binding"] as? [String: Any])
            if let positions = payload["positions"] as? [[String: Any]]
                ?? payload["payload"] as? [[String: Any]] {
                applyPositions(positions, merge: false)
            }
        case "snapshot":
            snapshotsReceived += 1
            let payload = object["payload"] as? [String: Any] ?? [:]
            if let positions = payload["positions"] as? [[String: Any]]
                ?? object["positions"] as? [[String: Any]] {
                applyPositions(positions, merge: false)
            }
        case "position_delta":
            // 实时更新走的是 position_delta（按槽位增量下发）。
            // 之前只认 snapshot，等于开一次悬浮窗就把画面焊死在那一刻。
            deltasReceived += 1
            let payload = object["payload"] as? [String: Any] ?? [:]
            if let positions = payload["positions"] as? [[String: Any]] {
                applyPositions(positions, merge: true)
            }
        case "map_roster":
            // 引擎把自身槽位放在 payload.binding 里（不是 payload 顶层）。
            let payload = object["payload"] as? [String: Any] ?? [:]
            applySessionMetadata(payload["session"] as? [String: Any])
            applyRoster(
                payload["binding"] as? [String: Any] ?? payload,
                fingerprint: rosterFingerprint(for: payload)
            )
        case "session_status":
            let payload = object["payload"] as? [String: Any] ?? [:]
            applySessionMetadata(payload)
        default:
            break
        }
        onUpdate?()
    }

    private func clearPositionState() {
        entities.removeAll()
        lastSeen.removeAll()
        yawWindows.removeAll()
        yawStamps.removeAll()
        selfSlot = nil
        localSlots.removeAll()
        latestSelfCamp = nil
        positionsSeen = 0
        // 换局/换图：+90° 组合旋转、跟随视点、粘住的"自己"都必须重来
        hasBoundSelfThisSession = false
        lastSelfView = nil
        boundSelfKey = nil
        boundSelfEntity = nil
        boundSelfSlot = nil
        boundSelfSince = .distantPast
        boundSelfLastSeen = .distantPast
        pendingEngineSelfSlot = nil
        pendingEngineSelfSlotHits = 0
        previousViewSample = nil
        currentViewSample = nil
        smoothedView = nil
        lastRenderAt = nil
        rosterFingerprint = nil
    }

    private func applySessionMetadata(_ session: [String: Any]?) {
        guard let session else { return }
        if let generation = (session["channel_generation"] as? NSNumber)?.int64Value {
            if let previous = channelGeneration, previous != generation {
                clearPositionState()
            }
            channelGeneration = generation
        }
        if let map = (session["map_id"] as? NSNumber)?.intValue, map > 0 {
            if mapID != map {
                clearPositionState()
                mapID = map
                mapImage = nil
                loadingTextureFor = nil
            }
        } else if session["map_id"] is NSNull || (session["status"] as? String) == "ended" {
            clearPositionState()
            mapID = nil
            mapImage = nil
            loadingTextureFor = nil
        }
        loadPackagedTextureIfAvailable()
    }

    private func applyRoster(_ roster: [String: Any]?, fingerprint: String? = nil) {
        guard let roster else { return }
        if let fingerprint, rosterFingerprint != fingerprint {
            // map_roster 的槽位绑定可能在同一 session 内修订。旧 position_delta
            // 可能不带 agent_id，不能把旧槽位的英雄继续沿用到新玩家。
            entities = entities.map { entity in
                var cleared = entity
                cleared.agentID = nil
                return cleared
            }
            rosterFingerprint = fingerprint
        }
        if let slot = roster["self_slot"] as? Int {
            selfSlot = slot
        }
        if let slots = roster["local_slots"] as? [Int] {
            localSlots = Set(slots)
        }
    }

    private func rosterFingerprint(for payload: [String: Any]) -> String? {
        let value = payload["roster"] ?? payload["binding"] ?? payload
        guard JSONSerialization.isValidJSONObject(value) else { return nil }
        return try? String(
            data: JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
            encoding: .utf8
        )
    }

    /// `merge == false`：整份替换（snapshot）；
    /// `merge == true`：按槽位增量更新（position_delta），未出现的槽位保持原值。
    private func applyPositions(_ rows: [[String: Any]], merge: Bool) {
        let now = Date()
        var bySlot: [Int: Entity] = [:]
        if merge {
            for entity in entities { bySlot[entity.slot] = entity }
        }
        for row in rows {
            guard let slot = row["slot"] as? Int else { continue }
            guard let point = normalizedPoint(row) else { continue }
            let updatedNS = timestamp(from: row["updated_ns"])
            if let prior = bySlot[slot], updatedNS > 0, prior.updatedNS > updatedNS {
                continue
            }
            if merge, let prior = lastSeen[slot], prior.updatedNS == updatedNS {
                // 没有新数据：保留原时间戳，交给 TTL 判定
                continue
            } else {
                lastSeen[slot] = (updatedNS, now)
            }
            updateLifeClock(slot: slot, u: point.u, v: point.v,
                            yaw: (row["yaw"] as? Double) ?? 0, now: now)
            bySlot[slot] = Entity(
                slot: slot,
                u: point.u,
                v: point.v,
                yaw: stableYaw(slot: slot, raw: (row["yaw"] as? Double) ?? 0, updatedNS: updatedNS),
                updatedNS: updatedNS,
                campID: row["camp_id"] as? Int ?? bySlot[slot]?.campID,
                name: row["display_name"] as? String ?? bySlot[slot]?.name,
                agentID: (row["agent_id"] as? Int) ?? bySlot[slot]?.agentID,
                fresh: (row["fresh"] as? Bool) ?? true,
                trackID: (row["track_id"] as? String) ?? bySlot[slot]?.trackID,
                world: worldPoint(row) ?? bySlot[slot]?.world
            )
        }
        let next = bySlot.values.sorted { $0.slot < $1.slot }

        // 引擎 roster 没给自身槽位时，用面板里存的「选自己」结果兜底。
        if selfSlot == nil, let preferred = settings.selfSlotPreference {
            selfSlot = preferred
        }
        // 自己是谁：每次数据更新重算一次（面板 selfCandidate + resolveBoundSelf 的粘性规则）
        updateBoundSelf(in: next)
        let selfEntity = currentSelf(in: next)
        if let selfEntity, let camp = selfEntity.campID { latestSelfCamp = camp }
        // 注：**不**把 selfEntity.slot 写回 selfSlot（那是身份互换的根因）

        // 存活：**删人只由判死规则决定**（lifeState），这里只做内存回收。
        // 旧版是"敌方静默 25s / 我方 12s 就删"，买枪阶段会把活人删掉（客户实报"第二回合人不画了"）。
        let filtered = next.filter { entity in
            guard let seen = lastSeen[entity.slot] else { return true }
            return now.timeIntervalSince(seen.at) < 300
        }
        entities = filtered
        positionsSeen = filtered.count
    }

    /// 世界坐标（引擎单位＝厘米）。面板的威胁距离就是世界坐标差 `/(100)`。
    private func worldPoint(_ row: [String: Any]) -> (x: Double, y: Double, z: Double)? {
        guard let world = row["world"] as? [String: Any],
              let x = (world["x"] as? NSNumber)?.doubleValue,
              let y = (world["y"] as? NSNumber)?.doubleValue else { return nil }
        return (x, y, (world["z"] as? NSNumber)?.doubleValue ?? 0)
    }

    private func timestamp(from value: Any?) -> UInt64 {
        if let number = value as? NSNumber { return UInt64(number.stringValue) ?? 0 }
        if let string = value as? String { return UInt64(string) ?? 0 }
        return 0
    }

    private func stableYaw(slot: Int, raw: Double, updatedNS: UInt64) -> Double {
        let normalized = ((raw.truncatingRemainder(dividingBy: 360)) + 360)
            .truncatingRemainder(dividingBy: 360)
        if updatedNS > 0, yawStamps[slot] == updatedNS {
            return yawWindows[slot]?.last ?? normalized
        }
        let window = yawWindows[slot] ?? []
        let base = window.last ?? normalized
        let delta = ((normalized - base + 540).truncatingRemainder(dividingBy: 360)) - 180
        let unwrapped = base + delta
        var next = window + [unwrapped]
        if next.count > 5 { next.removeFirst(next.count - 5) }
        yawWindows[slot] = next
        if updatedNS > 0 { yawStamps[slot] = updatedNS }
        let median = next.sorted()[next.count / 2]
        return ((median.truncatingRemainder(dividingBy: 360)) + 360)
            .truncatingRemainder(dividingBy: 360)
    }

    /// 与面板 `roleForPoint` 同一套判定：先按「自己是谁」认自己，再按阵营分敌我。
    /// `selfEntity` 由 `resolveSelf` 给出（track_id 优先，槽位兜底），不要各写一套。
    private func role(for entity: Entity, self selfEntity: Entity?, in pool: [Entity]) -> Role {
        if let selfEntity, entity.slot == selfEntity.slot { return .own }
        guard let mine = entity.campID else { return .unknown }
        // 认不出我方阵营时宁可不画（灰点），也不许"猜一个 1"——猜错就是整片反色
        guard let own = ownCamp(in: pool) else { return .unknown }
        return mine == own ? .team : .enemy
    }

    private func allowed(_ role: Role, _ entity: Entity) -> Bool {
        if !entity.fresh && !settings.filterDead { return false }
        switch role {
        case .own: return settings.filterSelf
        case .team: return settings.filterTeam
        case .enemy: return settings.filterEnemy
        case .unknown: return true
        }
    }

    /// 面板优先用 `map.u/v`；缺失时用世界坐标 + 底图标定换算，
    /// 与前端 `worldToMap` 完全一致：
    /// `u = 0.5 - (x - cx) / sx`，`v = 0.5 - (y - cy) / sy`。
    private func normalizedPoint(_ row: [String: Any]) -> (u: Double, v: Double)? {
        if let map = row["map"] as? [String: Any],
           let u = map["u"] as? Double, let v = map["v"] as? Double,
           u.isFinite, v.isFinite {
            return (u, v)
        }
        guard let center = levelCenter, let size = levelSize,
              size.width != 0, size.height != 0,
              let world = row["world"] as? [String: Any],
              let x = world["x"] as? Double, let y = world["y"] as? Double else { return nil }
        let u = 0.5 - (x - Double(center.x)) / Double(size.width)
        let v = 0.5 - (y - Double(center.y)) / Double(size.height)
        guard u.isFinite, v.isFinite else { return nil }
        return (u, v)
    }

    // MARK: - 地图清单 / 底图

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        return value as? Double
    }

    private func manifestEntry(for mapID: Int) -> [String: Any]? {
        manifest.first {
            ($0["map_id"] as? Int) == mapID || ($0["map_id"] as? NSNumber)?.intValue == mapID
        }
    }

    /// 清单字段 → 当前底图口径。
    ///
    /// ⚠️ 两条装载路径（HTTP `refreshSession → ensureTexture` 与 WS
    /// `applySessionMetadata → loadPackagedTextureIfAvailable`）**必须都走这里**：
    /// 曾经只有 WS 那条路会设 `assetRotationDegrees`，于是先到的那条路决定底图转不转
    /// —— Ascent 是 180°、Bind 是 -90°，漏了就整图与人物错开。
    /// 调用方已持有 `stateLock`（本方法不再加锁，NSLock 非递归）。
    @discardableResult
    func loadManifestFields(mapID: Int) -> Bool {
        guard let entry = manifestEntry(for: mapID) else { return false }
        mapName = (entry["name"] as? String) ?? ""
        rotationDegrees = Self.number(entry["default_rotation_degrees"]) ?? 0
        // ⚠️ 底图资产旋转：面板口径 = background_rotation_degrees ?? image_rotation_degrees。
        // 这一句**只能有一个出处**（两条装载路径共用本函数）：
        // 漏了它 → 底图按 0° 画、人物按 manifest 口径画 → Ascent(180°)/Bind(-90°) 整图错开。
        assetRotationDegrees = Self.number(entry["background_rotation_degrees"])
            ?? Self.number(entry["image_rotation_degrees"])
            ?? rotationDegrees
        if let center = entry["level_center"] as? [String: Any] {
            levelCenter = CGPoint(x: Self.number(center["x"]) ?? 0, y: Self.number(center["y"]) ?? 0)
        }
        if let size = entry["level_size"] as? [String: Any] {
            levelSize = CGSize(width: Self.number(size["x"]) ?? 0, height: Self.number(size["y"]) ?? 0)
        }
        return true
    }

    private func refreshSession() {
        guard let base = baseURL else { return }
        if manifest.isEmpty { loadManifest(base) }
        let url = base.appendingPathComponent("api/v1/session")
        activeSession().dataTask(with: url) { [weak self] data, _, _ in
            guard let self, let data,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            let mapID = object["map_id"] as? Int
            self.refreshQueue.async {
                self.stateLock.lock()
                if mapID != self.mapID {
                    self.mapID = mapID
                    self.mapImage = nil
                }
                self.stateLock.unlock()
                self.ensureTexture(base: base)
            }
        }.resume()
    }

    private func loadManifest(_ base: URL) {
        let url = base.appendingPathComponent("api/v1/maps/manifest")
        activeSession().dataTask(with: url) { [weak self] data, _, _ in
            guard let self, let data,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let maps = object["maps"] as? [[String: Any]] else { return }
            self.refreshQueue.async {
                self.stateLock.lock()
                self.manifest = maps
                self.stateLock.unlock()
                self.ensureTexture(base: base)
            }
        }.resume()
    }

    private func ensureTexture(base: URL) {
        stateLock.lock(); defer { stateLock.unlock() }
        guard mapImage == nil,
              let mapID,
              loadingTextureFor != mapID,
              let entry = manifest.first(where: {
                  ($0["map_id"] as? Int) == mapID || ($0["map_id"] as? NSNumber)?.intValue == mapID
              }),
              let texture = entry["texture_path"] as? String, !texture.isEmpty else { return }
        // 清单字段统一落地（见 loadManifestFields 的注释：两条装载路径不许分叉）
        loadManifestFields(mapID: mapID)
        loadingTextureFor = mapID
        if let localURL = Bundle.main.url(
            forResource: (texture as NSString).deletingPathExtension,
            withExtension: (texture as NSString).pathExtension.isEmpty ? "png" : (texture as NSString).pathExtension
        ) {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self, let data = try? Data(contentsOf: localURL),
                      let image = UIImage(data: data)?.cgImage else { return }
                self.refreshQueue.async {
                    self.stateLock.lock(); defer { self.stateLock.unlock() }
                    self.mapImage = image
                    self.loadingTextureFor = nil
                    self.onUpdate?()
                }
            }
            return
        }
        let url = base.appendingPathComponent("api/v1/maps/\(texture)")
        activeSession().dataTask(with: url) { [weak self] data, _, _ in
            guard let self, let data, let image = UIImage(data: data)?.cgImage else { return }
            self.refreshQueue.async {
                self.stateLock.lock(); defer { self.stateLock.unlock() }
                self.mapImage = image
                self.loadingTextureFor = nil
                self.onUpdate?()
            }
        }.resume()
    }

    /// 在 WebSocket 的 session_status 到达时同步加载包内地图，不等待云端图片请求。
    private func loadPackagedTextureIfAvailable() {
        guard let mapID,
              mapImage == nil,
              let entry = manifest.first(where: {
                  ($0["map_id"] as? Int) == mapID || ($0["map_id"] as? NSNumber)?.intValue == mapID
              }),
              let texture = entry["texture_path"] as? String else { return }
        let stem = (texture as NSString).deletingPathExtension
        let ext = (texture as NSString).pathExtension.isEmpty ? "png" : (texture as NSString).pathExtension
        guard let url = (Bundle.main.url(forResource: stem, withExtension: ext, subdirectory: "Maps")
            ?? Bundle.main.url(forResource: stem, withExtension: ext)),
              let data = try? Data(contentsOf: url),
              let image = UIImage(data: data)?.cgImage else { return }
        mapImage = image
        loadingTextureFor = nil
        // 同一个清单解析函数：ASSET 旋转值只在这里落地一次，两条路共用
        loadManifestFields(mapID: mapID)
    }

    private func activeSession() -> URLSession {
        session ?? URLSession.shared
    }

    // MARK: - 绘制

    /// 测试/诊断用：直接装一张底图。
    ///
    /// 生产路径的底图只由「云端/包内 manifest + 包内 PNG」决定，这个方法只是给
    /// 几何测试喂一张**已知图案**的图，好在像素层面证明「底图格子 ↔ 人物点」对齐。
    func installMapImage(_ image: CGImage?) {
        stateLock.lock(); defer { stateLock.unlock() }
        mapImage = image
        loadingTextureFor = mapID
    }

    #if DEBUG
    /// 测试用：读某槽位当前显示状态
    func debugLifeState(slot: Int) -> String {
        stateLock.lock(); defer { stateLock.unlock() }
        guard let e = entities.first(where: { $0.slot == slot }) else { return "none" }
        let selfEntity = currentSelf(in: entities)
        let role = role(for: e, self: selfEntity, in: entities)
        switch lifeState(u: e.u, v: e.v, yaw: e.yaw, slot: e.slot,
                         isSelf: role == .own, now: Date()) {
        case .live: return "live"
        case .ghost: return "ghost"
        case .dead: return "dead"
        }
    }
    #endif

    func draw(into context: CGContext, size: CGSize) {
        stateLock.lock(); defer { stateLock.unlock() }
        context.saveGState()
        // ⚠️ 必须先把用户空间翻成「y 向下」。
        // CG 位图上下文的用户空间是 y 向上，而出帧缓冲/系统小窗、以及面板 canvas 都是
        // y 向下：不翻就会把底图与人物画成**上下镜像**（v=0.25 跑到画面下方 62.5% 处，
        // 而底图同一行在 25% 处）—— 这正是「地图坐标与实际位置不符合」的主因之一。
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)

        context.setFillColor(red: 0.043, green: 0.055, blue: 0.086, alpha: 1)
        context.fill(CGRect(origin: .zero, size: size))

        let geometry = self.geometry(size: size)
        context.saveGState()
        context.concatenate(geometry.bitmapTransform.transform)
        drawMap(context, mapRect: geometry.mapRect)
        context.restoreGState()
        // 压暗底图：浅灰底图上再亮的标记也会糊；压暗之后标记就是画面里最亮的东西
        context.setFillColor(red: 0, green: 0, blue: 0, alpha: Palette.mapDimAlpha)
        context.fill(CGRect(origin: .zero, size: size))
        drawMarkers(context, size: size, geometry: geometry)
        if settings.diagnostics { drawDiagnostics(context, size: size) }
        context.restoreGState()
    }

    /// 小窗自带的一行状态：地图 / 自己是谁（怎么认出来的）/ 点位数 / 面板是否连着 / 朝向模式。
    /// 这一轮排障专用（`Settings.diagnostics`，下一版可关）：出问题时截一张图就能定位。
    private func drawDiagnostics(_ context: CGContext, size: CGSize) {
        let source: String
        if boundSelfKey == nil {
            source = "未认出"
        } else {
            source = (bindingSource ?? .engine).rawValue
        }
        let mode = settings.lockNorth ? "北向固定" : "跟随朝向"
        let map = mapID.map { "\(mapName.isEmpty ? "图" : "")#\($0)" } ?? "无图"
        let camp = ownCamp(in: entities).map { "队\($0)" } ?? "队?"
        let roster = localSlots.isEmpty ? "" : " 名单\(localSlots.count)"
        let page = settings.pageState.map { " · 网页:\($0)" } ?? ""
        let text = "图\(map) · 自己:\(source)\(boundSelfSlot.map { " 槽\($0)" } ?? "") · \(camp)\(roster)"
            + " · 点\(entities.count) · 面板\(connected ? "已连" : "未连") · \(mode)" + page
        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: UIColor(red: 0.62, green: 0.72, blue: 0.82, alpha: 0.95)
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let bounds = string.size()
        let origin = CGPoint(x: 6, y: size.height - bounds.height - 6)
        let backdrop = CGRect(x: 0, y: size.height - bounds.height - 10, width: min(size.width, bounds.width + 12), height: bounds.height + 8)
        context.setFillColor(red: 0.02, green: 0.03, blue: 0.05, alpha: 0.72)
        context.fill(backdrop)
        string.draw(at: origin)
    }

    // MARK: - 视口几何（＝面板网页 drawRadar() 的组合，顺序不可改）

    /// 面板 `SELECTED_PLAYER_ROTATION_DEGREES`：本局认到过自己就一直加 90°。
    private static let selectedPlayerRotationDegrees = 90.0
    /// 面板 `PLAYER_MARKER_HEADING_CORRECTION_DEGREES = -90`：游戏 yaw 的轴与原生地图
    /// 空间差 90°。少了这一项，方向指示整体偏 90° —— 表现为「跟随朝向时人也朝不上」。
    private static let headingCorrectionDegrees = -90.0
    /// 面板 `GLOBAL_VIEW_ROTATION_DEGREES = 0`
    private static let globalViewRotationDegrees = 0.0

    /// 二维仿射：`p' = (a·x + c·y + tx, b·x + d·y + ty)`，与 `CGAffineTransform` 同约定。
    /// 自己写一遍是为了让**组合顺序看得见**（`then` = 先做 self，再做 other）。
    private struct Affine {
        var a: CGFloat = 1, b: CGFloat = 0, c: CGFloat = 0, d: CGFloat = 1
        var tx: CGFloat = 0, ty: CGFloat = 0

        static func rotation(_ radians: CGFloat, about pivot: CGPoint) -> Affine {
            let cosine = cos(radians), sine = sin(radians)
            return Affine(a: cosine, b: sine, c: -sine, d: cosine,
                          tx: pivot.x - cosine * pivot.x + sine * pivot.y,
                          ty: pivot.y - sine * pivot.x - cosine * pivot.y)
        }

        static func translation(_ dx: CGFloat, _ dy: CGFloat) -> Affine {
            Affine(tx: dx, ty: dy)
        }

        func apply(_ point: CGPoint) -> CGPoint {
            CGPoint(x: a * point.x + c * point.y + tx,
                    y: b * point.x + d * point.y + ty)
        }

        func then(_ other: Affine) -> Affine {
            Affine(a: other.a * a + other.c * b,
                   b: other.b * a + other.d * b,
                   c: other.a * c + other.c * d,
                   d: other.b * c + other.d * d,
                   tx: other.a * tx + other.c * ty + other.tx,
                   ty: other.b * tx + other.d * ty + other.ty)
        }

        var transform: CGAffineTransform {
            CGAffineTransform(a: a, b: b, c: c, d: d, tx: tx, ty: ty)
        }
    }

    /// 一帧的视口几何：底图矩形、原生 UV → 小窗、方向指示角度。
    private struct Geometry {
        let mapRect: CGRect
        let centre: CGPoint
        let baseOrigin: CGPoint
        let baseViewRotation: CGFloat
        let pivot: CGPoint
        let selectedRotation: CGFloat
        let bitmapRotation: CGFloat

        /// 原生 UV 空间 → 小窗（人物/方向用；**不含**底图资产旋转）。
        var nativeTransform: Affine {
            Affine.rotation(baseViewRotation, about: baseOrigin)
                .then(.translation(centre.x - baseOrigin.x, centre.y - baseOrigin.y))
                .then(.rotation(selectedRotation, about: pivot))
        }

        /// 底图另加一层资产旋转（面板注释：这是**位图专属**校正，人物 UV 留在原生空间）。
        var bitmapTransform: Affine {
            Affine.rotation(bitmapRotation, about: centre).then(nativeTransform)
        }

        func raw(u: Double, v: Double) -> CGPoint {
            CGPoint(x: mapRect.minX + CGFloat(u) * mapRect.width,
                    y: mapRect.minY + CGFloat(v) * mapRect.height)
        }

        func point(u: Double, v: Double) -> CGPoint { nativeTransform.apply(raw(u: u, v: v)) }

        /// 方向指示在**屏幕**上的角度（弧度）＝面板 `markerAngleFor` 的原样搬运。
        func headingAngle(yaw: Double, defaultRotationDegrees: Double) -> CGFloat {
            let heading = CGFloat((yaw - defaultRotationDegrees) * .pi / 180)
            return heading + baseViewRotation + selectedRotation
                + CGFloat(PiPRadarSource.headingCorrectionDegrees * .pi / 180)
        }
    }

    /// 面板 `selfCandidate()`：track_id 优先，其次**引擎的 `binding.self_slot`**，
    /// 最后才是面板 localStorage 里存的槽位。
    ///
    /// ⚠️ 2026-10-12 修正（客户报"认错我 + 阵营搞反"）：
    /// 上一版把"面板存的槽位"排在引擎之前 —— 那是错的。面板源码自己写着
    /// 「引擎这个槽位是用本机角色出生点锚出来的，是权威」；而 `codev.display.selfSlot`
    /// 是**上一局/上个房间**的残留（换局槽位会重排）。一旦认成别人，
    /// `role()` 之前又拿"这个人的阵营"当我方阵营 → 整片敌我反色。
    private func selfCandidate(in pool: [Entity]) -> Entity? {
        // ① **引擎的 `binding.self_slot` 是权威**（面板源码原话：它是用本机角色出生点锚出来的）。
        //    2026-10-12 再次修正：上一版把 track/面板存的槽位排在它前面 ——
        //    那些是**上一局**的残留（槽位会重排），认成队友就会出现"把队友当成我"。
        if let slot = selfSlot, let match = pool.first(where: { $0.slot == slot }) {
            bindingSource = .engine
            return match
        }
        // ② track 绑定（面板写进 localStorage）。**必须落在引擎给的本机名单里**：
        //    名单还没到（localSlots 为空）就先用"上一局的残留"= 开局几秒把队友认成自己
        //    （客户实测就是这个表现）。宁可这几秒没有"自己"，也不要认错人。
        if let track = settings.selfTrackID, !track.isEmpty, trackBindingIsCurrent,
           !localSlots.isEmpty,
           let bound = pool.first(where: { $0.trackID == track }),
           localSlots.contains(bound.slot) {
            bindingSource = .track
            return bound
        }
        // ③ 面板存的槽位：同样要求落在引擎给的本机名单里（名单未知时不阻拦）
        if storedSlotBelongsToCurrentMatch, !localSlots.isEmpty,
           let slot = settings.selfSlotPreference,
           let match = pool.first(where: { $0.slot == slot }),
           localSlots.contains(match.slot) {
            bindingSource = .panelSlot
            return match
        }
        return nil
    }

    /// 面板存的槽位属于**本局**吗？面板写入时会把 `channel_generation` 一起存进
    /// `codev.display.selfGen`；取不到 generation（引擎没发）时不阻拦，取到且对不上就作废。
    private var storedSlotBelongsToCurrentMatch: Bool {
        guard let stored = settings.selfTrackGen, !stored.isEmpty,
              let generation = channelGeneration else { return true }
        return stored == String(generation)
    }

    /// 我方阵营：**优先用引擎给的 `local_slots`（本机五人槽位）**，其次才是自己那个点的阵营。
    /// 用自己点的阵营当基准有个致命弱点：自己一旦认错，整片敌我就会反色。
    private func ownCamp(in pool: [Entity]) -> Int? {
        if !localSlots.isEmpty {
            var tally: [Int: Int] = [:]
            for entity in pool where localSlots.contains(entity.slot) {
                if let camp = entity.campID { tally[camp, default: 0] += 1 }
            }
            if let best = tally.max(by: { $0.value < $1.value }) { return best.key }
        }
        return currentSelf(in: pool)?.campID ?? latestSelfCamp ?? settings.selfCamp
    }

    /// 面板 `selfTrackUsable()` 的等价物：**有 gen 才校验 gen**；拿不到 channel_generation
    /// 时不能因为"对不上"就把绑定丢掉 —— 面板在拿不到 gen 时压根不写 `selfGen`，
    /// 小窗上一版要求必须匹配，等于把面板认出来的人又丢掉（表现为不跟随、点还画成队友色）。
    private var trackBindingIsCurrent: Bool {
        guard let stored = settings.selfTrackGen, !stored.isEmpty,
              let generation = channelGeneration else { return true }
        return stored == String(generation)
    }

    /// 面板 `resolveBoundSelf()`：自己是谁必须**粘住**。
    ///  · 换人（或闪成别人）要连续稳定 400ms 才采纳，否则视点会往别人身上甩一下再甩回来；
    ///  · 自己暂时没有数据（阵亡/观战/丢包）时 8s 内不掉锚，否则跟随与旋转会失去目标。
    private func updateBoundSelf(in pool: [Entity]) {
        let candidate = selfCandidate(in: pool)
        let key = candidate.map { entity -> String in
            if let track = entity.trackID, !track.isEmpty { return "t:\(track)" }
            return "s:\(entity.slot)"
        }
        let now = Date()
        if key != nil { boundSelfLastSeen = now }
        if key == boundSelfKey {
            boundSelfEntity = candidate
            if let candidate { boundSelfSlot = candidate.slot }
            return
        }
        if boundSelfKey != nil, now.timeIntervalSince(boundSelfSince) < Self.selfSwitchDebounce { return }
        if key == nil, boundSelfKey != nil,
           now.timeIntervalSince(boundSelfLastSeen) < Self.selfResolveHold { return }
        // 引擎值"连续一致"才采纳（首次绑定与换人时都算）：开局那一下的抖动不许改绑定
        if bindingSource == .engine, let slot = candidate?.slot {
            if slot == pendingEngineSelfSlot { pendingEngineSelfSlotHits += 1 } else { pendingEngineSelfSlot = slot; pendingEngineSelfSlotHits = 1 }
            if pendingEngineSelfSlotHits < Self.engineSelfConfirmHits { return }
        } else {
            pendingEngineSelfSlot = nil
            pendingEngineSelfSlotHits = 0
        }
        boundSelfKey = key
        boundSelfSince = now
        boundSelfEntity = candidate
        if let candidate { boundSelfSlot = candidate.slot }
        hasBoundSelfThisSession = (key != nil)
    }

    /// 粘住的"自己"在这一帧里的最新位置；暂时没数据时沿用上一次（面板同款）。
    private func currentSelf(in pool: [Entity]) -> Entity? {
        if let slot = boundSelfSlot, let live = pool.first(where: { $0.slot == slot }) { return live }
        if let track = boundSelfEntity?.trackID, !track.isEmpty,
           let live = pool.first(where: { $0.trackID == track }) { return live }
        return boundSelfEntity
    }

    /// 每帧算一次"显示用视点"：先按两次采样外推补足 10Hz 的空档，再按时间常数平滑。
    /// 调用方已持有 stateLock。
    private func updateSmoothedView(live: Entity?, now: Date) -> (u: Double, v: Double, yaw: Double)? {
        if let live {
            if currentViewSample?.ns != live.updatedNS {
                previousViewSample = currentViewSample
                currentViewSample = (live.u, live.v, live.yaw, live.updatedNS, now)
            }
        }
        guard let currentSample = currentViewSample else { return nil }
        var target = (u: currentSample.u, v: currentSample.v, yaw: currentSample.yaw)
        if let previous = previousViewSample, currentSample.ns > previous.ns {
            let seconds = Double(currentSample.ns - previous.ns) / 1_000_000_000
            let age = min(Self.viewExtrapolateMax, max(0, now.timeIntervalSince(currentSample.at)))
            if seconds > 0.008, seconds < 0.6, age > 0.001 {
                let vu = (currentSample.u - previous.u) / seconds
                let vv = (currentSample.v - previous.v) / seconds
                let vyaw = ((currentSample.yaw - previous.yaw + 540).truncatingRemainder(dividingBy: 360) - 180) / seconds
                if abs(vyaw) <= Self.viewMaxYawRate, abs(vu) < 2, abs(vv) < 2 {
                    target.u += vu * age
                    target.v += vv * age
                    target.yaw += vyaw * age
                }
            }
        }
        let dt = min(0.15, max(1.0 / 120, now.timeIntervalSince(lastRenderAt ?? now)))
        lastRenderAt = now
        guard var smoothed = smoothedView else {
            smoothedView = target
            return target
        }
        let alpha = 1 - exp(-dt / Self.viewTau)
        smoothed.u += (target.u - smoothed.u) * alpha
        smoothed.v += (target.v - smoothed.v) * alpha
        let delta = ((target.yaw - smoothed.yaw + 540).truncatingRemainder(dividingBy: 360)) - 180
        if abs(delta) > Self.viewYawDeadZone { smoothed.yaw += delta * alpha }
        smoothedView = smoothed
        return smoothed
    }

    private func geometry(size: CGSize) -> Geometry {
        // 面板口径：宽度 ≤640 时内边距 4px（手机全屏雷达），否则 32px。
        let inset: CGFloat = size.width <= 640 ? 4 : 32
        let side = max(1, min(size.width, size.height) - inset)
        let mapRect = CGRect(x: (size.width - side) / 2, y: (size.height - side) / 2,
                             width: side, height: side)
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)

        let liveSelf = currentSelf(in: entities)
        if liveSelf != nil { hasBoundSelfThisSession = true }
        // 视点：平滑外推后的自己（follow 关掉时不参与），其次上一帧兜底
        // （＝面板 followHold，丢包瞬间不许跳视角）
        let view: (u: Double, v: Double, yaw: Double)?
        if settings.follow {
            let smoothed = updateSmoothedView(live: liveSelf, now: Date())
            if let smoothed { lastSelfView = smoothed }
            view = smoothed ?? lastSelfView
        } else {
            smoothedView = nil
            lastRenderAt = nil
            view = nil
        }
        let following = view != nil
        let selfRaw: CGPoint = {
            guard following, let view else { return centre }
            return CGPoint(x: mapRect.minX + CGFloat(view.u) * mapRect.width,
                           y: mapRect.minY + CGFloat(view.v) * mapRect.height)
        }()
        let viewYaw = (following ? view?.yaw : nil) ?? 0
        // 跟随朝向（北向未锁）＝底图绕自己反向转，人永朝上；北向锁定时底图不动。
        let baseViewRotation: CGFloat = following && !settings.lockNorth
            ? CGFloat(-Double.pi / 2 - (viewYaw - rotationDegrees) * .pi / 180)
            : CGFloat(Self.globalViewRotationDegrees * .pi / 180)
        let baseOrigin = following ? selfRaw : centre
        // 认到过自己就一直加 90°（面板 hasBoundSelfThisSession），否则开局前底图是歪的。
        let selectedRotation = hasBoundSelfThisSession
            ? CGFloat(Self.selectedPlayerRotationDegrees * .pi / 180) : 0

        let baseAffine = Affine.rotation(baseViewRotation, about: baseOrigin)
            .then(.translation(centre.x - baseOrigin.x, centre.y - baseOrigin.y))
        let pivot: CGPoint
        if following {
            pivot = centre
        } else if hasBoundSelfThisSession, let view {
            pivot = baseAffine.apply(CGPoint(x: mapRect.minX + CGFloat(view.u) * mapRect.width,
                                             y: mapRect.minY + CGFloat(view.v) * mapRect.height))
        } else {
            pivot = centre
        }

        return Geometry(mapRect: mapRect, centre: centre, baseOrigin: baseOrigin,
                        baseViewRotation: baseViewRotation, pivot: pivot,
                        selectedRotation: selectedRotation,
                        bitmapRotation: CGFloat(assetRotationDegrees * .pi / 180))
    }

    private func drawMap(_ context: CGContext, mapRect: CGRect) {
        guard let image = mapImage else {
            drawGrid(context, in: mapRect)
            return
        }
        context.interpolationQuality = .high
        // 在「y 向下」的空间里 CGImage 会被上下画反：按 UIKit 的常规做法再翻一次，
        // 让底图像素 (0,0) 落在 mapRect 左上角 —— 与 u/v 同一个原点。
        // 底图在构建期已烧入「描边+发光」，暗底直接贴即可（与网页端同一张图）
        context.saveGState()
        context.translateBy(x: 0, y: mapRect.minY + mapRect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: mapRect)
        context.restoreGState()
    }

    private func drawMarkers(_ context: CGContext, size: CGSize, geometry: Geometry) {
        guard settings.players else { return }

        let base = min(size.width, size.height)
        let scale = settings.markerScale > 0.2 ? settings.markerScale : 1
        // 标记直径 ≈ 画布边长的 3.8%（原来 5.2%）：小窗里更干净，不再挡住地图细节
        let radius = max(2.5, base * 0.019 * CGFloat(scale))
        let selfEntity = currentSelf(in: entities)
        var nearestEnemy: (metres: Double, point: CGPoint)?

        for entity in entities {
            let role = role(for: entity, self: selfEntity, in: entities)
            guard allowed(role, entity) else { continue }
            // 判死（客户规则）：dead 不画，ghost 半透明（只在下面调 alpha）
            let life = lifeState(u: entity.u, v: entity.v, yaw: entity.yaw,
                                 slot: entity.slot, isSelf: role == .own, now: Date())
            guard life != .dead else { continue }
            context.saveGState()
            if life == .ghost { context.setAlpha(0.42) }
            defer { context.restoreGState() }
            let point = geometry.point(u: entity.u, v: entity.v)
            let colour = colour(for: role)
            // 面板 drawBallArrowMarker 的顺序：深色外圈 → 本体 → 亮描边 → 高光 →
            // （箭头最后画，且自带深色描边）
            let haloWidth = max(2.0, radius * 0.40)
            context.setFillColor(Palette.halo)
            context.fillEllipse(in: CGRect(
                x: point.x - radius - haloWidth, y: point.y - radius - haloWidth,
                width: (radius + haloWidth) * 2, height: (radius + haloWidth) * 2
            ))
            context.setFillColor(colour)
            context.fillEllipse(in: CGRect(
                x: point.x - radius, y: point.y - radius,
                width: radius * 2, height: radius * 2
            ))
            context.setStrokeColor(Palette.edge)
            context.setLineWidth(max(1.0, radius * 0.12))
            context.strokeEllipse(in: CGRect(
                x: point.x - radius, y: point.y - radius,
                width: radius * 2, height: radius * 2
            ))
            context.setFillColor(red: 1, green: 1, blue: 1, alpha: 0.42)
            context.fillEllipse(in: CGRect(
                x: point.x - radius * 0.5, y: point.y - radius * 0.52,
                width: radius * 0.44, height: radius * 0.44
            ))
            if role == .own {
                context.setStrokeColor(red: 1, green: 1, blue: 1, alpha: 0.95)
                context.setLineWidth(1.2)
                context.strokeEllipse(in: CGRect(
                    x: point.x - radius - 2.2, y: point.y - radius - 2.2,
                    width: (radius + 2.2) * 2, height: (radius + 2.2) * 2
                ))
            }
            // ⚠️ 方向指示**最后**画（面板 drawBallArrowMarker 也是这个顺序）：
            // 先画的话会被自己的白圈切成两截，看上去像断掉的指针。
            drawHeading(context, at: point, angle: geometry.headingAngle(yaw: entity.yaw, defaultRotationDegrees: rotationDegrees), radius: radius, colour: colour)
            // 英雄名/玩家名标签已整体下线（客户 2026-10-29）：引擎贴槽会整队错位，
            // 名字画出来只会误导。雷达只画点位 + 朝向 + 敌我颜色。
            _ = entity.agentID
            _ = entity.name
            if settings.threats, role == .enemy, let selfEntity,
               let metres = Self.distanceMeters(from: selfEntity, to: entity) {
                if nearestEnemy == nil || metres < nearestEnemy!.metres {
                    nearestEnemy = (metres, point)
                }
            }
        }

        // 面板「威胁增强」：把小窗里最近敌人的**真实距离**标出来（世界坐标 /100 = 米）。
        if settings.threats, let nearestEnemy {
            drawLabel(
                context,
                text: "\(Int(nearestEnemy.metres.rounded()))m",
                at: CGPoint(x: nearestEnemy.point.x, y: nearestEnemy.point.y - radius - 9)
            )
        }
    }

    /// 面板口径的威胁距离：世界坐标（引擎单位＝厘米）差 / 100 = 米。
    static func distanceMeters(from selfEntity: Entity, to other: Entity) -> Double? {
        guard let mine = selfEntity.world, let theirs = other.world else { return nil }
        let dx = (theirs.x - mine.x) / 100
        let dy = (theirs.y - mine.y) / 100
        let dz = (theirs.z - mine.z) / 100
        let metres = (dx * dx + dy * dy + dz * dz).squareRoot()
        return metres > 0.01 ? metres : nil
    }

    private func drawLabel(_ context: CGContext, text: String, at point: CGPoint) {
        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: UIColor(red: 1, green: 0.45, blue: 0.55, alpha: 1)
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        string.draw(at: CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2))
    }

    private func colour(for role: Role) -> CGColor {
        switch role {
        case .own: return Palette.selfColour
        case .team: return Palette.teamColour
        case .enemy: return Palette.enemyColour
        case .unknown: return Palette.unknownColour
        }
    }

    /// 方向指示：与面板 `drawBallArrowMarker` 一样画成实心三角，角度直接用**屏幕角度**。
    /// 这样朝向补偿（-90°）与视口旋转（base + selected）都只在一处生效，不会再被
    /// 「先在地图空间算方向、再套变换」这种写法吃掉一项。
    private func drawHeading(_ context: CGContext, at point: CGPoint, angle: CGFloat, radius: CGFloat, colour: CGColor) {
        context.saveGState()
        context.translateBy(x: point.x, y: point.y)
        context.rotate(by: angle)
        let tip = radius + max(4, radius * 0.85)
        let halfWidth = radius * 0.42
        // 先描深色边再画本体：细箭头压在浅灰底图上也能看清
        triangle(context, base: radius - 1 - 1.6, tip: tip + 1.6, halfWidth: halfWidth + 1.6, colour: Palette.halo)
        triangle(context, base: radius - 1, tip: tip, halfWidth: halfWidth, colour: colour)
        context.restoreGState()
    }

    private func triangle(_ context: CGContext, base: CGFloat, tip: CGFloat, halfWidth: CGFloat, colour: CGColor) {
        context.setFillColor(colour)
        context.beginPath()
        context.move(to: CGPoint(x: tip, y: 0))
        context.addLine(to: CGPoint(x: base, y: -halfWidth))
        context.addLine(to: CGPoint(x: base, y: halfWidth))
        context.closePath()
        context.fillPath()
    }

    private func drawGrid(_ context: CGContext, in rect: CGRect) {
        context.setStrokeColor(red: 0.22, green: 0.32, blue: 0.42, alpha: 0.45)
        context.setLineWidth(1)
        let step: CGFloat = max(12, rect.width / 8)
        var x = rect.minX
        while x <= rect.maxX {
            context.beginPath(); context.move(to: CGPoint(x: x, y: rect.minY))
            context.addLine(to: CGPoint(x: x, y: rect.maxY)); context.strokePath()
            x += step
        }
        var y = rect.minY
        while y <= rect.maxY {
            context.beginPath(); context.move(to: CGPoint(x: rect.minX, y: y))
            context.addLine(to: CGPoint(x: rect.maxX, y: y)); context.strokePath()
            y += step
        }
    }
}
