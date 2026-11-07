import XCTest
@testable import TerminalMac

final class VNCConnectionTests: XCTestCase {
    func testTextValidationAcceptsBMPWithoutConnection() {
        XCTAssertNoThrow(try VNCConnection.validateText("Hello café ✓\n漢字\t"))
        XCTAssertNoThrow(try VNCConnection.validateText(String(repeating: "a", count: 32768)))
    }

    func testSupplementaryScalarRejectsWholeTextBeforeTyping() {
        for text in ["Hello 😀", "\u{1D11E}", "prefix𐐀suffix"] {
            XCTAssertThrowsError(try VNCConnection.validateText(text)) { error in
                XCTAssertTrue(error.localizedDescription.contains("No text was entered"))
            }
        }
    }

    func testTextLimitCountsUTF8Bytes() {
        XCTAssertThrowsError(try VNCConnection.validateText(String(repeating: "a", count: 32769)))
        XCTAssertThrowsError(try VNCConnection.validateText(String(repeating: "漢", count: 10923)))
    }
}
