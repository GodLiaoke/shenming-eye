import XCTest
@testable import Phoenix

final class RadarCapabilitySnapshotTests: XCTestCase {
    func testStreamingKeepsLocalRadarPrimaryAndLive() {
        let snapshot = RadarCapabilitySnapshot(
            flow: .streaming(count: 1284),
            panelStreamStatus: "已收到 42 帧",
            pipSupported: true,
            pipActive: false,
            usageMode: .singleDevice
        )

        XCTAssertEqual(snapshot.local, .streaming(frames: 1284))
        XCTAssertTrue(snapshot.isLocalLive)
        XCTAssertEqual(snapshot.localTitle, "正在接收坐标")
        XCTAssertTrue(snapshot.primaryCopy.contains("算法服务"))
        XCTAssertEqual(snapshot.browserTitle, "已共享")
        XCTAssertEqual(snapshot.pipTitle, "可用")
    }

    func testBrowserFailureDoesNotTurnLocalWaitingIntoFailure() {
        let snapshot = RadarCapabilitySnapshot(
            flow: .waiting,
            panelStreamStatus: "异常：本机连接断开",
            pipSupported: false,
            pipActive: false,
            usageMode: .singleDevice
        )

        XCTAssertEqual(snapshot.local, .waiting)
        XCTAssertFalse(snapshot.isLocalLive)
        XCTAssertEqual(snapshot.browser, .failed)
        XCTAssertEqual(snapshot.localTitle, "等待游戏数据")
        XCTAssertEqual(snapshot.browserTitle, "连接失败")
        XCTAssertEqual(snapshot.pip, .unavailable)
        XCTAssertEqual(snapshot.pipTitle, "不可用")
    }

    func testLocalEngineFaultIsRepresentedWithoutInventingFrames() {
        let snapshot = RadarCapabilitySnapshot(
            flow: .fault("引擎未运行"),
            panelStreamStatus: "未开启",
            pipSupported: true,
            pipActive: true,
            usageMode: .singleDevice
        )

        XCTAssertEqual(snapshot.local, .failed(message: "引擎未运行"))
        XCTAssertFalse(snapshot.isLocalLive)
        XCTAssertEqual(snapshot.localTitle, "引擎未运行")
        XCTAssertEqual(snapshot.browser, .off)
        XCTAssertEqual(snapshot.pip, .active)
        XCTAssertEqual(snapshot.pipTitle, "运行中")
    }

    func testCapabilityChipsKeepLocalDecodeFirst() {
        let snapshot = RadarCapabilitySnapshot(
            flow: .waiting,
            panelStreamStatus: "未开启",
            pipSupported: true,
            pipActive: false,
            usageMode: .singleDevice
        )

        XCTAssertEqual(snapshot.capabilityChips.map(\.title), ["算法服务", "浏览器共享", "画中画"])
        XCTAssertEqual(snapshot.capabilityChips.first?.emphasis, .primary)
        XCTAssertEqual(snapshot.capabilityChips.dropFirst().map(\.emphasis), [.secondary, .secondary])
    }

    func testDualDeviceModeDisablesPiPAndDescribesBDevice() {
        let mode = RadarUsageMode.dualDevice
        XCTAssertFalse(mode.supportsPiP)
        XCTAssertTrue(mode.requiresSecondDevice)
        XCTAssertTrue(mode.guideTitle.contains("双机"))

        let snapshot = RadarCapabilitySnapshot(
            flow: .waiting,
            panelStreamStatus: "未开启",
            pipSupported: true,
            pipActive: true,
            usageMode: mode
        )

        XCTAssertEqual(snapshot.pip, .unavailable)
        XCTAssertEqual(snapshot.pipTitle, "本模式不使用")
    }

    func testVisibleCopyHasNoClientDecodeTerms() {
        let snapshot = RadarCapabilitySnapshot(
            flow: .waiting,
            panelStreamStatus: "未开启",
            pipSupported: true,
            pipActive: false,
            usageMode: .singleDevice
        )
        let visible = [snapshot.primaryCopy, snapshot.localTitle, snapshot.browserTitle, snapshot.pipTitle]
        let forbidden = ["本机解码", "本地解密", "客户端解密", "本机解析"]
        XCTAssertTrue(visible.allSatisfy { text in forbidden.allSatisfy { !text.contains($0) } })
    }
}

extension RadarCapabilitySnapshotTests {
    func testBackgroundRuntimeReportsFiniteFallbackAndPreservesCredentials() {
        XCTAssertEqual(BackgroundRuntime.Status.foreground.displayText, "前台运行")
        XCTAssertEqual(BackgroundRuntime.Status.backgroundTask.displayText, "后台恢复已安排 · 可能需要重新同步节点")
        XCTAssertFalse(BackgroundRuntime.Status.backgroundTask.preservesRelayCredentials)
        XCTAssertFalse(RadarUsageMode.dualDevice.supportsPiP)
    }
}
