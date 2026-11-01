import XCTest
import CoreGraphics
@testable import Phoenix

final class PiPRadarSourceTests: XCTestCase {
    private func position(_ slot: Int, u: Double, yaw: Double = 120, ns: UInt64 = 100) -> String {
        "{\"slot\":\(slot),\"track_id\":\"t\(slot)\",\"map\":{\"u\":\(u),\"v\":0.5},\"world\":{\"x\":0,\"y\":0,\"z\":0},\"yaw\":\(yaw),\"updated_ns\":\(ns),\"camp_id\":1,\"fresh\":true}"
    }

    private func send(_ source: PiPRadarSource, kind: String, rows: [String], session: String = "one") {
        source.handle("{\"schema_version\":1,\"session_id\":\"\(session)\",\"kind\":\"\(kind)\",\"payload\":{\"positions\":[\(rows.joined(separator: ","))]}}")
    }

    func testDeltaMergesAndSnapshotReplaces() {
        let source = PiPRadarSource()
        send(source, kind: "snapshot", rows: [position(0, u: 0.3), position(1, u: 0.4)])
        send(source, kind: "position_delta", rows: [position(0, u: 0.7, ns: 200)])
        XCTAssertEqual(source.entities.count, 2)
        XCTAssertEqual(source.entities.first?.u, 0.7)
        send(source, kind: "snapshot", rows: [position(1, u: 0.8, ns: 300)])
        XCTAssertEqual(source.entities.map(\.slot), [1])
    }

    func testNewSessionClearsOldEntities() {
        let source = PiPRadarSource()
        send(source, kind: "snapshot", rows: [position(0, u: 0.3)])
        send(source, kind: "position_delta", rows: [position(1, u: 0.4)], session: "two")
        XCTAssertEqual(source.entities.map(\.slot), [1])
    }

    func testOutOfOrderPositionDoesNotRewind() {
        let source = PiPRadarSource()
        send(source, kind: "snapshot", rows: [position(0, u: 0.7, ns: 200)])
        send(source, kind: "position_delta", rows: [position(0, u: 0.2, ns: 100)])
        XCTAssertEqual(source.entities.first?.u, 0.7)
    }

    func testRosterRebindClearsCachedHeroUntilFreshIdentityArrives() {
        let source = PiPRadarSource()
        send(source, kind: "snapshot", rows: [
            "{\"slot\":0,\"track_id\":\"t0\",\"map\":{\"u\":0.3,\"v\":0.5},\"world\":{\"x\":0,\"y\":0,\"z\":0},\"yaw\":120,\"updated_ns\":100,\"camp_id\":1,\"agent_id\":3024,\"fresh\":true}"
        ])
        XCTAssertEqual(source.entities.first?.agentID, 3024)
        source.handle("{\"kind\":\"map_roster\",\"payload\":{\"binding\":{\"self_slot\":0,\"local_slots\":[0]}}}")
        send(source, kind: "position_delta", rows: [position(0, u: 0.4, ns: 200)])
        XCTAssertNil(source.entities.first?.agentID, "绑定修订后不能继续显示旧英雄头像")
    }

    func testHeadingFiltersSingleFrameZeroSpikeAndDuplicateSampling() {
        let source = PiPRadarSource()
        for ns in 1...5 {
            send(source, kind: "position_delta", rows: [position(0, u: 0.5, yaw: 120, ns: UInt64(ns))])
        }
        send(source, kind: "position_delta", rows: [position(0, u: 0.5, yaw: 0, ns: 6)])
        for _ in 0..<12 {
            send(source, kind: "position_delta", rows: [position(0, u: 0.5, yaw: 0, ns: 6)])
        }
        XCTAssertEqual(source.entities.first?.yaw, 120)
    }

    func testSessionMetadataUsesWirePayloadAndGenerationClearsPoints() {
        let source = PiPRadarSource()
        source.handle("{\"schema_version\":1,\"session_id\":\"one\",\"kind\":\"session_status\",\"payload\":{\"map_id\":1013,\"channel_generation\":1,\"status\":\"live\"}}")
        XCTAssertEqual(source.mapID, 1013)
        send(source, kind: "snapshot", rows: [position(0, u: 0.5)])
        source.handle("{\"schema_version\":1,\"session_id\":\"one\",\"kind\":\"session_status\",\"payload\":{\"map_id\":1013,\"channel_generation\":2,\"status\":\"live\"}}")
        XCTAssertTrue(source.entities.isEmpty)
    }

    func testPackagedMapLoadsWithoutNetworkOrWebView() {
        let source = PiPRadarSource()
        source.handle("{\"schema_version\":1,\"session_id\":\"one\",\"kind\":\"session_status\",\"payload\":{\"map_id\":1,\"channel_generation\":1,\"status\":\"live\"}}")
        XCTAssertEqual(source.mapImage?.width, 1024)
        XCTAssertEqual(source.rotationDegrees, 90)
        XCTAssertEqual(source.assetRotationDegrees, 180)
    }

    func testMapChangeClearsPreviousMapEntitiesEvenWithoutGeneration() {
        let source = PiPRadarSource()
        source.handle("{\"kind\":\"session_status\",\"payload\":{\"map_id\":1}}")
        send(source, kind: "snapshot", rows: [position(0, u: 0.5)])
        source.handle("{\"kind\":\"session_status\",\"payload\":{\"map_id\":2}}")
        XCTAssertTrue(source.entities.isEmpty)
    }

    func testEndedSessionClearsMapAndBinding() {
        let source = PiPRadarSource()
        source.handle("{\"kind\":\"map_roster\",\"payload\":{\"session\":{\"map_id\":1},\"binding\":{\"self_slot\":0}}}")
        send(source, kind: "snapshot", rows: [position(0, u: 0.5)])
        source.handle("{\"kind\":\"session_status\",\"payload\":{\"status\":\"ended\",\"map_id\":null}}")
        XCTAssertNil(source.mapID)
        XCTAssertNil(source.selfSlot)
        XCTAssertNil(source.mapImage)
        XCTAssertTrue(source.entities.isEmpty)
    }

    func testNanosecondTimestampsDoNotLosePrecision() {
        let source = PiPRadarSource()
        send(source, kind: "snapshot", rows: [position(0, u: 0.3, ns: 1_800_000_000_000_000_000)])
        send(source, kind: "position_delta", rows: [position(0, u: 0.7, ns: 1_800_000_000_000_000_001)])
        XCTAssertEqual(source.entities.first?.u, 0.7)
    }

    func testFollowCentersOwnMarkerForPortraitAndLandscapeFrames() throws {
        let source = PiPRadarSource()
        source.handle("{\"kind\":\"map_roster\",\"payload\":{\"session\":{\"map_id\":1},\"binding\":{\"self_slot\":0}}}")
        // 引擎的 self_slot 要"两连一致"才被采纳（面板同款）：这两条把"自己"稳下来
        send(source, kind: "snapshot", rows: [position(0, u: 0.25)])
        send(source, kind: "position_delta", rows: [position(0, u: 0.25)])
        XCTAssertEqual(source.selfSlot, 0)
        XCTAssertEqual(source.entities.first?.slot, 0)
        for (width, height) in [(480, 480), (640, 360), (360, 640)] {
            let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            source.draw(into: context, size: CGSize(width: width, height: height))
            let pixels = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
            let center = (height / 2 * width + width / 2) * 4
            var best = (score: 0, x: 0, y: 0)
            var yellow = (score: 0, x: 0, y: 0)
            for y in 0..<height { for x in 0..<width {
                let i = (y * width + x) * 4
                let score = Int(pixels[i]) + Int(pixels[i + 1]) - Int(pixels[i + 2])
                if score > best.score { best = (score, x, y) }
                if pixels[i] > 245 && pixels[i + 1] > 200 && pixels[i + 2] < 90 && score > yellow.score { yellow = (score, x, y) }
            }}
            XCTAssertGreaterThan(pixels[center], 180, "自己应在画面中心，不受画布比例影响；最亮点=\(best.x),\(best.y) 黄点=\(yellow.x),\(yellow.y)")
            XCTAssertGreaterThan(pixels[center + 1], 150)
            XCTAssertLessThan(pixels[center + 2], 140)
        }
    }
}
