import Foundation

/// A page as the file stores it, with the entries it inherits from the page tree filled in.
public struct PageEntry {
    public let number: Int
    public let generation: Int
    public let dictionary: PDFDictionary
    /// Resources in effect for the page (its own or inherited); a reference or a dictionary
    public let resources: PDFObject?
}

extension PDFFile {
    public func pages() throws -> [PageEntry] {
        guard let catalog = resolve(trailer["Root"])?.dictionary,
              case .reference(let rootNumber, _) = catalog["Pages"] else {
            throw PDFParseError("no page tree")
        }
        var pages: [PageEntry] = []
        var visited: Set<Int> = []

        func walk(_ number: Int, inherited: PDFObject?) throws {
            guard !visited.contains(number) else { throw PDFParseError("page tree loops") }
            visited.insert(number)
            guard let node = object(number)?.dictionary else { throw PDFParseError("page object \(number) unreadable") }
            let resources = node["Resources"] ?? inherited
            let isPage = node["Type"]?.name == "Page" || (node["Type"] == nil && node["Kids"] == nil)
            if isPage {
                pages.append(PageEntry(number: number, generation: generation(of: number), dictionary: node, resources: resources))
                return
            }
            for kid in resolve(node["Kids"])?.array ?? [] {
                guard case .reference(let kidNumber, _) = kid else { throw PDFParseError("page tree kid is not a reference") }
                try walk(kidNumber, inherited: resources)
            }
        }

        try walk(rootNumber, inherited: nil)
        return pages
    }
}
