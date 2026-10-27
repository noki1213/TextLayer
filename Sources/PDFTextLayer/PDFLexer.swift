import Foundation

public struct PDFParseError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// Reads PDF objects from raw bytes.
struct PDFLexer {
    let bytes: [UInt8]
    var position: Int

    init(_ bytes: [UInt8], at position: Int = 0) {
        self.bytes = bytes
        self.position = position
    }

    static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x00 || byte == 0x09 || byte == 0x0A || byte == 0x0C || byte == 0x0D || byte == 0x20
    }

    static func isDelimiter(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x28, 0x29, 0x3C, 0x3E, 0x5B, 0x5D, 0x7B, 0x7D, 0x2F, 0x25: return true
        default: return false
        }
    }

    var atEnd: Bool { position >= bytes.count }

    func peek(_ offset: Int = 0) -> UInt8? {
        let index = position + offset
        return index < bytes.count ? bytes[index] : nil
    }

    mutating func skipWhitespace() {
        while let byte = peek() {
            if Self.isWhitespace(byte) {
                position += 1
            } else if byte == 0x25 {
                while let next = peek(), next != 0x0A, next != 0x0D { position += 1 }
            } else {
                break
            }
        }
    }

    /// A run of regular characters (keyword or number)
    mutating func readToken() -> String {
        skipWhitespace()
        let start = position
        while let byte = peek(), !Self.isWhitespace(byte), !Self.isDelimiter(byte) { position += 1 }
        return String(decoding: bytes[start..<position], as: UTF8.self)
    }

    func hasKeyword(_ keyword: String) -> Bool {
        let word = Array(keyword.utf8)
        guard position + word.count <= bytes.count else { return false }
        guard Array(bytes[position..<position + word.count]) == word else { return false }
        if let after = peek(word.count) { return Self.isWhitespace(after) || Self.isDelimiter(after) }
        return true
    }

    mutating func readInteger() -> Int? {
        let saved = position
        let token = readToken()
        if let value = Int(token) { return value }
        position = saved
        return nil
    }

    mutating func parseObject() throws -> PDFObject {
        skipWhitespace()
        guard let byte = peek() else { throw PDFParseError("unexpected end of file") }
        switch byte {
        case 0x2F:
            position += 1
            let start = position
            while let next = peek(), !Self.isWhitespace(next), !Self.isDelimiter(next) { position += 1 }
            return .name(String(bytes: bytes[start..<position], encoding: .isoLatin1) ?? "")
        case 0x28:
            return .string(try readLiteralString())
        case 0x3C:
            if peek(1) == 0x3C {
                return .dictionary(try parseDictionary())
            }
            let start = position
            while let next = peek(), next != 0x3E { position += 1 }
            guard !atEnd else { throw PDFParseError("unterminated hex string") }
            position += 1
            return .string(Array(bytes[start..<position]))
        case 0x5B:
            position += 1
            var items: [PDFObject] = []
            while true {
                skipWhitespace()
                guard let next = peek() else { throw PDFParseError("unterminated array") }
                if next == 0x5D { position += 1; break }
                items.append(try parseObject())
            }
            return .array(items)
        case 0x2B, 0x2D, 0x2E, 0x30...0x39:
            let token = readToken()
            // n g R
            if let number = Int(token), number >= 0 {
                let saved = position
                if let generation = readInteger(), generation >= 0 {
                    skipWhitespace()
                    if peek() == 0x52, peek(1).map({ Self.isWhitespace($0) || Self.isDelimiter($0) }) ?? true {
                        position += 1
                        return .reference(number, generation)
                    }
                }
                position = saved
            }
            return .number(token)
        default:
            let token = readToken()
            switch token {
            case "true": return .bool(true)
            case "false": return .bool(false)
            case "null": return .null
            default: throw PDFParseError("unexpected token '\(token)' at \(position)")
            }
        }
    }

    mutating func parseDictionary() throws -> PDFDictionary {
        position += 2
        var dict = PDFDictionary()
        while true {
            skipWhitespace()
            guard let next = peek() else { throw PDFParseError("unterminated dictionary") }
            if next == 0x3E, peek(1) == 0x3E { position += 2; break }
            guard case .name(let key) = try parseObject() else {
                throw PDFParseError("dictionary key is not a name at \(position)")
            }
            dict[key] = try parseObject()
        }
        return dict
    }

    private mutating func readLiteralString() throws -> [UInt8] {
        let start = position
        position += 1
        var depth = 1
        while depth > 0 {
            guard let byte = peek() else { throw PDFParseError("unterminated string") }
            position += 1
            switch byte {
            case 0x5C: position += 1
            case 0x28: depth += 1
            case 0x29: depth -= 1
            default: break
            }
        }
        return Array(bytes[start..<position])
    }
}
