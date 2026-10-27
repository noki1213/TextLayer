import Foundation

/// How much of what is printed on pages (as read by OCR) the pages' own text contains, counted
/// separately for kanji, kana and everything else.
///
/// Text that is merely incomplete because some of the printing is inside pictures misses a similar
/// share of every kind of character. Text from a font that lost its Japanese misses the kanji (or
/// all Japanese) while keeping the rest, and garbled text misses nearly everything.
struct CharacterMatch: CustomStringConvertible {
    enum Kind: CaseIterable { case kanji, kana, other }

    private(set) var printed: [Kind: Int] = [:]
    private(set) var matched: [Kind: Int] = [:]

    /// Fewer printed characters of a kind than this say nothing about it
    static let minimumSample = 15

    static func kind(of character: Character) -> Kind {
        guard let scalar = character.unicodeScalars.first?.value else { return .other }
        switch scalar {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF: return .kanji
        case 0x3040...0x30FF: return .kana
        default: return .other
        }
    }

    mutating func add(printed printedCharacters: [Character], own: [Character]) {
        var available: [Character: Int] = [:]
        for character in own { available[character, default: 0] += 1 }
        for character in printedCharacters {
            let kind = Self.kind(of: character)
            printed[kind, default: 0] += 1
            if (available[character] ?? 0) > 0 {
                available[character]! -= 1
                matched[kind, default: 0] += 1
            }
        }
    }

    /// nil: all kinds together
    func recall(of kind: Kind?) -> Double {
        let total = kind.map { printed[$0] ?? 0 } ?? printed.values.reduce(0, +)
        let hits = kind.map { matched[$0] ?? 0 } ?? matched.values.reduce(0, +)
        return total == 0 ? 1 : Double(hits) / Double(total)
    }

    private func sampled(_ kind: Kind) -> Bool { (printed[kind] ?? 0) >= Self.minimumSample }

    var isBroken: Bool {
        let total = printed.values.reduce(0, +)
        guard total >= 30 else { return false }
        // Garbled throughout
        if recall(of: nil) < 0.25 { return true }
        // Japanese lost while the rest came through
        let japanese = (printed[.kanji] ?? 0) + (printed[.kana] ?? 0)
        let japaneseHits = (matched[.kanji] ?? 0) + (matched[.kana] ?? 0)
        if japanese >= Self.minimumSample, sampled(.other),
           Double(japaneseHits) / Double(japanese) < recall(of: .other) * 0.5 {
            return true
        }
        // Kanji lost while the kana came through
        if sampled(.kanji), sampled(.kana), recall(of: .kanji) < recall(of: .kana) * 0.5 {
            return true
        }
        return false
    }

    var description: String {
        Kind.allCases.map { kind in
            "\(kind) \(matched[kind] ?? 0)/\(printed[kind] ?? 0)"
        }.joined(separator: ", ")
    }
}
