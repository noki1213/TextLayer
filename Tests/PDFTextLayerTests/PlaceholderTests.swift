import XCTest
@testable import PDFTextLayer

final class LexerTests: XCTestCase {
    func testReferenceAndNumbers() throws {
        var lexer = PDFLexer(Array("<< /A 1 0 R /B [1 2 -3.5] /C (a(b)c) /D <00FF> >>".utf8))
        let dict = try XCTUnwrap(lexer.parseObject().dictionary)
        XCTAssertEqual(dict["A"]?.reference?.0, 1)
        XCTAssertEqual(dict["B"]?.array?.count, 3)
        XCTAssertEqual(dict["C"].map { String(decoding: $0.serialized(), as: UTF8.self) }, "(a(b)c)")
    }
}
