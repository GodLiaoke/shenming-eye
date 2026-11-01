//
//  LicenseInputTests.swift
//  PhoenixTests
//
//  卡密输入规范化的验收：客户报"24 位粘进去只显示 22 位"。
//
//  根因：旧实现的 `filter { isASCII && (isLetter || isNumber) }` 会把**全角字符**
//  （微信/短信/第三方输入法复制出来极常见：Ａ=U+FF21、１=U+FF10）当"非字母数字"
//  整块吃掉，而且是静默的 —— 界面上只看得到位数变少，没有任何提示。
//
//  验收标准：
//   · 全角/兼容字形 → 折叠成半角（确定映射，可以放心做），**不许丢**；
//   · 真的不是卡密内容的字符（短横线、零宽、空格…）→ 丢掉，但**必须上报码位**；
//   · 超 24 位 → 截断并标记。
//

import XCTest
@testable import Phoenix

final class LicenseInputTests: XCTestCase {

    /// 24 位纯 ASCII（跳过易混的 I/O，和真卡一样只用字母数字）
    private let card = "ABCDEFGHJKLMNPQRSTUVWXYZ"
    private let prefix22 = "ABCDEFGHJKLMNPQRSTUVWX"

    func testPlainAsciiCardIsUntouched() {
        let parse = LicenseView.parse(card)
        XCTAssertEqual(parse.value, card)
        XCTAssertEqual(parse.value.count, 24)
        XCTAssertTrue(parse.droppedCodePoints.isEmpty)
        XCTAssertFalse(parse.truncated)
    }

    func testLowercaseIsUppercased() {
        XCTAssertEqual(LicenseView.normalize(card.lowercased()), card)
    }

    func testFullWidthLettersAreFoldedNotDropped() {
        let pasted = prefix22 + "ＹＺ"          // 22 个 ASCII + 2 个全角字母 = 24 位
        XCTAssertEqual(pasted.count, 24)

        // 旧实现（这就是客户看到的 24 → 22）
        let legacy = String(pasted.uppercased()
            .filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
            .prefix(24))
        XCTAssertEqual(legacy.count, 22, "旧实现会把全角字母静默吃掉两位")

        let parse = LicenseView.parse(pasted)
        XCTAssertEqual(parse.value, card, "全角字母必须折叠成半角，不许丢")
        XCTAssertEqual(parse.value.count, 24)
        XCTAssertTrue(parse.droppedCodePoints.isEmpty)
    }

    func testFullWidthDigitsAreFoldedNotDropped() {
        let pasted = prefix22 + "１２"
        let parse = LicenseView.parse(pasted)
        XCTAssertEqual(parse.value, prefix22 + "12")
        XCTAssertEqual(parse.value.count, 24)
        XCTAssertTrue(parse.droppedCodePoints.isEmpty)
    }

    func testStraySymbolsAreReportedInsteadOfSilentlyDropped() {
        let pasted = prefix22 + "--"            // 24 位里混进两个短横线
        let parse = LicenseView.parse(pasted)
        XCTAssertEqual(parse.value.count, 22, "短横线不是卡密内容 → 有效 22 位")
        XCTAssertEqual(parse.droppedCodePoints, [0x2D, 0x2D],
                       "必须把被丢弃的码位报出来（旧实现是静默丢）")
        XCTAssertEqual(parse.originalLength, 24)
    }

    func testZeroWidthCharactersAreReported() {
        let pasted = prefix22 + "\u{200B}\u{FEFF}"
        let parse = LicenseView.parse(pasted)
        XCTAssertEqual(parse.droppedCodePoints, [0x200B, 0xFEFF])
        XCTAssertEqual(parse.value.count, 22)
    }

    func testOverLongInputIsTruncatedAndFlagged() {
        let parse = LicenseView.parse(card + "ZZZZ")     // 28 位有效
        XCTAssertEqual(parse.value.count, 24)
        XCTAssertTrue(parse.truncated, "超过 24 位要标记出来，不能悄悄截断")
    }

    func testSpacesAndNewlinesAreReported() {
        let parse = LicenseView.parse(prefix22 + " \n")
        XCTAssertEqual(parse.value.count, 22)
        XCTAssertEqual(parse.droppedCodePoints, [0x20, 0x0A])
    }
}
