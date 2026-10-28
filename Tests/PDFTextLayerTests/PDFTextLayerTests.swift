import PDFKit
import XCTest
@testable import PDFTextLayer
import TextRecognition

final class LexerTests: XCTestCase {
    func testReferenceAndNumbers() throws {
        var lexer = PDFLexer(Array("<< /A 1 0 R /B [1 2 -3.5] /C (a(b)c) /D <00FF> >>".utf8))
        let dict = try XCTUnwrap(lexer.parseObject().dictionary)
        XCTAssertEqual(dict["A"]?.reference?.0, 1)
        XCTAssertEqual(dict["B"]?.array?.count, 3)
        XCTAssertEqual(dict["C"].map { String(decoding: $0.serialized(), as: UTF8.self) }, "(a(b)c)")
    }
}

final class ReadingOrderTests: XCTestCase {
    func testTwoColumnsAreReadOneAfterTheOther() {
        // Origin bottom-left; left column at x 0-45, right column at x 55-100, a title across both
        let boxes = [
            CGRect(x: 0, y: 90, width: 100, height: 5),   // title
            CGRect(x: 0, y: 80, width: 45, height: 5),    // left 1
            CGRect(x: 55, y: 81, width: 45, height: 5),   // right 1
            CGRect(x: 0, y: 70, width: 45, height: 5),    // left 2
            CGRect(x: 55, y: 71, width: 45, height: 5),   // right 2
        ]
        XCTAssertEqual(ReadingOrder.order(boxes, pageWidth: 100), [0, 1, 3, 2, 4])
    }

    func testStraddlingLinesDoNotJoinTheColumns() {
        let boxes = [
            CGRect(x: 10, y: 90, width: 60, height: 5),   // author line reaching into the right column
            CGRect(x: 0, y: 80, width: 45, height: 5),    // left 1
            CGRect(x: 55, y: 81, width: 45, height: 5),   // right 1
            CGRect(x: 0, y: 70, width: 45, height: 5),    // left 2
            CGRect(x: 55, y: 71, width: 45, height: 5),   // right 2
            CGRect(x: 44, y: 50, width: 12, height: 5),   // page number in the gutter
        ]
        XCTAssertEqual(ReadingOrder.order(boxes, pageWidth: 100), [0, 1, 3, 2, 4, 5])
    }

    func testOverlappingLinesAreSeparated() {
        let boxes = [
            CGRect(x: 0, y: 20, width: 100, height: 12),  // reaches down into the next line
            CGRect(x: 0, y: 10, width: 100, height: 8),
            CGRect(x: 0, y: 40, width: 100, height: 8),   // clear of the others
        ]
        let separated = LineBoxes.separated(boxes)
        XCTAssertLessThanOrEqual(separated[1].maxY, separated[0].minY)
        XCTAssertEqual(separated[2], boxes[2])
    }
}

final class ContentStreamTests: XCTestCase {
    func testActualTextSpansAreTakenOut() throws {
        let content = Array("q /Im1 Do Q /Span << /ActualText <feff30fc> >> BDC BT (a) Tj ET EMC /OC /oc1 BDC 1 0 0 RG EMC".utf8)
        let stripped = String(decoding: try XCTUnwrap(ContentStream.removingActualText(content)), as: UTF8.self)
        XCTAssertFalse(stripped.contains("ActualText"))
        XCTAssertTrue(stripped.contains("BT (a) Tj ET"))
        // Optional content stays, with its own EMC
        XCTAssertTrue(stripped.contains("/OC /oc1 BDC 1 0 0 RG EMC"))
    }

    func testContentWithoutActualTextIsLeftAlone() {
        XCTAssertNil(ContentStream.removingActualText(Array("q BT (a) Tj ET Q".utf8)))
    }
}

final class InvisibleTextTests: XCTestCase {
    /// Draws the lines on one page and returns what PDFKit reads from it
    private func pageString(_ lines: [RecognizedLine]) throws -> String {
        let data = NSMutableData()
        var media = CGRect(x: 0, y: 0, width: 400, height: 400)
        let consumer = try XCTUnwrap(CGDataConsumer(data: data))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &media, nil))
        context.beginPDFPage(nil)
        InvisibleText.draw(lines, in: media, context: context)
        context.endPDFPage()
        context.closePDF()
        return try XCTUnwrap(PDFDocument(data: data as Data)?.page(at: 0)?.string)
    }

    func testDoubledLettersSurviveInANarrowBox() throws {
        let line = RecognizedLine(text: "all fell well", box: CGRect(x: 0.1, y: 0.5, width: 0.15, height: 0.05))
        XCTAssertEqual(try pageString([line]).filter { !$0.isWhitespace }, "allfellwell")
    }

    func testALongVerticalLineStaysOnThePage() throws {
        // A column reading down from near the top to near the bottom of the page
        let text = "ハイウェイで、トラックの運転手に頭を撃たれ、バイクから落ちて死ぬ。"
        let line = RecognizedLine(
            text: text,
            topLeft: CGPoint(x: 0.55, y: 0.95), topRight: CGPoint(x: 0.55, y: 0.05),
            bottomLeft: CGPoint(x: 0.5, y: 0.95), bottomRight: CGPoint(x: 0.5, y: 0.05)
        )
        XCTAssertEqual(try pageString([line]).filter { !$0.isWhitespace }, text)
    }
}

final class InvisibleTextRemovalTests: XCTestCase {
    func testTextObjectsGoAndDrawingStays() throws {
        let content = Array("q 100 0 0 50 0 0 cm /Im1 Do Q 3 Tr BT /F1 9 Tf 1 0 0 1 5 5 Tm (abc) Tj ET BT (d) Tj ET".utf8)
        XCTAssertTrue(ContentStream.showsOnlyInvisibleText(content))
        let bare = String(decoding: try XCTUnwrap(ContentStream.removingTextObjects(content)), as: UTF8.self)
        XCTAssertTrue(bare.contains("/Im1 Do"))
        XCTAssertFalse(bare.contains("Tj"))
    }
}
