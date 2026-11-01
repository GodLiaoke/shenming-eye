import XCTest
@testable import Phoenix

/// 「验证连接失败」到底是什么意思：错误码 → 人话。
/// 客户截图里那串 ［NSURLErrorDomain -xxxx］就是判据，这张表保证它不会再被含糊过去。
final class GatewayTransportHintTests: XCTestCase {
    func testKnownCodesMapToActionableHints() {
        XCTAssertTrue(GatewayClient.transportHint(code: NSURLErrorTimedOut).contains("超时"))
        XCTAssertTrue(GatewayClient.transportHint(code: NSURLErrorCannotConnectToHost).contains("连不上"))
        XCTAssertTrue(GatewayClient.transportHint(code: NSURLErrorCannotFindHost).contains("解析"))
        XCTAssertTrue(GatewayClient.transportHint(code: NSURLErrorNetworkConnectionLost).contains("中断"))
        XCTAssertTrue(GatewayClient.transportHint(code: NSURLErrorNotConnectedToInternet).contains("没有网络"))
        XCTAssertTrue(GatewayClient.transportHint(code: NSURLErrorServerCertificateUntrusted).contains("证书"))
        XCTAssertTrue(GatewayClient.transportHint(code: NSURLErrorAppTransportSecurityRequiresSecureConnection).contains("ATS"))
    }

    func testUnknownCodeStillSaysSomethingUseful() {
        XCTAssertFalse(GatewayClient.transportHint(code: -99999).isEmpty)
    }

    func testGatewayOriginIsConfigured() {
        // 打包时必须能解析出网关地址，否则激活的连接目标是空的（历史上出现过界面显示 dev）
        XCTAssertFalse(GatewayClient.origin.absoluteString.isEmpty)
        XCTAssertNotNil(GatewayClient.origin.host)
    }
}
