import Foundation

/// A TrueType font with one empty glyph, used for invisible text: every character code maps to that
/// glyph, so nothing depends on which characters a real font happens to cover.
/// From Tesseract (pdf.ttf), Apache License 2.0.
enum GlyphlessFont {
    static let trueType: [UInt8] = Array(Data(base64Encoded: """
        AAEAAAAKAIAAAwAgT1MvMlbeyJQAAAEoAAAAYGNtYXAACgA0AAABkAAAAB5nbHlmFSJBJAAAAbgA\
        AAAYaGVhZAt48WUAAACsAAAANmhoZWEMAgQCAAAA5AAAACRobXR4BAAAAAAAAYgAAAAIbG9jYQAM\
        AAAAAAGwAAAABm1heHAABAAFAAABCAAAACBuYW1l8usW2gAAAdAAAABLcG9zdAABAAEAAAIcAAAA\
        IAABAAAAAQAAsJRxEF8PPPUEBwgAAAAAAM+a/G4AAAAA1MOn8gAAAAAEAAgAAAAAEAACAAAAAAAA\
        AAEAAAgA//8AAAQAAAAAAAQAAAEAAAAAAAAAAAAAAAAAAAACAAEAAAACAAQAAQAAAAAAAQAAAAAA\
        AAAAAAAAAAAAAAAAAwAAAZAABQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAUAAQABAAAAAAAAAAAA\
        AAAAAAAAAAAAAAAAR09PRwBAAAAAAAAB//8AAAABAAGAAAAAAAAAAAAAAAAAAAABAAAAAAAABAAA\
        AAAAAAIAAQAAAAAAFAADAAAAAAAUAAYACgAAAAAAAAAAAAAAAAAMAAAAAQAAAAAEAAgAAAMAADEh\
        ESEEAPwACAAAAAADACoAAAADAAAABQAWAAAAAQAAAAAABQALABYAAwABBAkABQAWAAAAVgBlAHIA\
        cwBpAG8AbgAgADEALgAwVmVyc2lvbiAxLjAAAAEAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAA\
        AAA=
        """)!)

    /// Advance of every glyph, in thousandths of the font size
    static let advance = 500

    /// Character codes are UTF-16 code units and read back as themselves. Ranges stay within one
    /// high byte, and the surrogate block is left out.
    static var toUnicode: [UInt8] {
        var ranges: [String] = []
        for high in 0...0xFF where !(0xD8...0xDF).contains(high) {
            let prefix = String(format: "%02X", high)
            ranges.append("<\(prefix)00> <\(prefix)FF> <\(prefix)00>")
        }
        var text = """
            /CIDInit /ProcSet findresource begin
            12 dict begin
            begincmap
            /CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def
            /CMapName /Adobe-Identity-UCS def
            /CMapType 2 def
            1 begincodespacerange
            <0000> <FFFF>
            endcodespacerange

            """
        var index = 0
        while index < ranges.count {
            let chunk = ranges[index..<min(index + 100, ranges.count)]
            text += "\(chunk.count) beginbfrange\n" + chunk.joined(separator: "\n") + "\nendbfrange\n"
            index += 100
        }
        text += """
            endcmap
            CMapName currentdict /CMap defineresource pop
            end
            end

            """
        return Array(text.utf8)
    }

    /// Every CID drawn with glyph 1
    static var cidToGIDMap: [UInt8] {
        var map = [UInt8](repeating: 0, count: 65536 * 2)
        for index in stride(from: 1, to: map.count, by: 2) { map[index] = 1 }
        return map
    }
}
