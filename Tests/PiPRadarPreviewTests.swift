//
//  PiPRadarPreviewTests.swift
//  PhoenixTests
//
//  出图预览：把画中画的几何**离线**渲染成 PNG，装机之前先肉眼看一帧。
//  · 每次跑测试都写一次（3 张 PNG，<100ms，无网络无副作用）；文件落在
//    模拟器容器的 tmp/phoenix-preview/ 下，路径会打印在测试日志里。
//  · 渲染的是**真实底图**（包内 Icebox）+ 真实 PiPRadarSource 绘制路径，
//    不是另写一套画法，所以看到什么 = 手机上出什么（除分辨率/字模差异）。
//
//  取文件：
//    xcodebuild ... test -only-testing:PhoenixTests/PiPRadarPreviewTests
//    find ~/Library/Developer/CoreSimulator/Devices -path "*phoenix-preview*" -name "*.png"
//

import CoreGraphics
import UIKit
import XCTest
@testable import Phoenix

final class PiPRadarPreviewTests: XCTestCase {

    private let canvas = CGSize(width: 512, height: 512)

    private func row(slot: Int, u: Double, v: Double, yaw: Double = 90, camp: Int = 1,
                     track: String? = nil) -> String {
        var parts = ["\"slot\":\(slot)", "\"map\":{\"u\":\(u),\"v\":\(v)}", "\"yaw\":\(yaw)",
                     "\"updated_ns\":100", "\"camp_id\":\(camp)", "\"fresh\":true"]
        if let track = track { parts.append("\"track_id\":\"\(track)\"") }
        return "{" + parts.joined(separator: ",") + "}"
    }

    private func render(lockNorth: Bool, selfYaw: Double) throws -> CGImage {
        let source = PiPRadarSource()
        var settings = PiPRadarSource.Settings()
        settings.follow = true
        settings.lockNorth = lockNorth
        settings.labels = true
        source.setSettings(settings)
        // 真实包内底图（Icebox，image_rotation_degrees = 0）
        source.handle("{\"schema_version\":1,\"session_id\":\"preview\",\"kind\":\"map_roster\","
            + "\"payload\":{\"session\":{\"map_id\":1003,\"channel_generation\":1,\"status\":\"live\"},"
            + "\"binding\":{\"self_slot\":0}}}")
        source.handle("{\"schema_version\":1,\"session_id\":\"preview\",\"kind\":\"snapshot\","
            + "\"payload\":{\"positions\":["
            + row(slot: 0, u: 0.50, v: 0.50, yaw: selfYaw, track: "SELF")
            + "," + row(slot: 1, u: 0.62, v: 0.44, yaw: selfYaw + 20, camp: 1, track: "MATE")
            + "," + row(slot: 2, u: 0.46, v: 0.63, yaw: selfYaw + 95, camp: 2, track: "E1")
            + "," + row(slot: 3, u: 0.57, v: 0.56, yaw: selfYaw - 40, camp: 2, track: "E2")
            + "]}}")

        let width = Int(canvas.width), height = Int(canvas.height)
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        source.draw(into: context, size: canvas)
        return try XCTUnwrap(context.makeImage())
    }

    func testWritePreviewFrames() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("phoenix-preview")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let frames: [(name: String, lockNorth: Bool, yaw: Double)] = [
            ("pip-heading-up（角色朝上·地图转）", false, 35),
            ("pip-north-locked（北向固定·地图不转）", true, 35),
            ("pip-heading-up-yaw200", false, 200),
        ]
        for frame in frames {
            let image = try render(lockNorth: frame.lockNorth, selfYaw: frame.yaw)
            let data = try XCTUnwrap(UIImage(cgImage: image).pngData())
            let url = directory.appendingPathComponent("\(frame.name).png")
            try data.write(to: url)
            print("PREVIEW \(url.path)")
        }
    }
}
