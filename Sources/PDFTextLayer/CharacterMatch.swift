import Foundation

/// How much of what is printed on pages (as read by OCR, line by line) the pages' own text
/// contains, counted separately for kanji, kana and everything else.
///
/// Text that is merely incomplete because some of the printing is inside pictures misses whole
/// lines: figure labels, screenshots. Text from a font that lost its Japanese misses characters
/// inside lines it otherwise has: the kanji between kana it kept, or the Japanese next to Latin
/// text it kept. Garbled text misses nearly everything, and much of what it has is not printed.
struct CharacterMatch: CustomStringConvertible {
    enum Kind: CaseIterable { case kanji, kana, other }

    private(set) var printed: [Kind: Int] = [:]
    private(set) var matched: [Kind: Int] = [:]
    /// The own text's characters, and how many of them are also printed
    private(set) var ownTotal = 0
    private(set) var ownMatched = 0
    /// Kanji in lines whose kana the own text has
    private(set) var anchoredKanji = (printed: 0, matched: 0)
    /// Japanese in lines whose other characters the own text has
    private(set) var anchoredJapanese = (printed: 0, matched: 0)

    /// Fewer characters than this say nothing
    static let minimumSample = 15
    /// A line counts as present in the own text when this share of a kind of its characters is there
    static let presentShare = 0.7

    static func kind(of character: Character) -> Kind {
        guard let scalar = character.unicodeScalars.first?.value else { return .other }
        switch scalar {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF: return .kanji
        case 0x3040...0x30FF: return .kana
        default: return .other
        }
    }

    /// printedLines: the letters of each line read off one page; own: the letters of the page's own text
    mutating func add(printedLines: [[Character]], own: [Character]) {
        var available: [Character: Int] = [:]
        for character in own { available[character, default: 0] += 1 }
        var printedAvailable: [Character: Int] = [:]
        for character in printedLines.joined() { printedAvailable[character, default: 0] += 1 }
        ownTotal += own.count
        for character in own where (printedAvailable[character] ?? 0) > 0 {
            printedAvailable[character]! -= 1
            ownMatched += 1
        }

        for line in printedLines {
            var linePrinted: [Kind: Int] = [:]
            var lineMatched: [Kind: Int] = [:]
            for character in line {
                let kind = Self.kind(of: character)
                linePrinted[kind, default: 0] += 1
                if (available[character] ?? 0) > 0 {
                    available[character]! -= 1
                    lineMatched[kind, default: 0] += 1
                }
            }
            for kind in Kind.allCases {
                printed[kind, default: 0] += linePrinted[kind] ?? 0
                matched[kind, default: 0] += lineMatched[kind] ?? 0
            }

            func present(_ kind: Kind, atLeast count: Int) -> Bool {
                let total = linePrinted[kind] ?? 0
                return total >= count && Double(lineMatched[kind] ?? 0) >= Double(total) * Self.presentShare
            }
            if present(.kana, atLeast: 2) {
                anchoredKanji.printed += linePrinted[.kanji] ?? 0
                anchoredKanji.matched += lineMatched[.kanji] ?? 0
            }
            if present(.other, atLeast: 3) {
                anchoredJapanese.printed += (linePrinted[.kanji] ?? 0) + (linePrinted[.kana] ?? 0)
                anchoredJapanese.matched += (lineMatched[.kanji] ?? 0) + (lineMatched[.kana] ?? 0)
            }
        }
    }

    /// Share of the own text's characters that are printed
    var precision: Double { ownTotal == 0 ? 0 : Double(ownMatched) / Double(ownTotal) }

    /// nil: all kinds together
    func recall(of kind: Kind?) -> Double {
        let total = kind.map { printed[$0] ?? 0 } ?? printed.values.reduce(0, +)
        let hits = kind.map { matched[$0] ?? 0 } ?? matched.values.reduce(0, +)
        return total == 0 ? 1 : Double(hits) / Double(total)
    }

    private static func lacks(_ pair: (printed: Int, matched: Int)) -> Bool {
        pair.printed >= minimumSample && Double(pair.matched) < Double(pair.printed) * 0.5
    }

    var isBroken: Bool {
        let total = printed.values.reduce(0, +)
        guard total >= 30 else { return false }
        // Garbled throughout
        let precision = ownTotal == 0 ? 0 : Double(ownMatched) / Double(ownTotal)
        if recall(of: nil) < 0.25, precision < 0.5 { return true }
        // OCR reads the odd dash or symbol in Latin text as a kanji; Japanese that makes up only a
        // sliver of the page is that, not text that went missing
        let japanese = (printed[.kanji] ?? 0) + (printed[.kana] ?? 0)
        guard Double(japanese) >= Double(total) * 0.05 else { return false }
        // Kanji missing from lines whose kana are there
        if Self.lacks(anchoredKanji) { return true }
        // Japanese missing from lines whose other characters are there
        if Self.lacks(anchoredJapanese) { return true }
        // No Japanese at all although the rest came through
        let japaneseHits = (matched[.kanji] ?? 0) + (matched[.kana] ?? 0)
        if japanese >= Self.minimumSample, (printed[.other] ?? 0) >= Self.minimumSample,
           Double(japaneseHits) < Double(japanese) * 0.1, recall(of: .other) >= 0.5 {
            return true
        }
        return false
    }

    var description: String {
        Kind.allCases.map { "\($0) \(matched[$0] ?? 0)/\(printed[$0] ?? 0)" }.joined(separator: ", ")
            + ", kanji beside kana \(anchoredKanji.matched)/\(anchoredKanji.printed)"
            + ", Japanese beside other \(anchoredJapanese.matched)/\(anchoredJapanese.printed)"
            + ", own text printed \(ownMatched)/\(ownTotal)"
    }
}
