import Foundation

enum ContentStream {
    /// The content with every marked-content span that carries an /ActualText taken out (the BDC
    /// with its operands and the matching EMC), everything else byte for byte as it was. Marked
    /// content does not change what is drawn. Returns nil when the content has no /ActualText or
    /// holds something this does not read (an inline image), so the caller keeps it as it is.
    ///
    /// A page's own replacement text nested inside the empty /ActualText that hides the page would
    /// otherwise come back out: readers take the innermost /ActualText.
    static func removingActualText(_ content: [UInt8]) -> [UInt8]? {
        guard contains(content, Array("ActualText".utf8)) else { return nil }
        var lexer = PDFLexer(content)
        var operands: [(start: Int, object: PDFObject)] = []
        var spans: [Bool] = []
        var removed: [Range<Int>] = []

        while true {
            lexer.skipWhitespace()
            guard let byte = lexer.peek() else { break }
            let start = lexer.position
            let isOperandStart = byte == 0x2F || byte == 0x28 || byte == 0x3C || byte == 0x5B
                || byte == 0x2B || byte == 0x2D || byte == 0x2E || (0x30...0x39).contains(byte)
            if isOperandStart {
                guard let object = try? lexer.parseObject() else { return nil }
                operands.append((start, object))
                continue
            }
            let token = lexer.readToken()
            guard !token.isEmpty else { return nil }
            switch token {
            case "true", "false", "null":
                operands.append((start, .null))
                continue
            case "BI":
                return nil
            case "BDC":
                let carries = operands.count >= 2 && operands[operands.count - 1].object.dictionary?["ActualText"] != nil
                if carries { removed.append(operands[operands.count - 2].start..<lexer.position) }
                spans.append(carries)
            case "BMC":
                spans.append(false)
            case "EMC":
                guard let carries = spans.popLast() else { return nil }
                if carries { removed.append(start..<lexer.position) }
            default:
                break
            }
            operands.removeAll()
        }
        guard spans.isEmpty, !removed.isEmpty else { return nil }

        var output: [UInt8] = []
        var cursor = 0
        for range in removed.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            output += content[cursor..<range.lowerBound]
            output.append(0x20)
            cursor = range.upperBound
        }
        output += content[cursor...]
        return output
    }

    private static func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard haystack.count >= needle.count else { return false }
        var index = 0
        while index <= haystack.count - needle.count {
            if haystack[index] == needle[0], Array(haystack[index..<index + needle.count]) == needle { return true }
            index += 1
        }
        return false
    }
}

extension ContentStream {
    /// Whether every piece of text the content shows is invisible (render mode 3) — the mark of a
    /// text layer some other OCR laid over a picture. False when nothing is shown, when anything
    /// is shown visibly (a fill-in-the-blanks slide hides only its answers), or when the content
    /// holds something this does not read.
    static func showsOnlyInvisibleText(_ content: [UInt8]) -> Bool {
        var lexer = PDFLexer(content)
        var operands: [PDFObject] = []
        var mode = 0
        var saved: [Int] = []
        var shown = false
        while true {
            lexer.skipWhitespace()
            guard let byte = lexer.peek() else { break }
            let isOperandStart = byte == 0x2F || byte == 0x28 || byte == 0x3C || byte == 0x5B
                || byte == 0x2B || byte == 0x2D || byte == 0x2E || (0x30...0x39).contains(byte)
            if isOperandStart {
                guard let object = try? lexer.parseObject() else { return false }
                operands.append(object)
                continue
            }
            let token = lexer.readToken()
            switch token {
            case "": return false
            case "true", "false", "null":
                operands.append(.null)
                continue
            case "BI": return false
            case "q": saved.append(mode)
            case "Q": mode = saved.popLast() ?? 0
            case "Tr": mode = operands.last?.integer ?? mode
            case "Tj", "TJ", "'", "\"":
                if mode != 3 { return false }
                shown = true
            default: break
            }
            operands.removeAll()
        }
        return shown
    }
}

extension ContentStream {
    /// The content with every text object (BT ... ET) taken out, everything else byte for byte as
    /// it was. Only for content whose text is all invisible, where this changes nothing that is
    /// drawn. Returns nil when the content holds something this does not read (an inline image).
    static func removingTextObjects(_ content: [UInt8]) -> [UInt8]? {
        var lexer = PDFLexer(content)
        var removed: [Range<Int>] = []
        var objectStart: Int?
        while true {
            lexer.skipWhitespace()
            guard let byte = lexer.peek() else { break }
            let isOperandStart = byte == 0x2F || byte == 0x28 || byte == 0x3C || byte == 0x5B
                || byte == 0x2B || byte == 0x2D || byte == 0x2E || (0x30...0x39).contains(byte)
            if isOperandStart {
                guard (try? lexer.parseObject()) != nil else { return nil }
                continue
            }
            let start = lexer.position
            let token = lexer.readToken()
            switch token {
            case "": return nil
            case "BI": return nil
            case "BT": objectStart = start
            case "ET":
                guard let from = objectStart else { return nil }
                removed.append(from..<lexer.position)
                objectStart = nil
            default: break
            }
        }
        guard objectStart == nil, !removed.isEmpty else { return nil }
        var output: [UInt8] = []
        var cursor = 0
        for range in removed {
            output += content[cursor..<range.lowerBound]
            output.append(0x20)
            cursor = range.upperBound
        }
        output += content[cursor...]
        return output
    }
}
