import CoreGraphics
import Foundation

/// A line of text placed in a page's default user space: the text runs from `origin` along `run`
/// (its full length), and `rise` points from the bottom of the line to its top.
public struct PlacedLine {
    public var text: String
    public var origin: CGPoint
    public var run: CGVector
    public var rise: CGVector

    public init(text: String, origin: CGPoint, run: CGVector, rise: CGVector) {
        self.text = text
        self.origin = origin
        self.run = run
        self.rise = rise
    }
}

/// Builds an incremental update that lays invisible text over pages. The original bytes stay as
/// they are, so the file before the update is exactly the bytes up to its old length.
public enum TextLayerUpdate {
    /// Info dictionary key that marks a file this tool has updated
    public static let markerKey = "TextLayer"

    /// lines: text for each page index. Each of those pages has its own content wrapped in an empty
    /// /ActualText, so readers that honour it take the new layer instead of any text the page had
    /// (a page read again either had none, or had text that does not match what is printed).
    public static func make(
        file: PDFFile,
        pages: [PageEntry],
        lines: [Int: [PlacedLine]],
        marker: String
    ) throws -> [UInt8] {
        var writer = UpdateWriter(file: file)

        let fontFile = writer.add(.stream(
            PDFDictionary([("Length1", .int(GlyphlessFont.trueType.count)), ("Filter", .name("FlateDecode"))]),
            Flate.encode(GlyphlessFont.trueType)
        ))
        let descriptor = writer.add(.dictionary(PDFDictionary([
            ("Type", .name("FontDescriptor")),
            ("FontName", .name("GlyphLessFont")),
            ("Flags", .int(5)),
            ("FontBBox", .array([.int(0), .int(0), .int(GlyphlessFont.advance), .int(1000)])),
            ("ItalicAngle", .int(0)),
            ("Ascent", .int(1000)),
            ("Descent", .int(-1)),
            ("CapHeight", .int(1000)),
            ("StemV", .int(80)),
            ("FontFile2", fontFile),
        ])))
        let gidMap = writer.add(.stream(
            PDFDictionary([("Filter", .name("FlateDecode"))]),
            Flate.encode(GlyphlessFont.cidToGIDMap)
        ))
        let cidFont = writer.add(.dictionary(PDFDictionary([
            ("Type", .name("Font")),
            ("Subtype", .name("CIDFontType2")),
            ("BaseFont", .name("GlyphLessFont")),
            ("CIDSystemInfo", .dictionary(PDFDictionary([
                ("Registry", .text("Adobe")), ("Ordering", .text("Identity")), ("Supplement", .int(0)),
            ]))),
            ("FontDescriptor", descriptor),
            ("DW", .int(GlyphlessFont.advance)),
            ("CIDToGIDMap", gidMap),
        ])))
        let toUnicode = writer.add(.stream(
            PDFDictionary([("Filter", .name("FlateDecode"))]),
            Flate.encode(GlyphlessFont.toUnicode)
        ))
        let font = writer.add(.dictionary(PDFDictionary([
            ("Type", .name("Font")),
            ("Subtype", .name("Type0")),
            ("BaseFont", .name("GlyphLessFont")),
            ("Encoding", .name("Identity-H")),
            ("DescendantFonts", .array([cidFont])),
            ("ToUnicode", toUnicode),
        ])))

        let prefix = writer.add(.stream(PDFDictionary(), Array("q\n/Span <</ActualText ()>> BDC\n".utf8)))

        for (index, page) in pages.enumerated() {
            guard let pageLines = lines[index] else { continue }

            var resources = file.resolve(page.resources)?.dictionary ?? PDFDictionary()
            var fonts = file.resolve(resources["Font"])?.dictionary ?? PDFDictionary()
            var fontName = "TextLayerOCR"
            var suffix = 1
            while fonts[fontName] != nil {
                fontName = "TextLayerOCR\(suffix)"
                suffix += 1
            }
            fonts[fontName] = font
            resources["Font"] = .dictionary(fonts)

            let closing = "\nEMC\nQ\n" + textOperators(pageLines, fontName: fontName)
            let textStream = writer.add(.stream(
                PDFDictionary([("Filter", .name("FlateDecode"))]),
                Flate.encode(Array(closing.utf8))
            ))

            var contents: [PDFObject] = []
            switch page.dictionary["Contents"] {
            case .reference(let number, _):
                if let items = file.object(number)?.array { contents = items } else { contents = [page.dictionary["Contents"]!] }
            case .array(let items): contents = items
            case nil: contents = []
            default: throw PDFParseError("page \(index + 1) has unreadable contents")
            }
            // Spans of the page's own /ActualText would win over the empty one around them, so they go
            if let decoded = try? contents.map({ part -> [UInt8] in
                guard let stream = file.resolve(part) else { throw PDFParseError("missing content stream") }
                return try file.decodedStream(stream)
            }), let stripped = ContentStream.removingActualText(Array(decoded.joined(separator: [0x0A]))) {
                contents = [writer.add(.stream(PDFDictionary([("Filter", .name("FlateDecode"))]), Flate.encode(stripped)))]
            }

            var dict = page.dictionary
            dict["Contents"] = .array([prefix] + contents + [textStream])
            dict["Resources"] = .dictionary(resources)
            writer.put(page.number, generation: page.generation, .dictionary(dict))
        }

        // Info marker
        var info = PDFDictionary()
        var infoNumber: (Int, Int)?
        if case .reference(let number, let generation) = file.trailer["Info"] {
            info = file.object(number)?.dictionary ?? PDFDictionary()
            infoNumber = (number, generation)
        } else if let direct = file.trailer["Info"]?.dictionary {
            info = direct
        }
        info[markerKey] = .text(marker)
        let infoRef: PDFObject
        if let infoNumber {
            writer.put(infoNumber.0, generation: infoNumber.1, .dictionary(info))
            infoRef = .reference(infoNumber.0, infoNumber.1)
        } else {
            infoRef = writer.add(.dictionary(info))
        }

        return writer.finish(info: infoRef)
    }

    static func textOperators(_ lines: [PlacedLine], fontName: String) -> String {
        var ops = "BT\n3 Tr\n/\(fontName) 1 Tf\n"
        for line in lines {
            // Characters outside the BMP have no code in this font's mapping
            let units = line.text.unicodeScalars.filter { $0.value <= 0xFFFF }.map { UInt16($0.value) }
            guard !units.isEmpty else { continue }
            let runLength = hypot(line.run.dx, line.run.dy)
            let riseLength = hypot(line.rise.dx, line.rise.dy)
            guard runLength > 0.5, riseLength > 0.5 else { continue }
            let advance = Double(units.count) * Double(GlyphlessFont.advance) / 1000
            let f = PDFObject.format
            ops += "\(f(line.run.dx / advance)) \(f(line.run.dy / advance)) \(f(line.rise.dx)) \(f(line.rise.dy)) "
            ops += "\(f(line.origin.x)) \(f(line.origin.y)) Tm\n<"
            ops += units.map { String(format: "%04X", $0) }.joined()
            ops += "> Tj\n"
        }
        ops += "ET\n"
        return ops
    }
}

/// Collects the objects of an update and writes them after the original bytes.
struct UpdateWriter {
    let file: PDFFile
    private var body: [UInt8] = []
    private var offsets: [Int: (offset: Int, generation: Int)] = [:]
    private var nextNumber: Int
    private let base: Int

    init(file: PDFFile) {
        self.file = file
        nextNumber = file.size
        base = file.bytes.count
        if let last = file.bytes.last, last != 0x0A, last != 0x0D { body.append(0x0A) }
    }

    mutating func add(_ object: PDFObject) -> PDFObject {
        let number = nextNumber
        nextNumber += 1
        put(number, generation: 0, object)
        return .reference(number, 0)
    }

    mutating func put(_ number: Int, generation: Int, _ object: PDFObject) {
        offsets[number] = (base + body.count, generation)
        body += Array("\(number) \(generation) obj\n".utf8)
        object.write(to: &body)
        body += Array("\nendobj\n".utf8)
    }

    mutating func finish(info: PDFObject) -> [UInt8] {
        var trailer = PDFDictionary()
        trailer["Root"] = file.trailer["Root"]
        trailer["Info"] = info
        if let id = file.trailer["ID"] { trailer["ID"] = id }
        // Without a usable chain to point back to, the update lists every object
        let full = file.startxref < 0
        if !full { trailer["Prev"] = .int(file.startxref) }

        var entries: [Int: (offset: Int, generation: Int, inUse: Bool)] = [:]
        if full {
            for (number, entry) in file.xref {
                if case .offset(let offset, let generation) = entry { entries[number] = (offset, generation, true) }
            }
            entries[0] = (0, 65535, false)
        }
        for (number, value) in offsets { entries[number] = (value.offset, value.generation, true) }

        if file.usesXrefStream && !full {
            let number = nextNumber
            nextNumber += 1
            let xrefOffset = base + body.count
            entries[number] = (xrefOffset, 0, true)
            trailer["Size"] = .int(nextNumber)
            let width = xrefOffset > 0xFFFF_FFFF ? 8 : 4
            var data: [UInt8] = []
            var index: [PDFObject] = []
            for run in Self.runs(entries.keys.sorted()) {
                index += [.int(run.first!), .int(run.count)]
                for number in run {
                    let entry = entries[number]!
                    data.append(entry.inUse ? 1 : 0)
                    for shift in stride(from: (width - 1) * 8, through: 0, by: -8) {
                        data.append(UInt8((entry.offset >> shift) & 0xFF))
                    }
                    data += [UInt8((entry.generation >> 8) & 0xFF), UInt8(entry.generation & 0xFF)]
                }
            }
            trailer["Type"] = .name("XRef")
            trailer["W"] = .array([.int(1), .int(width), .int(2)])
            trailer["Index"] = .array(index)
            body += Array("\(number) 0 obj\n".utf8)
            PDFObject.stream(trailer, data).write(to: &body)
            body += Array("\nendobj\nstartxref\n\(xrefOffset)\n%%EOF\n".utf8)
            return body
        }

        trailer["Size"] = .int(max(nextNumber, (entries.keys.max() ?? 0) + 1))
        let xrefOffset = base + body.count
        body += Array("xref\n".utf8)
        for run in Self.runs(entries.keys.sorted()) {
            body += Array("\(run.first!) \(run.count)\n".utf8)
            for number in run {
                let entry = entries[number]!
                body += Array(String(format: "%010d %05d %@\r\n", entry.offset, entry.generation, entry.inUse ? "n" : "f").utf8)
            }
        }
        body += Array("trailer\n".utf8)
        PDFObject.dictionary(trailer).write(to: &body)
        body += Array("\nstartxref\n\(xrefOffset)\n%%EOF\n".utf8)
        return body
    }

    static func runs(_ numbers: [Int]) -> [[Int]] {
        var runs: [[Int]] = []
        for number in numbers {
            if let last = runs.last?.last, last + 1 == number {
                runs[runs.count - 1].append(number)
            } else {
                runs.append([number])
            }
        }
        return runs
    }
}
