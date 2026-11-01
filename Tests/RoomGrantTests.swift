import XCTest
import WebKit
@testable import Phoenix

final class RoomGrantTests: XCTestCase {
    @MainActor
    func testLocalRadarWebViewReceivesLiveFramesWithoutSocketInjection() async throws {
        LocalRelay.stop()
        defer { LocalRelay.stop() }
        let startResult = await LocalRelay.start(advertisedHost: "127.0.0.1")
        XCTAssertEqual(startResult, 0)
        let panel = try XCTUnwrap(LocalRelay.panelURL)
        let token = try XCTUnwrap(LocalRelay.panelToken)
        var endpoint = URLComponents(url: panel.appendingPathComponent("api/v1/mirror/positions"), resolvingAgainstBaseURL: false)!
        endpoint.queryItems = [URLQueryItem(name: "token", value: token)]
        var request = URLRequest(url: try XCTUnwrap(endpoint.url))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let now = UInt64(Date().timeIntervalSince1970 * 1_000_000_000)
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "capture_ns": now, "map_id": 1004,
            "binding": ["self_slot": 9, "local_slots": [9]],
            "positions": [["slot": 9, "track_id": "webview-live-9", "camp_id": 2,
                "world": ["x": 2960.0, "y": -13430.0, "z": 400.3], "yaw": 90,
                "fresh": true, "continuity": "proven", "identity_confidence": "proven",
                "updated_ns": now]]
        ])
        let (_, uploadResponse) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((uploadResponse as? HTTPURLResponse)?.statusCode, 200)

        let page = try XCTUnwrap(LocalRelay.panelPageURL)
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: WKWebViewConfiguration())
        webView.load(URLRequest(url: page))
        var state: [String: Any] = [:]
        for _ in 0..<80 {
            try await Task.sleep(for: .milliseconds(100))
            if let value = try? await webView.evaluateJavaScript("""
              ({session:document.getElementById('sessionMeta')?.textContent || '',
                players:document.getElementById('playerCount')?.textContent || '0',
                empty:document.getElementById('mapEmpty')?.hidden || false})
            """) as? [String: Any] {
                state = value
                if (value["players"] as? String) == "1" { break }
            }
        }
        XCTAssertTrue((state["session"] as? String)?.contains("实时接收") == true, "WKWebView must consume session_status: \(state)")
        XCTAssertEqual(state["players"] as? String, "1", "WKWebView must render the received position: \(state)")
        XCTAssertEqual(state["empty"] as? Bool, true, "live session must hide the waiting panel")
        webView.stopLoading()
    }

    func testProxyRoomResponseDecodesIntoCodeVNodeAndRoom() throws {
        let json = #"""
        {
          "room_id":"VALDEVICE01",
          "room_url":"https://140.210.14.246/r/VALDEVICE01",
          "radar_url":"https://140.210.14.246/radar",
          "node_host":"140.210.14.246",
          "node_port":21001,
          "node_username":"val-device01",
          "node_password":"secret-value",
          "expires_at":"2026-09-01 12:00:00",
          "expires_unix":1788235200,
          "notice":"",
          "source_mode":"proxy"
        }
        """#
        let grant = try JSONDecoder().decode(RoomGrant.self, from: Data(json.utf8))
        XCTAssertEqual(grant.sourceMode, "proxy")
        XCTAssertEqual(grant.nodePort, 21001)
        XCTAssertEqual(grant.expiresUnix, 1788235200)
        XCTAssertTrue(grant.socksLink.hasPrefix("socks5://"))
        XCTAssertTrue(grant.socksLink.contains("140.210.14.246:21001"))
    }
    func testGrantOnlyNeedsAValidExpiry() throws {
        let grant = RoomGrant(roomID: "ROOM1",
            roomURL: "\(GatewayClient.origin.absoluteString)/r/ROOM1?access=test-private",
            radarURL: "\(GatewayClient.origin.absoluteString)/r/ROOM1?access=test-private",
            nodeHost: GatewayClient.origin.host!, nodePort: 21001,
            nodeUsername: "test-slot", nodePassword: "test-only",
            expiresAt: "2099-01-01 00:00:00", expiresUnix: 4070908800,
            notice: "", sourceMode: "proxy")
        // 新版只校验有效期：房间号 / 节点账号 / 房间链接都不再是放行条件。
        XCTAssertNoThrow(try GatewayClient().validate(grant))

        let expired = RoomGrant(roomID: grant.roomID, roomURL: grant.roomURL,
            radarURL: grant.radarURL, nodeHost: grant.nodeHost, nodePort: grant.nodePort,
            nodeUsername: grant.nodeUsername, nodePassword: grant.nodePassword,
            expiresAt: "2000-01-01 00:00:00", expiresUnix: 946684800,
            notice: "", sourceMode: "proxy")
        XCTAssertThrowsError(try GatewayClient().validate(expired), "过期卡密必须被拦下")

        let noExpiry = RoomGrant(roomID: grant.roomID, roomURL: grant.roomURL,
            radarURL: grant.radarURL, nodeHost: grant.nodeHost, nodePort: grant.nodePort,
            nodeUsername: grant.nodeUsername, nodePassword: grant.nodePassword,
            expiresAt: "", expiresUnix: 0,
            notice: "", sourceMode: "proxy")
        XCTAssertThrowsError(try GatewayClient().validate(noExpiry), "没有有效期必须报错")
    }
    @MainActor
    func testCancelledActivationNeverStartsNetworkRetry() async {
        let task = Task { try await GatewayClient().activate(card: "TESTCARD12345678", deviceID: "TEST-DEVICE-0000000001") }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled activation must not succeed") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testGatewayDateIsParsedAsAuthoritativeUnixTime() {
        XCTAssertEqual(
            GatewayClient.serverUnix(fromHTTPDate: "Wed, 21 Oct 2015 07:28:00 GMT"),
            1_445_412_480
        )
        XCTAssertNil(GatewayClient.serverUnix(fromHTTPDate: nil))
        XCTAssertNil(GatewayClient.serverUnix(fromHTTPDate: "not-a-date"))
    }

    @MainActor
    func testAuthorizationDeadlineUsesServerClockAndNeverPhoneRollback() {
        XCTAssertEqual(
            AppModel.authorizationRecheckDelay(expiresUnix: 2_000, serverUnix: 1_000),
            1_000
        )
        XCTAssertNil(AppModel.authorizationRecheckDelay(expiresUnix: 999, serverUnix: 1_000))
        XCTAssertEqual(
            AppModel.authorizationRecheckDelay(expiresUnix: Int64.max, serverUnix: nil),
            300
        )
    }

    func testOnlyAuthorizationFailuresTriggerRoomReactivation() {
        for status in [400, 401, 402, 403, 404, 410] {
            XCTAssertTrue(RadarWebView.Coordinator.isDeadRoomStatus(status))
        }
        for status in [408, 429, 500, 502, 503] {
            XCTAssertFalse(RadarWebView.Coordinator.isDeadRoomStatus(status))
        }
    }
}
