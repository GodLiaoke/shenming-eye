import XCTest
@testable import Phoenix

final class PiPBackgroundTests: XCTestCase {
    @MainActor
    func testPiPPreparesWithoutAWebView() {
        let pump = PiPPump()
        pump.attach(panelURL: URL(string: "http://127.0.0.1:18080/")!, token: "", webView: nil)
        pump.start(webView: nil)
        XCTAssertTrue(pump.isPreparing, "原生 PiP 不得因 WebView 不在前台/不存在而停止出帧")
        XCTAssertNil(pump.hint)
        pump.stop()
    }
}
