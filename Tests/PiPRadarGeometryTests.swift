//
//  PiPRadarGeometryTests.swift
//  PhoenixTests
//
//  画中画小窗的**像素级**验收标准（这是「地图坐标与实际位置不符合」的机械定义）：
//
//   · 底图上代表归一化格子 (u,v) 的那块像素，渲染后必须和「站在 (u,v) 的人物点」
//     落在同一像素上；且 v 增大 = 屏幕上往下（与面板网页 drawRadar() 同向）。
//   · 跟随朝向（heading-up）时自己必须在画面正中心，方向指示必须指屏幕正上方。
//   · 北向固定（lockNorth）时底图一动不动，方向指示随朝向转。
//   · 自己是谁：优先按 track_id（与面板同代），槽位只做兜底。
//
//  口径来源：App 二进制里内嵌的面板网页（drawRadar / markerAngleFor）。
//  常量：GLOBAL_VIEW_ROTATION_DEGREES=0、SELECTED_PLAYER_ROTATION_DEGREES=90、
//        PLAYER_MARKER_HEADING_CORRECTION_DEGREES=-90。
//  任何把底图旋转值（asset_rotation）、+90°、-90°、或上下方向写错/漏写的改动，
//  都会在这里变红。
//

import CoreGraphics
import UIKit
import XCTest
@testable import Phoenix

final class PiPRadarGeometryTests: XCTestCase {

    private let canvas = CGSize(width: 512, height: 512)
    /// 底图会被 `Palette.mapDimAlpha` 压暗，所以合成色块的期望值要按同一系数算
    private var magenta: (Int, Int, Int) {
        let value = Int((255 * (1 - Double(PiPRadarSource.Palette.mapDimAlpha))).rounded())
        return (value, 0, value)
    }
    /// 人物标记的颜色**不能**硬编码：`CGColor(red:green:blue:)` 是 generic RGB，
    /// 写进 DeviceRGB 位图会被转换（`#ffd84d` 实际落成 (255,221,95)）。
    /// 所以这里用 1×1 探针量出真实值，并直接引用源码里的同一批颜色对象。
    private var selfYellow = (255, 216, 77)
    private var teamBlue = (79, 169, 255)
    private var enemyRed = (255, 45, 69)

    private let mapIDAscent = 1      // manifest: image_rotation_degrees = 180
    private let mapIDBind = 2        // manifest: image_rotation_degrees = -90
    private let mapIDIcebox = 1003   // manifest: image_rotation_degrees = 0

    // MARK: - 注入（一律走真实的 WS 报文格式）

    private func row(slot: Int, u: Double, v: Double, yaw: Double = 90, ns: UInt64 = 100,
                     track: String? = nil, camp: Int? = 1,
                     world: (x: Double, y: Double, z: Double)? = nil) -> String {
        var parts = ["\"slot\":\(slot)",
                     "\"map\":{\"u\":\(u),\"v\":\(v)}",
                     "\"yaw\":\(yaw)",
                     "\"updated_ns\":\(ns)",
                     "\"fresh\":true"]
        if let camp { parts.append("\"camp_id\":\(camp)") }
        if let track = track { parts.append("\"track_id\":\"\(track)\"") }
        if let world = world {
            parts.append("\"world\":{\"x\":\(world.x),\"y\":\(world.y),\"z\":\(world.z)}")
        }
        return "{" + parts.joined(separator: ",") + "}"
    }

    private func hello(_ source: PiPRadarSource, mapID: Int, slot: Int? = nil,
                       localSlots: [Int] = [], generation: Int = 7) {
        var binding = ""
        if let slot {
            binding = ",\"binding\":{\"self_slot\":\(slot)"
                + (localSlots.isEmpty ? "" : ",\"local_slots\":[")
                + localSlots.map(String.init).joined(separator: ",")
                + (localSlots.isEmpty ? "" : "]") + "}"
        } else if !localSlots.isEmpty {
            binding = ",\"binding\":{\"local_slots\":["
                + localSlots.map(String.init).joined(separator: ",") + "]}"
        }
        source.handle("{\"schema_version\":1,\"session_id\":\"geo\",\"kind\":\"map_roster\","
            + "\"payload\":{\"session\":{\"map_id\":\(mapID),\"channel_generation\":\(generation),"
            + "\"status\":\"live\"}\(binding)}}")
    }

    /// 默认发一条；生产里引擎的 `self_slot` 要"两连一致"才被采纳（面板同款），
    /// 所以凡是要验"自己"的用例统一走这个：同内容再补一条（时间戳 +1）。
    private func positionsSettled(_ source: PiPRadarSource, _ rows: [String]) {
        positions(source, rows)
        // 同内容、同时间戳再发一条：只为了让"引擎 self_slot 两连一致"成立，
        // **不改 ns**（改了会打乱后面的时间顺序，把别的用例顶坏）。
        positions(source, rows, kind: "position_delta")
    }

    private func positions(_ source: PiPRadarSource, _ rows: [String], kind: String = "snapshot") {
        source.handle("{\"schema_version\":1,\"session_id\":\"geo\",\"kind\":\"\(kind)\","
            + "\"payload\":{\"positions\":[\(rows.joined(separator: ","))]}}")
    }

    private func settings(headingUp: Bool, follow: Bool = true, labels: Bool = false,
                          selfCamp: Int? = 1) -> PiPRadarSource.Settings {
        var value = PiPRadarSource.Settings()
        // 默认给一个"面板里存过的阵营"：真实环境下面板/引擎总会给（selfCamp 或 local_slots）。
        // 要测"完全没有阵营信息"的场景就显式传 nil。
        value.selfCamp = selfCamp
        value.players = true
        value.threats = false
        value.labels = labels
        value.markerScale = 1
        value.follow = follow
        value.lockNorth = !headingUp
        value.diagnostics = false
        return value
    }

    override func setUpWithError() throws {
        selfYellow = try probe(PiPRadarSource.Palette.selfColour)
        teamBlue = try probe(PiPRadarSource.Palette.teamColour)
        enemyRed = try probe(PiPRadarSource.Palette.enemyColour)
    }

    /// 把某个 CGColor 真正写进 DeviceRGB 像素后读回来（色彩空间转换后的真实值）。
    private func probe(_ colour: CGColor) throws -> (Int, Int, Int) {
        let context = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
            bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(colour)
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        let pixels = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        return (Int(pixels[0]), Int(pixels[1]), Int(pixels[2]))
    }

    // MARK: - 像素工具

    private struct Frame {
        let pixels: [UInt8]
        let width: Int
        let height: Int

        func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let index = (y * width + x) * 4
            return (Int(pixels[index]), Int(pixels[index + 1]), Int(pixels[index + 2]))
        }

        func matches(_ value: (Int, Int, Int), _ colour: (Int, Int, Int), tolerance: Int = 8) -> Bool {
            abs(value.0 - colour.0) <= tolerance
                && abs(value.1 - colour.1) <= tolerance
                && abs(value.2 - colour.2) <= tolerance
        }

        /// 最多的**连续**同色像素个数（行）。
        private func runLength(row: Int, colour: (Int, Int, Int)) -> Int {
            var best = 0, current = 0
            for x in 0..<width {
                if matches(rgb(x, row), colour) { current += 1; best = max(best, current) } else { current = 0 }
            }
            return best
        }

        /// 最多的**连续**同色像素个数（列）。
        private func runLength(column: Int, colour: (Int, Int, Int)) -> Int {
            var best = 0, current = 0
            for y in 0..<height {
                if matches(rgb(column, y), colour) { current += 1; best = max(best, current) } else { current = 0 }
            }
            return best
        }

        /// 圆形标记的中心直径与圆心。
        ///
        /// 为什么不用质心：方向指示的三角形/线段与圆同色，会把质心带偏 (~0.7r)。
        /// 标记的轴线恒过圆心，所以「最长的一行」和「最长的一列」一定交在圆心，
        /// 且圆的直径行/列是最长的连续段 —— 与箭头指向无关。
        func disc(of colour: (Int, Int, Int)) -> (centre: CGPoint, diameter: Int)? {
            var rowRuns = [Int](), columnRuns = [Int]()
            for y in 0..<height { rowRuns.append(runLength(row: y, colour: colour)) }
            for x in 0..<width { columnRuns.append(runLength(column: x, colour: colour)) }
            guard let bestRowRun = rowRuns.max(), let bestColumnRun = columnRuns.max(),
                  bestRowRun > 0, bestColumnRun > 0 else { return nil }
            // 圆的弦长在圆心附近是「平顶」：取所有达到最大值的行/列求平均 = 圆心。
            // 只取第一个最大值会被抗锯齿带偏 3~4px（实测）。
            let rows = rowRuns.indices.filter { rowRuns[$0] >= bestRowRun }
            let columns = columnRuns.indices.filter { columnRuns[$0] >= bestColumnRun }
            let centre = CGPoint(
                x: Double(columns.reduce(0, +)) / Double(columns.count),
                y: Double(rows.reduce(0, +)) / Double(rows.count)
            )
            return (centre, min(bestRowRun, bestColumnRun))
        }

        func count(of colour: (Int, Int, Int)) -> Int {
            var total = 0
            for y in 0..<height { for x in 0..<width where matches(rgb(x, y), colour) { total += 1 } }
            return total
        }

        func centroid(of colour: (Int, Int, Int)) -> CGPoint? {
            var sumX = 0.0, sumY = 0.0, count = 0
            for y in 0..<height {
                for x in 0..<width where matches(rgb(x, y), colour) {
                    sumX += Double(x); sumY += Double(y); count += 1
                }
            }
            guard count > 0 else { return nil }
            return CGPoint(x: sumX / Double(count), y: sumY / Double(count))
        }

        func farthestPixel(from point: CGPoint, colour: (Int, Int, Int)) -> CGPoint? {
            var best: CGPoint?
            var bestDistance = -1.0
            for y in 0..<height {
                for x in 0..<width where matches(rgb(x, y), colour) {
                    let dx = Double(x) - Double(point.x), dy = Double(y) - Double(point.y)
                    let distance = dx * dx + dy * dy
                    if distance > bestDistance { bestDistance = distance; best = CGPoint(x: x, y: y) }
                }
            }
            return best
        }
    }

    private func render(_ source: PiPRadarSource) throws -> Frame {
        let width = Int(canvas.width), height = Int(canvas.height)
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        source.draw(into: context, size: canvas)
        let buffer = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        return Frame(pixels: Array(UnsafeBufferPointer(start: buffer, count: width * height * 4)),
                     width: width, height: height)
    }

    // MARK: - 几何口径（与面板网页同式）

    /// 面板口径：宽度 ≤640 时内边距 4px（手机端全屏雷达），否则 32px。
    private func mapRect(_ size: CGSize) -> CGRect {
        let inset: CGFloat = size.width <= 640 ? 4 : 32
        let side = min(size.width, size.height) - inset
        return CGRect(x: (size.width - side) / 2, y: (size.height - side) / 2, width: side, height: side)
    }

    private func rawPoint(u: Double, v: Double, size: CGSize) -> CGPoint {
        let rect = mapRect(size)
        return CGPoint(x: rect.minX + CGFloat(u) * rect.width,
                       y: rect.minY + CGFloat(v) * rect.height)
    }

    /// 面板口径：`follow` 关掉时 `selfRaw = [画布中心]` → +90° 的支点就是**画布中心**
    /// （不是自己所在的位置）。所以不跟随时，任何归一化坐标的落点都要再绕中心转 90°。
    private func screenPointWhenNotFollowing(u: Double, v: Double) -> CGPoint {
        let centre = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
        return rotate(rawPoint(u: u, v: v, size: canvas), around: centre, by: .pi / 2)
    }

    private func rotate(_ point: CGPoint, around pivot: CGPoint, by radians: Double) -> CGPoint {
        let dx = Double(point.x - pivot.x), dy = Double(point.y - pivot.y)
        let cosine = cos(radians), sine = sin(radians)
        return CGPoint(x: Double(pivot.x) + dx * cosine - dy * sine,
                       y: Double(pivot.y) + dx * sine + dy * cosine)
    }

    /// 底图比原生 UV 空间多绕画布中心转 asset 度（面板注释：位图专属校正）。
    /// 所以「原生 (u,v) 对应的那块底图像素」= 把 raw(u,v) 绕中心**反转** asset 度。
    private func assetPatchCentre(u: Double, v: Double, assetDegrees: Double, size: CGSize) -> CGPoint {
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        return rotate(rawPoint(u: u, v: v, size: size), around: centre, by: -assetDegrees * .pi / 180)
    }

    private func assetPixel(_ point: CGPoint, size: CGSize, imageSize: Int = 1024) -> CGPoint {
        let rect = mapRect(size)
        return CGPoint(x: (point.x - rect.minX) / rect.width * CGFloat(imageSize),
                       y: (point.y - rect.minY) / rect.height * CGFloat(imageSize))
    }

    /// 合成底图：全黑 + 一个 40×40 品红色块，色块中心在 `patchCentre`（底图自身像素坐标，左上原点）。
    private func assetImage(patchCentre: CGPoint, imageSize: Int = 1024) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: imageSize, height: imageSize,
            bitsPerComponent: 8, bytesPerRow: imageSize * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: imageSize, height: imageSize))
        context.setFillColor(red: 1, green: 0, blue: 1, alpha: 1)
        // CG 位图上下文的用户空间 y 向上，而底图像素坐标左上原点 → 画色块时翻一次。
        let userY = CGFloat(imageSize) - patchCentre.y
        context.fill(CGRect(x: patchCentre.x - 20, y: userY - 20, width: 40, height: 40))
        return try XCTUnwrap(context.makeImage())
    }

    // MARK: - 1. 底图方向：两条装载路径都必须落地

    func testManifestRotationIsAppliedOnBothLoadPaths() throws {
        // 路径 A：WS（session_status → applySessionMetadata → 包内底图）
        let websocket = PiPRadarSource()
        websocket.handle("{\"schema_version\":1,\"session_id\":\"geo\",\"kind\":\"session_status\","
            + "\"payload\":{\"map_id\":\(mapIDBind),\"channel_generation\":1,\"status\":\"live\"}}")
        XCTAssertEqual(websocket.assetRotationDegrees, -90,
                       "Bind 的底图方向是 -90°，WS 路径必须把 manifest 的 image_rotation_degrees 落地")

        // 路径 B：HTTP（/api/v1/session → ensureTexture 用的同一段清单解析）
        let http = PiPRadarSource()
        XCTAssertTrue(http.loadManifestFields(mapID: mapIDIcebox), "包内清单里应有 map_id=1003")
        XCTAssertEqual(http.assetRotationDegrees, 0, "Icebox 的底图方向是 0°")
        XCTAssertTrue(http.loadManifestFields(mapID: mapIDAscent), "包内清单里应有 map_id=1")
        XCTAssertEqual(http.assetRotationDegrees, 180,
                       "Ascent=180°：HTTP 路径漏这一句 = 底图按 0° 画、人物按 180° 算 → 整图错开")
        XCTAssertEqual(http.rotationDegrees, 90, "default_rotation_degrees 也要落地")
    }

    // MARK: - 2. 底图像素 vs 人物点：必须落在同一像素，且 v 向下

    func testBitmapPixelAndMarkerAgreeForTheSameCell() throws {
        let u = 0.25, v = 0.25
        for (mapID, asset) in [(mapIDAscent, 180.0), (mapIDBind, -90.0), (mapIDIcebox, 0.0)] {
            let source = PiPRadarSource()
            source.setSettings(settings(headingUp: true, follow: false))
            hello(source, mapID: mapID)
            XCTAssertEqual(source.assetRotationDegrees, asset, "地图 \(mapID) 的底图方向")

            let patch = assetPatchCentre(u: u, v: v, assetDegrees: asset, size: canvas)
            source.installMapImage(try assetImage(patchCentre: assetPixel(patch, size: canvas)))

            let expected = rawPoint(u: u, v: v, size: canvas)

            // ① 底图上那一块像素，渲染后必须落在 raw(u,v)
            let bitmapOnly = try render(source)
            let painted = try XCTUnwrap(bitmapOnly.centroid(of: magenta),
                                        "地图 \(mapID)：帧里找不到底图色块")
            XCTAssertEqual(Double(painted.x), Double(expected.x), accuracy: 3,
                           "地图 \(mapID)：底图格子与归一化坐标错位（X）")
            XCTAssertEqual(Double(painted.y), Double(expected.y), accuracy: 3,
                           "地图 \(mapID)：底图格子与归一化坐标错位（Y）")

            // ② 站在同一格子上的人，必须压在同一像素
            positionsSettled(source, [row(slot: 1, u: u, v: v, camp: 1)])
            let withEntity = try render(source)
            let marker = try XCTUnwrap(withEntity.disc(of: teamBlue), "地图 \(mapID)：没画出队友点").centre
            XCTAssertEqual(Double(marker.x), Double(expected.x), accuracy: 3,
                           "地图 \(mapID)：人物点没压在它该在的底图格子上（X）")
            XCTAssertEqual(Double(marker.y), Double(expected.y), accuracy: 3,
                           "地图 \(mapID)：人物点没压在它该在的底图格子上（Y）")

            // ③ v 增大 = 屏幕上往下（当前实现是上下镜像）
            XCTAssertLessThan(marker.y, canvas.height / 2, "地图 \(mapID)：v=0.25 必须落在画面上半")
            XCTAssertLessThan(marker.x, canvas.width / 2, "地图 \(mapID)：u=0.25 必须落在画面左半")
        }
    }

    // MARK: - 3. 跟随朝向：自己在中心、方向指示指正上方

    func testHeadingUpPutsSelfInTheCentreAndTheArrowUp() throws {
        for yaw in [0.0, 45, 90, 137, 270, 359] {
            let source = PiPRadarSource()
            source.setSettings(settings(headingUp: true))
            hello(source, mapID: mapIDIcebox, slot: 0)
            positionsSettled(source, [row(slot: 0, u: 0.42, v: 0.63, yaw: yaw)])

            let frame = try render(source)
            let disc = try XCTUnwrap(frame.disc(of: selfYellow), "yaw=\(yaw)：没画出自机")
            XCTAssertEqual(Double(disc.centre.x), Double(canvas.width / 2), accuracy: 3,
                           "yaw=\(yaw)：跟随朝向时自机必须在画面中心（X）")
            XCTAssertEqual(Double(disc.centre.y), Double(canvas.height / 2), accuracy: 3,
                           "yaw=\(yaw)：跟随朝向时自机必须在画面中心（Y）")

            let tip = try XCTUnwrap(frame.farthestPixel(from: disc.centre, colour: selfYellow))
            let dx = Double(tip.x - disc.centre.x), dy = Double(tip.y - disc.centre.y)
            let distance = (dx * dx + dy * dy).squareRoot()
            // 圆点半径 ≈ 512 × 0.019 ≈ 9.7px，箭头尖 ≈ 18px；超过 13px 才证明方向指示伸到圆外
            XCTAssertGreaterThan(distance, 13,
                                 "yaw=\(yaw)：自机方向指示没画出来（距离 \(distance)）")
            let angle = atan2(dy, dx) * 180 / .pi
            XCTAssertEqual(angle, -90, accuracy: 6,
                           "yaw=\(yaw)：跟随朝向时方向指示必须指屏幕正上方（得到 \(angle)°）")
        }
    }

    // MARK: - 4. 北向固定：底图一动不动，只有方向指示在转

    func testNorthLockedKeepsBitmapStillAndArrowFollowsHeading() throws {
        func frame(yaw: Double) throws -> Frame {
            let source = PiPRadarSource()
            source.setSettings(settings(headingUp: false))
            hello(source, mapID: mapIDIcebox, slot: 0)
            let asset = source.assetRotationDegrees
            let patch = assetPatchCentre(u: 0.3, v: 0.7, assetDegrees: asset, size: canvas)
            source.installMapImage(try assetImage(patchCentre: assetPixel(patch, size: canvas)))
            positionsSettled(source, [row(slot: 0, u: 0.42, v: 0.63, yaw: yaw)])
            return try render(source)
        }

        // 底图：yaw 变了也必须还在同一像素（地图固定的）
        let first = try frame(yaw: 0)
        let second = try frame(yaw: 180)
        let firstPatch = try XCTUnwrap(first.centroid(of: magenta))
        let secondPatch = try XCTUnwrap(second.centroid(of: magenta))
        XCTAssertEqual(Double(firstPatch.x), Double(secondPatch.x), accuracy: 1.5,
                       "北向固定时底图不许跟着朝向转（X）")
        XCTAssertEqual(Double(firstPatch.y), Double(secondPatch.y), accuracy: 1.5,
                       "北向固定时底图不许跟着朝向转（Y）")

        // 方向指示：面板口径 = 朝向相对底图默认朝向的差角
        for (yaw, expected) in [(90.0, 0.0), (180.0, 90.0), (0.0, -90.0)] {
            let image = try frame(yaw: yaw)
            let disc = try XCTUnwrap(image.disc(of: selfYellow)).centre
            let tip = try XCTUnwrap(image.farthestPixel(from: disc, colour: selfYellow))
            let angle = atan2(Double(tip.y - disc.y), Double(tip.x - disc.x)) * 180 / .pi
            XCTAssertEqual(angle, expected, accuracy: 8,
                           "北向固定 yaw=\(yaw) 时方向指示应为 \(expected)°（得到 \(angle)°）")
        }
    }

    // MARK: - 5. 自己是谁：**引擎 self_slot 优先**，track/面板槽位兜底

    /// 引擎给了 self_slot 时，track 绑定不许盖过它（否则认成队友 → "把队友识别成我"）
    func testEngineSelfSlotWinsOverTrackBinding() throws {
        let source = PiPRadarSource()
        var value = settings(headingUp: true, follow: false)
        value.selfTrackID = "T-7"
        value.selfTrackGen = "7"
        source.setSettings(value)
        hello(source, mapID: mapIDIcebox, slot: 0)
        positionsSettled(source, [row(slot: 0, u: 0.8, v: 0.5, camp: 1),
                           row(slot: 3, u: 0.2, v: 0.5, track: "T-7", camp: 1)])

        let frame = try render(source)
        let selfDisc = try XCTUnwrap(frame.disc(of: selfYellow), "没画出自机").centre
        let expected = screenPointWhenNotFollowing(u: 0.8, v: 0.5)   // 引擎的槽 0
        XCTAssertEqual(Double(selfDisc.x), Double(expected.x), accuracy: 3,
                       "引擎 self_slot 是权威：track 绑定（上一局残留）不许盖过它")
        XCTAssertEqual(Double(selfDisc.y), Double(expected.y), accuracy: 3)
    }

    /// 引擎没给 self_slot 时，track 绑定才生效
    func testTrackBindingUsedWhenEngineHasNoSelfSlot() throws {
        let source = PiPRadarSource()
        var value = settings(headingUp: true, follow: false)
        value.selfTrackID = "T-7"
        value.selfTrackGen = "7"
        source.setSettings(value)
        // 引擎不给 self_slot，但给了本机名单 → track 绑定才允许采信
        hello(source, mapID: mapIDIcebox, localSlots: [0, 3])
        positionsSettled(source, [row(slot: 0, u: 0.8, v: 0.5, camp: 1),
                           row(slot: 3, u: 0.2, v: 0.5, track: "T-7", camp: 1)])

        let frame = try render(source)
        let selfDisc = try XCTUnwrap(frame.disc(of: selfYellow), "没画出自机").centre
        let expected = screenPointWhenNotFollowing(u: 0.2, v: 0.5)
        XCTAssertEqual(Double(selfDisc.x), Double(expected.x), accuracy: 3)
        XCTAssertEqual(Double(selfDisc.y), Double(expected.y), accuracy: 3)
    }

    func testSelfBindingFallsBackToSlotWhenTrackIsNotInThisMatch() throws {
        let source = PiPRadarSource()
        var value = settings(headingUp: true, follow: false)
        value.selfTrackID = "T-7"
        value.selfTrackGen = "999"        // 上一局留下的绑定 → 本局必须作废
        source.setSettings(value)
        hello(source, mapID: mapIDIcebox, slot: 0)
        positionsSettled(source, [row(slot: 0, u: 0.8, v: 0.5, camp: 1),
                           row(slot: 3, u: 0.2, v: 0.5, track: "T-7", camp: 1)])

        let frame = try render(source)
        let selfDisc = try XCTUnwrap(frame.disc(of: selfYellow), "没画出自机").centre
        let expected = screenPointWhenNotFollowing(u: 0.8, v: 0.5)
        XCTAssertEqual(Double(selfDisc.x), Double(expected.x), accuracy: 3,
                       "跨局残留的 track 绑定必须作废，回落到引擎给的 self_slot")
        XCTAssertEqual(Double(selfDisc.y), Double(expected.y), accuracy: 3)
    }

    // MARK: - 5b. 全 9 张打包底图 × 多格子：地图有没有"放错位置/放错角度/放错比例"

    /// 这是对「上一版地图放错位置」最直接的回归：把色块放在**该图真实旋转值**对应的
    /// 底图像素上，然后在 8 个分散格子上比对"色块落点"与"站在该格子的人"。
    /// · 整体平移错 → 每个格子都偏同样的量
    /// · 缩放错/旋转错 → 越靠边的格子偏得越多
    /// · 上下或左右镜像 → 对角格子必然出现在错误象限
    /// 三种错法都会在这里变红。
    func testEveryPackagedMapAlignsAtManyCells() throws {
        let maps: [(id: Int, asset: Double)] = [
            (mapIDAscent, 180), (mapIDBind, -90), (mapIDIcebox, 0), (1004, 180),
            (1009, -90), (1010, -90), (1011, -90), (1012, 180), (1013, -90),
        ]
        let cells: [(Double, Double)] = [
            (0.05, 0.05), (0.10, 0.25), (0.25, 0.10), (0.50, 0.50),
            (0.75, 0.90), (0.90, 0.30), (0.30, 0.90), (0.95, 0.95),
        ]
        for map in maps {
            for cell in cells {
                let source = PiPRadarSource()
                source.setSettings(settings(headingUp: true, follow: false))
                hello(source, mapID: map.id)
                XCTAssertEqual(source.assetRotationDegrees, map.asset,
                               "地图 \(map.id) 的底图旋转值应与 manifest 一致")
                let patch = assetPatchCentre(u: cell.0, v: cell.1, assetDegrees: map.asset, size: canvas)
                source.installMapImage(try assetImage(patchCentre: assetPixel(patch, size: canvas)))

                let expected = rawPoint(u: cell.0, v: cell.1, size: canvas)
                let bitmapOnly = try render(source)
                let painted = try XCTUnwrap(bitmapOnly.centroid(of: magenta),
                                            "地图 \(map.id) 格子 \(cell)：找不到底图色块")
                XCTAssertEqual(Double(painted.x), Double(expected.x), accuracy: 3,
                               "地图 \(map.id) 格子 \(cell)：底图放错位置（X）")
                XCTAssertEqual(Double(painted.y), Double(expected.y), accuracy: 3,
                               "地图 \(map.id) 格子 \(cell)：底图放错位置（Y）")

                positionsSettled(source, [row(slot: 1, u: cell.0, v: cell.1, camp: 1)])
                let withEntity = try render(source)
                let marker = try XCTUnwrap(withEntity.disc(of: teamBlue),
                                           "地图 \(map.id) 格子 \(cell)：没画出人物点").centre
                XCTAssertEqual(Double(marker.x), Double(expected.x), accuracy: 3,
                               "地图 \(map.id) 格子 \(cell)：人物点与底图不在同一格子（X）")
                XCTAssertEqual(Double(marker.y), Double(expected.y), accuracy: 3,
                               "地图 \(map.id) 格子 \(cell)：人物点与底图不在同一格子（Y）")
            }
        }
    }

    // MARK: - 5c. 自己是谁：粘性 + 不因缺 gen 而丢绑定

    func testSelfBindingAcceptsTrackWhenGenerationIsUnknown() throws {
        // 引擎不给 channel_generation、也不给 self_slot 时，面板压根不写 selfGen → 小窗不许因此拒绝绑定
        let source = PiPRadarSource()
        var value = settings(headingUp: true, follow: false)
        value.selfTrackID = "T-7"
        value.selfTrackGen = "999"          // 拿不到本局 generation → 这个 gen 无从校验
        source.setSettings(value)
        source.handle("{\"schema_version\":1,\"session_id\":\"geo\",\"kind\":\"map_roster\","
            + "\"payload\":{\"session\":{\"map_id\":\(mapIDIcebox),\"status\":\"live\"},"
            + "\"binding\":{\"local_slots\":[3]}}}")
        positionsSettled(source, [row(slot: 0, u: 0.8, v: 0.5, camp: 1),
                           row(slot: 3, u: 0.2, v: 0.5, track: "T-7", camp: 1)])

        let frame = try render(source)
        let selfDisc = try XCTUnwrap(frame.disc(of: selfYellow), "没画出自机").centre
        let expected = screenPointWhenNotFollowing(u: 0.2, v: 0.5)
        XCTAssertEqual(Double(selfDisc.x), Double(expected.x), accuracy: 3,
                       "引擎没给 self_slot 时，拿不到 generation 也不能成为丢掉 track 绑定的理由")
        XCTAssertEqual(Double(selfDisc.y), Double(expected.y), accuracy: 3)
    }

    func testSelfStaysAnchoredWhileItMomentarilyDisappears() throws {
        // 面板 resolveBoundSelf：自己暂时没数据（丢包/阵亡瞬间）8s 内不掉锚，
        // 否则跟随与旋转失去目标 → 画面猛跳（用户看到的是"地图位置突然变了"）
        let source = PiPRadarSource()
        source.setSettings(settings(headingUp: true))
        hello(source, mapID: mapIDIcebox, slot: 0)
        let asset = source.assetRotationDegrees
        let patch = assetPatchCentre(u: 0.35, v: 0.65, assetDegrees: asset, size: canvas)
        source.installMapImage(try assetImage(patchCentre: assetPixel(patch, size: canvas)))

        positionsSettled(source, [row(slot: 0, u: 0.42, v: 0.63, yaw: 30),
                           row(slot: 1, u: 0.60, v: 0.40, camp: 1)])
        let anchored = try XCTUnwrap(try render(source).centroid(of: magenta))

        // 这一帧里"自己"没了（只发别人）→ 视点必须冻住，不能跳回未跟随的视角
        positionsSettled(source, [row(slot: 1, u: 0.60, v: 0.40, camp: 1)])
        let duringGap = try XCTUnwrap(try render(source).centroid(of: magenta))

        XCTAssertEqual(Double(anchored.x), Double(duringGap.x), accuracy: 2,
                       "自己暂时消失时视点不许跳（X）")
        XCTAssertEqual(Double(anchored.y), Double(duringGap.y), accuracy: 2,
                       "自己暂时消失时视点不许跳（Y）")
    }

    // MARK: - 5d. 出帧预算：真实底图 + 11 个点位，每帧必须留够 30fps 的余量

    func testFrameBudgetForThirtyFPSWithRealMap() throws {
        let source = PiPRadarSource()
        source.setSettings(settings(headingUp: true))
        hello(source, mapID: 1013, slot: 0)          // 天枢云阙：包内最大的底图（546KB）
        var rows = [row(slot: 0, u: 0.50, v: 0.50, yaw: 42)]
        for slot in 1...10 {
            rows.append(row(slot: slot, u: 0.18 + Double(slot) * 0.06, v: 0.28 + Double(slot) * 0.045,
                            camp: slot % 2 == 0 ? 1 : 2))
        }
        positionsSettled(source, rows)
        for _ in 0..<5 { _ = try render(source) }                    // 预热
        let frames = 60
        let started = CFAbsoluteTimeGetCurrent()
        for _ in 0..<frames { _ = try render(source) }
        let msPerFrame = (CFAbsoluteTimeGetCurrent() - started) * 1000 / Double(frames)
        print(String(format: "PERF 每帧 %.2fms（33.3ms = 30fps 预算）", msPerFrame))
        XCTAssertLessThan(msPerFrame, 33, "每帧必须留出 30fps 的余量，实测 \(msPerFrame)ms")
    }

    // MARK: - 5e. 视点平滑：10Hz 数据 → 30fps 画面，不许"一格一格跳"

    func testViewIsInterpolatedInsteadOfJumping() throws {
        let source = PiPRadarSource()
        source.setSettings(settings(headingUp: true))
        hello(source, mapID: mapIDIcebox, slot: 0)
        let asset = source.assetRotationDegrees
        let patch = assetPatchCentre(u: 0.30, v: 0.70, assetDegrees: asset, size: canvas)
        source.installMapImage(try assetImage(patchCentre: assetPixel(patch, size: canvas)))

        positionsSettled(source, [row(slot: 0, u: 0.40, v: 0.50, yaw: 20, ns: 1000)])
        let before = try XCTUnwrap(try render(source).centroid(of: magenta))

        // 自己瞬移 0.10（≈51px）：数据是"跳"的，但画面必须**平滑过去**
        positions(source, [row(slot: 0, u: 0.50, v: 0.50, yaw: 20, ns: 2000)], kind: "position_delta")
        let after = try XCTUnwrap(try render(source).centroid(of: magenta))
        let shift = Double(hypot(after.x - before.x, after.y - before.y))

        XCTAssertGreaterThan(shift, 0.5, "视点必须动（不然就是冻住不动）")
        XCTAssertLessThan(shift, 25, "视点必须插值过去，不能一帧跳满 51px（实测 \(shift)px）")
        print(String(format: "SMOOTH 单帧位移 %.1fpx（原始跳变 51px）", shift))
    }

    // MARK: - 5f. 认错"我" + 阵营反色（2026-10-12 客户报的真事）

    func testEngineSelfSlotBeatsStalePanelSlot() throws {
        // 面板 localStorage 里存的是上一局的槽位（3），引擎本局给的是 8
        let source = PiPRadarSource()
        var value = settings(headingUp: true, follow: false)
        value.selfSlotPreference = 3
        source.setSettings(value)
        hello(source, mapID: mapIDIcebox, slot: 8)
        positionsSettled(source, [row(slot: 3, u: 0.2, v: 0.5, camp: 2),
                           row(slot: 8, u: 0.8, v: 0.5, camp: 1)])

        let frame = try render(source)
        let selfDisc = try XCTUnwrap(frame.disc(of: selfYellow), "没画出自机").centre
        let expected = screenPointWhenNotFollowing(u: 0.8, v: 0.5)   // 引擎那一个（槽 8）
        XCTAssertEqual(Double(selfDisc.x), Double(expected.x), accuracy: 3,
                       "引擎的 self_slot 是权威；面板存的旧槽位不许盖过它")
        XCTAssertEqual(Double(selfDisc.y), Double(expected.y), accuracy: 3)
    }

    func testCampsDoNotFlipWhenPanelSlotPointsAtAnEnemy() throws {
        // 回归：面板槽位指向**敌人**时，整片敌我不能反色
        let source = PiPRadarSource()
        var value = settings(headingUp: true, follow: false)
        value.selfSlotPreference = 3          // 上一局的残留，本局是敌人
        source.setSettings(value)
        hello(source, mapID: mapIDIcebox, slot: 8, localSlots: [8, 9])   // 引擎：本机五人是 8/9，阵营 1
        positionsSettled(source, [row(slot: 3, u: 0.2, v: 0.5, camp: 2),      // 敌人
                           row(slot: 8, u: 0.5, v: 0.5, camp: 1),      // 我
                           row(slot: 9, u: 0.8, v: 0.5, camp: 1)])     // 队友

        let frame = try render(source)
        let selfDisc = try XCTUnwrap(frame.disc(of: selfYellow), "没画出自机").centre
        XCTAssertEqual(Double(selfDisc.x), Double(screenPointWhenNotFollowing(u: 0.5, v: 0.5).x), accuracy: 3,
                       "自己必须是引擎给的槽 8")
        XCTAssertNotNil(frame.disc(of: teamBlue), "队友（同阵营 1）必须画成队友色")
        XCTAssertNotNil(frame.disc(of: enemyRed), "敌人（阵营 2）必须画成敌人色")
        // 只许有一个"自己"：黄色像素总量不超过单个标记的量级（两个会翻倍）
        let yellow = frame.count(of: selfYellow)
        XCTAssertGreaterThan(yellow, 50, "自机标记应该画出来")
        XCTAssertLessThan(yellow, 400, "只许有一个自己（两个黄色标记会让像素数翻倍）")
    }

    func testOwnCampUnknownStaysGreyInsteadOfGuessing() throws {
        // 既没有引擎名单、自己也没有阵营 → 宁可不画，也不许猜"阵营 1"（猜错=整片反色）
        let source = PiPRadarSource()
        source.setSettings(settings(headingUp: true, follow: false, selfCamp: nil))
        hello(source, mapID: mapIDIcebox, slot: 8)
        positionsSettled(source, [row(slot: 8, u: 0.5, v: 0.5, track: "T-8", camp: nil),
                           row(slot: 2, u: 0.2, v: 0.5, camp: 3)])
        let frame = try render(source)
        XCTAssertNil(frame.disc(of: teamBlue), "认不出我方阵营时不许把阵营 3 当队友")
        XCTAssertNil(frame.disc(of: enemyRed), "也不许当敌人")
    }

    // MARK: - 5g. 名单未到达时不许采信残留绑定（客户实测：开局几秒把队友认成自己）

    func testStaleTrackBindingIsIgnoredUntilRosterArrives() throws {
        let source = PiPRadarSource()
        var value = settings(headingUp: true, follow: false)
        value.selfTrackID = "T-OLD"          // 上一局留下的轨道绑定
        value.selfTrackGen = "7"
        source.setSettings(value)
        hello(source, mapID: mapIDIcebox)     // 没有 self_slot，也没有 local_slots（名单还没来）
        positionsSettled(source, [row(slot: 0, u: 0.8, v: 0.5, camp: 1),
                           row(slot: 3, u: 0.2, v: 0.5, track: "T-OLD", camp: 1)])

        let frame = try render(source)
        XCTAssertNil(frame.disc(of: selfYellow),
                     "名单未到达前宁可没有\"自己\"，也不能把上一局残留当成自己（否则跟随视角会先跳到队友身上）")
    }

    // MARK: - 5h. 引擎一次抖动不许改绑定（开局准备阶段把队友画成我）

    func testEngineSelfSlotNeedsTwoConsistentReports() throws {
        let source = PiPRadarSource()
        source.setSettings(settings(headingUp: true, follow: false))
        hello(source, mapID: mapIDIcebox, slot: 3, localSlots: [3, 8])
        // 第一条：引擎指到"队友"3
        positions(source, [row(slot: 3, u: 0.2, v: 0.5, camp: 1),
                           row(slot: 8, u: 0.8, v: 0.5, camp: 1)])
        let first = try render(source)
        XCTAssertNil(first.disc(of: selfYellow), "引擎只报了一条时不许立刻绑定（面板同款：两连一致才采纳）")

        // 第二条还是 3 → 才采纳
        positions(source, [row(slot: 3, u: 0.2, v: 0.5, ns: 101, camp: 1),
                           row(slot: 8, u: 0.8, v: 0.5, ns: 101, camp: 1)])
        let second = try render(source)
        XCTAssertNotNil(second.disc(of: selfYellow), "连续两条一致就应当采纳")
    }

    // MARK: - 6. 威胁距离：用世界坐标算真实米数（面板口径 /100）

    func testThreatDistanceUsesWorldMetresNotPixels() throws {
        let source = PiPRadarSource()
        source.setSettings(settings(headingUp: true))
        hello(source, mapID: mapIDIcebox, slot: 0)
        positionsSettled(source, [row(slot: 0, u: 0.5, v: 0.5, camp: 1, world: (x: 0, y: 0, z: 0)),
                           row(slot: 4, u: 0.6, v: 0.5, camp: 2, world: (x: 300, y: 400, z: 0))])
        let me = try XCTUnwrap(source.entities.first { $0.slot == 0 })
        let enemy = try XCTUnwrap(source.entities.first { $0.slot == 4 })
        let metres = try XCTUnwrap(PiPRadarSource.distanceMeters(from: me, to: enemy))
        XCTAssertEqual(metres, 5, accuracy: 0.001,
                       "300/400 厘米 = 5 米（面板口径：世界坐标差 /100，不是按像素估）")
    }
}
