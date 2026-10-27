import Foundation

/// Read access to a PDF file's objects through its cross-reference data, enough to find the pages
/// and append an incremental update.
public final class PDFFile {
    enum XrefEntry {
        case offset(Int, generation: Int)
        case compressed(stream: Int, index: Int)
        case free
    }

    public let bytes: [UInt8]
    private(set) var xref: [Int: XrefEntry] = [:]
    /// The newest trailer (for an xref stream, its dictionary)
    public private(set) var trailer = PDFDictionary()
    /// Where the newest cross-reference section starts, for the next update's /Prev
    public private(set) var startxref = 0
    /// The newest section is a stream, so an update has to write one as well
    public private(set) var usesXrefStream = false

    private var cache: [Int: PDFObject] = [:]
    private var objectStreams: [Int: [Int: PDFObject]] = [:]
    private var loading: Set<Int> = []

    public init(bytes: [UInt8]) throws {
        self.bytes = bytes
        do {
            try readXref()
        } catch {
            try rebuildXref()
        }
        guard trailer["Root"] != nil else { throw PDFParseError("no document catalog") }
    }

    public var size: Int { trailer["Size"]?.integer ?? ((xref.keys.max() ?? 0) + 1) }

    public var isEncrypted: Bool { trailer["Encrypt"] != nil }

    // MARK: Objects

    public func object(_ number: Int) -> PDFObject? {
        if let cached = cache[number] { return cached }
        guard !loading.contains(number) else { return nil }
        loading.insert(number)
        defer { loading.remove(number) }
        let object: PDFObject?
        switch xref[number] {
        case .offset(let offset, _): object = try? parseIndirectObject(at: offset, expecting: number)
        case .compressed(let stream, let index): object = try? objectFromStream(stream, index: index, number: number)
        default: object = nil
        }
        if let object { cache[number] = object }
        return object
    }

    public func generation(of number: Int) -> Int {
        if case .offset(_, let generation) = xref[number] { return generation }
        return 0
    }

    /// Follows references until a direct object
    public func resolve(_ object: PDFObject?) -> PDFObject? {
        var current = object
        var hops = 0
        while case .reference(let number, _) = current, hops < 32 {
            current = self.object(number)
            hops += 1
        }
        return current
    }

    public func decodedStream(_ object: PDFObject) throws -> [UInt8] {
        guard case .stream(let dict, let raw) = object else { throw PDFParseError("not a stream") }
        var filters: [String] = []
        switch resolve(dict["Filter"]) {
        case .name(let name): filters = [name]
        case .array(let items): filters = items.compactMap { resolve($0)?.name }
        default: break
        }
        var data = raw
        for filter in filters {
            guard filter == "FlateDecode" || filter == "Fl" else { throw PDFParseError("unsupported filter \(filter)") }
            data = try Flate.decode(data)
        }
        var params = resolve(dict["DecodeParms"])
        if case .array(let items) = params { params = resolve(items.first) }
        if let params = params?.dictionary, let predictor = resolve(params["Predictor"])?.integer, predictor >= 10 {
            data = try Flate.unpredict(
                data,
                columns: resolve(params["Columns"])?.integer ?? 1,
                colors: resolve(params["Colors"])?.integer ?? 1,
                bitsPerComponent: resolve(params["BitsPerComponent"])?.integer ?? 8
            )
        }
        return data
    }

    private func parseIndirectObject(at offset: Int, expecting number: Int?) throws -> PDFObject {
        var lexer = PDFLexer(bytes, at: offset)
        guard let found = lexer.readInteger(), lexer.readInteger() != nil else {
            throw PDFParseError("no object header at \(offset)")
        }
        if let number, found != number { throw PDFParseError("object \(number) not found at \(offset)") }
        guard lexer.readToken() == "obj" else { throw PDFParseError("no obj keyword at \(offset)") }
        let object = try lexer.parseObject()
        lexer.skipWhitespace()
        guard case .dictionary(let dict) = object, lexer.hasKeyword("stream") else { return object }

        lexer.position += 6
        if lexer.peek() == 0x0D { lexer.position += 1 }
        if lexer.peek() == 0x0A { lexer.position += 1 }
        let start = lexer.position
        var length = -1
        if case .number = dict["Length"] { length = dict["Length"]?.integer ?? -1 }
        if case .reference(let ref, _) = dict["Length"], let resolved = self.object(ref)?.integer { length = resolved }
        if length >= 0, start + length <= bytes.count, endstreamFollows(start + length) {
            return .stream(dict, Array(bytes[start..<start + length]))
        }
        // Wrong or missing /Length: take everything up to endstream
        guard let end = find(Array("endstream".utf8), from: start) else { throw PDFParseError("no endstream") }
        var stop = end
        if stop > start, bytes[stop - 1] == 0x0A { stop -= 1 }
        if stop > start, bytes[stop - 1] == 0x0D { stop -= 1 }
        return .stream(dict, Array(bytes[start..<stop]))
    }

    private func endstreamFollows(_ index: Int) -> Bool {
        var lexer = PDFLexer(bytes, at: index)
        lexer.skipWhitespace()
        return lexer.hasKeyword("endstream")
    }

    private func objectFromStream(_ streamNumber: Int, index: Int, number: Int) throws -> PDFObject? {
        if objectStreams[streamNumber] == nil {
            guard let stream = object(streamNumber), let dict = stream.dictionary,
                  let count = resolve(dict["N"])?.integer, let first = resolve(dict["First"])?.integer else {
                throw PDFParseError("bad object stream \(streamNumber)")
            }
            let data = try decodedStream(stream)
            var header = PDFLexer(data)
            var offsets: [(Int, Int)] = []
            for _ in 0..<count {
                guard let objectNumber = header.readInteger(), let offset = header.readInteger() else { break }
                offsets.append((objectNumber, offset))
            }
            var objects: [Int: PDFObject] = [:]
            for (objectNumber, offset) in offsets {
                var lexer = PDFLexer(data, at: first + offset)
                if let parsed = try? lexer.parseObject() { objects[objectNumber] = parsed }
            }
            objectStreams[streamNumber] = objects
        }
        return objectStreams[streamNumber]?[number]
    }

    // MARK: Cross-reference

    private func readXref() throws {
        guard let marker = findLast(Array("startxref".utf8)) else { throw PDFParseError("no startxref") }
        var lexer = PDFLexer(bytes, at: marker + 9)
        guard let offset = lexer.readInteger() else { throw PDFParseError("bad startxref") }
        startxref = offset

        var next: Int? = offset
        var visited: Set<Int> = []
        var newest = true
        while let sectionOffset = next, !visited.contains(sectionOffset) {
            visited.insert(sectionOffset)
            guard sectionOffset >= 0, sectionOffset < bytes.count else { throw PDFParseError("xref offset out of range") }
            var probe = PDFLexer(bytes, at: sectionOffset)
            probe.skipWhitespace()
            let dict: PDFDictionary
            if probe.hasKeyword("xref") {
                dict = try readXrefTable(at: probe.position + 4)
                if newest { usesXrefStream = false }
                // Hybrid files list some objects in an extra stream
                if let streamOffset = dict["XRefStm"]?.integer { _ = try? readXrefStream(at: streamOffset) }
            } else {
                dict = try readXrefStream(at: sectionOffset)
                if newest { usesXrefStream = true }
            }
            if newest { trailer = dict }
            newest = false
            next = dict["Prev"]?.integer
        }
        // Offsets that do not lead to the catalog mean the table is broken
        guard object(trailer["Root"]?.reference?.0 ?? -1)?.dictionary != nil else {
            throw PDFParseError("catalog unreadable through xref")
        }
    }

    private func readXrefTable(at start: Int) throws -> PDFDictionary {
        var lexer = PDFLexer(bytes, at: start)
        while true {
            lexer.skipWhitespace()
            if lexer.hasKeyword("trailer") {
                lexer.position += 7
                guard case .dictionary(let dict) = try lexer.parseObject() else { throw PDFParseError("bad trailer") }
                return dict
            }
            guard let first = lexer.readInteger(), let count = lexer.readInteger() else {
                throw PDFParseError("bad xref subsection")
            }
            for index in 0..<count {
                guard let offset = lexer.readInteger(), let generation = lexer.readInteger() else {
                    throw PDFParseError("bad xref entry")
                }
                let kind = lexer.readToken()
                let number = first + index
                guard xref[number] == nil else { continue }
                xref[number] = kind == "n" ? .offset(offset, generation: generation) : .free
            }
        }
    }

    private func readXrefStream(at offset: Int) throws -> PDFDictionary {
        let stream = try parseIndirectObject(at: offset, expecting: nil)
        guard case .stream(let dict, _) = stream, dict["Type"]?.name == "XRef" else {
            throw PDFParseError("no xref at \(offset)")
        }
        let data = try decodedStream(stream)
        let widths = (dict["W"]?.array ?? []).compactMap(\.integer)
        guard widths.count == 3 else { throw PDFParseError("bad /W") }
        let size = dict["Size"]?.integer ?? 0
        let index = (dict["Index"]?.array ?? [.int(0), .int(size)]).compactMap(\.integer)
        let rowLength = widths.reduce(0, +)
        var position = 0

        func field(_ width: Int, default value: Int) -> Int {
            guard width > 0 else { return value }
            var result = 0
            for _ in 0..<width {
                result = result << 8 | Int(data[position])
                position += 1
            }
            return result
        }

        var pair = 0
        while pair + 1 < index.count {
            let first = index[pair], count = index[pair + 1]
            for i in 0..<count {
                guard position + rowLength <= data.count else { break }
                let type = field(widths[0], default: 1)
                let second = field(widths[1], default: 0)
                let third = field(widths[2], default: 0)
                let number = first + i
                guard xref[number] == nil else { continue }
                switch type {
                case 0: xref[number] = .free
                case 1: xref[number] = .offset(second, generation: third)
                case 2: xref[number] = .compressed(stream: second, index: third)
                default: break
                }
            }
            pair += 2
        }
        return dict
    }

    /// For a file whose cross-reference data is broken: find every "n g obj" and the last trailer
    private func rebuildXref() throws {
        xref = [:]
        cache = [:]
        usesXrefStream = false
        var found = PDFDictionary()
        var index = 0
        let objKeyword = Array("obj".utf8)
        while let hit = find(objKeyword, from: index) {
            index = hit + 3
            // Walk back over "n g "
            var cursor = hit - 1
            func skipBackWhitespace() { while cursor >= 0, PDFLexer.isWhitespace(bytes[cursor]) { cursor -= 1 } }
            func readBackDigits() -> Int? {
                let end = cursor
                while cursor >= 0, bytes[cursor] >= 0x30, bytes[cursor] <= 0x39 { cursor -= 1 }
                guard cursor < end else { return nil }
                return Int(String(decoding: bytes[(cursor + 1)...end], as: UTF8.self))
            }
            skipBackWhitespace()
            guard let generation = readBackDigits() else { continue }
            skipBackWhitespace()
            guard let number = readBackDigits() else { continue }
            xref[number] = .offset(cursor + 1, generation: generation)
        }
        var search = 0
        let trailerKeyword = Array("trailer".utf8)
        while let hit = find(trailerKeyword, from: search) {
            var lexer = PDFLexer(bytes, at: hit + 7)
            if case .dictionary(let dict) = try? lexer.parseObject() {
                for key in dict.keys { found[key] = dict[key] }
            }
            search = hit + 7
        }
        if found["Root"] == nil {
            // Catalog lookup by type for files that keep their trailer in an xref stream
            for number in xref.keys.sorted() {
                if let dict = object(number)?.dictionary, dict["Type"]?.name == "Catalog" {
                    found["Root"] = .reference(number, generation(of: number))
                }
                if let dict = object(number)?.dictionary, dict["Type"]?.name == "XRef" {
                    for key in ["Info", "ID"] where dict[key] != nil { found[key] = dict[key] }
                }
            }
        }
        found["Prev"] = nil
        found["XRefStm"] = nil
        found["Size"] = .int((xref.keys.max() ?? 0) + 1)
        trailer = found
        startxref = -1
    }

    // MARK: Byte search

    func find(_ needle: [UInt8], from start: Int) -> Int? {
        guard !needle.isEmpty, needle.count <= bytes.count else { return nil }
        let first = needle[0]
        var index = max(0, start)
        let last = bytes.count - needle.count
        while index <= last {
            if bytes[index] == first {
                var match = true
                for j in 1..<needle.count where bytes[index + j] != needle[j] {
                    match = false
                    break
                }
                if match { return index }
            }
            index += 1
        }
        return nil
    }

    func findLast(_ needle: [UInt8]) -> Int? {
        var index = bytes.count - needle.count
        while index >= 0 {
            if bytes[index] == needle[0], Array(bytes[index..<index + needle.count]) == needle { return index }
            index -= 1
        }
        return nil
    }
}
