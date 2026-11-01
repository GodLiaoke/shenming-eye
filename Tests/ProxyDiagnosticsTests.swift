import XCTest
@testable import Phoenix

final class ProxyDiagnosticsTests: XCTestCase {
    func testLayeredDiagnosticsPreserveListenerAndIndividualNetworkFailures() throws {
        let json = """
        {"ok":false,"diagnostics":{"listener":{"ok":true,"detail":"代理端口已监听"},"socks_handshake":{"ok":true,"detail":"SOCKS5握手正常"},"dns":{"ok":false,"detail":"域名解析失败"},"tcp":{"ok":false,"detail":"TCP外网失败"},"udp":{"ok":false,"detail":"UDP中继失败"},"interface":"ifindex=4 192.168.1.2"}}
        """
        let snapshot = try ProxyDiagnosticsSnapshot(json: Data(json.utf8))
        XCTAssertTrue(snapshot.listener.ok)
        XCTAssertTrue(snapshot.socksHandshake.ok)
        XCTAssertFalse(snapshot.dns.ok)
        XCTAssertFalse(snapshot.tcp.ok)
        XCTAssertFalse(snapshot.udp.ok)
        XCTAssertEqual(snapshot.interfaceSummary, "ifindex=4 192.168.1.2")
        XCTAssertFalse(snapshot.isHealthy)
    }
}
