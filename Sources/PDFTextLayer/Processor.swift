import CoreGraphics
import CryptoKit
import Foundation
import PDFKit

public struct ProcessOptions {
    /// Copy of each file as it was before the update; nil keeps none
    public var backupDirectory: URL?
    /// Write the updated file here (under its path relative to the folder it was found in)
    /// instead of updating it in place
    public var outputDirectory: URL?
    public var dryRun = false
    /// Pages read at the same time
    public var jobs = max(1, ProcessInfo.processInfo.activeProcessorCount - 2)

    public init() {}

    public static var defaultBackupDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/TextLayer/Originals", isDirectory: true)
    }
}

public enum Outcome {
    case skipped(String)
    case updated(String)
    case failed(String)
}

/// What a file needs, worked out from the text it already has.
struct Assessment {
    enum Plan {
        case nothing(String)
        /// Read the pages with too little text of their own
        case fillEmptyPages([Int])
        /// The text the file has does not match what is printed: read every page and hide the old text
        case replaceText(recall: Double)
    }
    let plan: Plan
    /// Pages already read while assessing, to reuse
    var recognized: [Int: [PlacedLine]] = [:]
    var match: CharacterMatch?
}

public final class Processor {
    public let options: ProcessOptions
    private let queue: OperationQueue
    private let logLock = NSLock()

    /// A page with fewer letters of its own than this is read again: what it has is at most a
    /// heading, a date or a page number over pictures or handwriting, and reading it again keeps those
    static let minimumPageText = 60
    /// Share of the printed characters an invisible OCR layer has to hold to be kept
    static let minimumLayerRecall = 0.8
    /// Share of an invisible OCR layer's own characters that have to be printed for it to be kept
    static let minimumLayerPrecision = 0.85

    public init(options: ProcessOptions) {
        self.options = options
        queue = OperationQueue()
        queue.maxConcurrentOperationCount = options.jobs
        queue.qualityOfService = .utility
    }

    /// root: the folder the file was found in, for its relative path under the output directory
    public func process(_ url: URL, root: URL?) -> Outcome {
        do {
            return try run(url, root: root)
        } catch {
            return .failed("\(error)")
        }
    }

    private func run(_ url: URL, root: URL?) throws -> Outcome {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return .skipped("not a regular file") }
        // iCloud placeholder whose content is not on this Mac
        if info.st_flags & UInt32(SF_DATALESS) != 0 { return .skipped("not downloaded") }
        let modified = info.st_mtimespec

        let bytes = [UInt8](try Data(contentsOf: url))
        var file = try PDFFile(bytes: bytes)
        if file.isEncrypted { return .skipped("encrypted") }
        if file.resolve(file.trailer["Info"])?.dictionary?[TextLayerUpdate.markerKey] != nil {
            return .skipped("already has a text layer from this tool")
        }
        let pages: [PageEntry]
        do {
            pages = try file.pages()
        } catch {
            file = try PDFFile(bytes: bytes, rebuild: true)
            pages = try file.pages()
        }
        guard let rendered = CGPDFDocument(url as CFURL), let document = PDFDocument(url: url) else {
            return .failed("cannot open")
        }
        guard rendered.numberOfPages == pages.count, document.pageCount == pages.count else {
            return .failed("page count differs between readers (\(pages.count), \(rendered.numberOfPages), \(document.pageCount))")
        }

        let texts = (0..<pages.count).map { document.page(at: $0)?.string ?? "" }
        let renderLock = NSLock()
        var assessment = try assess(texts: texts, file: file, pages: pages, document: rendered, lock: renderLock)

        let targets: [Int]
        switch assessment.plan {
        case .nothing(let reason):
            if options.dryRun, let match = assessment.match { return .skipped(reason + " [\(match.description)]") }
            return .skipped(reason)
        case .fillEmptyPages(let indices): targets = indices
        case .replaceText: targets = Array(0..<pages.count)
        }

        let pending = targets.filter { assessment.recognized[$0] == nil }
        for (index, lines) in try recognize(pages: pending, document: rendered, lock: renderLock) {
            assessment.recognized[index] = lines
        }
        var lines: [Int: [PlacedLine]] = [:]
        for index in targets { lines[index] = assessment.recognized[index] ?? [] }
        let lineCount = lines.values.reduce(0) { $0 + $1.count }
        guard lineCount > 0 else { return .skipped("no text found on \(targets.count) page(s) without text") }

        let pagesWithText = lines.values.filter { !$0.isEmpty }.count
        var summary = "\(pagesWithText)/\(pages.count) pages, \(lineCount) lines"
        if case .replaceText(let recall) = assessment.plan {
            summary += ", own text replaced (matched \(Int(recall * 100))%)"
        }
        if options.dryRun, let match = assessment.match {
            summary += " [\(match.description)]"
        }
        if options.dryRun { return .updated("would add: " + summary) }

        let marker = "1; Vision OCR \(ISO8601DateFormatter().string(from: Date()))"
        let update = try TextLayerUpdate.make(file: file, pages: pages, lines: lines, marker: marker)

        if let outputDirectory = options.outputDirectory {
            let destination = outputDirectory.appendingPathComponent(relativePath(of: url, root: root))
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(bytes + update).write(to: destination)
            try verify(destination, pageCount: pages.count, expectText: lines)
            return .updated(summary + " -> " + destination.path)
        }

        var backup: URL?
        if let directory = options.backupDirectory {
            backup = try makeBackup(of: url, in: directory)
        }

        // Append only if the file is still what was read
        var now = stat()
        guard stat(url.path, &now) == 0, now.st_size == off_t(bytes.count),
              now.st_mtimespec.tv_sec == modified.tv_sec, now.st_mtimespec.tv_nsec == modified.tv_nsec else {
            return .failed("changed while being read")
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(update))
        try handle.close()

        do {
            try verify(url, pageCount: pages.count, expectText: lines)
        } catch {
            let undo = try FileHandle(forWritingTo: url)
            try undo.truncate(atOffset: UInt64(bytes.count))
            try undo.close()
            return .failed("check after writing failed, file put back: \(error)")
        }

        if let directory = options.backupDirectory {
            appendLog(in: directory, url: url, original: bytes, backup: backup, summary: summary)
        }
        return .updated(summary)
    }

    // MARK: Assessing

    private func assess(texts: [String], file: PDFFile, pages: [PageEntry], document: CGPDFDocument, lock: NSLock) throws -> Assessment {
        // Text made of control characters is a font without a Unicode mapping
        let joined = texts.joined()
        let controls = joined.unicodeScalars.filter { $0.value < 0x20 && $0 != "\n" && $0 != "\r" && $0 != "\t" }.count
        if controls >= Self.minimumPageText, Double(controls) > Double(joined.unicodeScalars.count) * 0.3 {
            return Assessment(plan: .replaceText(recall: 0))
        }

        let counts = texts.map(Self.letterCount)
        let empty = counts.indices.filter { counts[$0] < Self.minimumPageText }
        let withText = counts.indices.filter { counts[$0] >= Self.minimumPageText }
        guard !withText.isEmpty else {
            return Assessment(plan: .fillEmptyPages(empty))
        }

        // Compare a few pages' own text with what is printed on them
        let samples = Array(Set([0.2, 0.5, 0.8].map { withText[Int(Double(withText.count - 1) * $0)] })).sorted()

        // Text that is all invisible is an OCR layer over a picture
        let invisibleOnly = samples.allSatisfy { index in
            guard let content = pageContent(file: file, page: pages[index]) else { return false }
            return ContentStream.showsOnlyInvisibleText(content)
        }
        let read = try recognize(pages: samples, document: document, lock: lock)
        var match = CharacterMatch()
        for index in samples {
            let printedLines = (read[index] ?? []).map { Self.letters(of: $0.text) }
            guard printedLines.joined().count >= 30 else { continue }
            match.add(printedLines: printedLines, own: Self.letters(of: texts[index]))
        }
        var assessment: Assessment
        // Another OCR's layer stays when it reads as well as Vision does (one made the same way,
        // such as a captured book); a weaker one, as scanners tend to make, is read again
        let layerReadsWell = match.recall(of: nil) >= Self.minimumLayerRecall && match.precision >= Self.minimumLayerPrecision
        if invisibleOnly, !match.isBroken, !layerReadsWell {
            assessment = Assessment(plan: .replaceText(recall: match.recall(of: nil)))
        } else if invisibleOnly, !match.isBroken {
            // Reading any of its pages again would only show the same text twice in PDFKit
            assessment = Assessment(plan: .nothing("has an OCR layer that reads well"))
        } else if match.isBroken {
            assessment = Assessment(plan: .replaceText(recall: match.recall(of: nil)))
        } else if empty.isEmpty {
            assessment = Assessment(plan: .nothing("has text"))
        } else {
            assessment = Assessment(plan: .fillEmptyPages(empty))
        }
        assessment.recognized = read
        assessment.match = match
        return assessment
    }

    /// The page's content streams, decoded and joined
    private func pageContent(file: PDFFile, page: PageEntry) -> [UInt8]? {
        var parts: [PDFObject] = []
        switch page.dictionary["Contents"] {
        case .reference(let number, _):
            parts = file.object(number)?.array ?? [page.dictionary["Contents"]!]
        case .array(let items): parts = items
        default: return nil
        }
        var content: [UInt8] = []
        for part in parts {
            guard let stream = file.resolve(part), let data = try? file.decodedStream(stream) else { return nil }
            content += data + [0x0A]
        }
        return content
    }

    static func letters(of text: String) -> [Character] {
        text.precomposedStringWithCompatibilityMapping.lowercased().filter { $0.isLetter || $0.isNumber }.map { $0 }
    }

    static func letterCount(_ text: String) -> Int {
        text.reduce(0) { $0 + (($1.isLetter || $1.isNumber) ? 1 : 0) }
    }

    /// Share of the printed characters that the page's own text also has (as a multiset)
    static func recall(printed: [Character], own: [Character]) -> Double {
        var match = CharacterMatch()
        match.add(printedLines: [printed], own: own)
        return match.recall(of: nil)
    }

    // MARK: Reading pages

    private func recognize(pages indices: [Int], document: CGPDFDocument, lock: NSLock) throws -> [Int: [PlacedLine]] {
        var results: [Int: [PlacedLine]] = [:]
        var firstError: Error?
        let resultLock = NSLock()
        let group = DispatchGroup()
        for index in indices {
            group.enter()
            queue.addOperation {
                defer { group.leave() }
                autoreleasepool {
                    guard let page = document.page(at: index + 1) else { return }
                    do {
                        let lines = try PageOCR.recognize(page, renderLock: lock)
                        resultLock.lock()
                        results[index] = lines
                        resultLock.unlock()
                    } catch {
                        resultLock.lock()
                        if firstError == nil { firstError = error }
                        resultLock.unlock()
                    }
                }
            }
        }
        group.wait()
        if let firstError { throw firstError }
        return results
    }

    // MARK: Checking, backups and log

    private func verify(_ url: URL, pageCount: Int, expectText lines: [Int: [PlacedLine]]) throws {
        guard let document = PDFDocument(url: url), document.pageCount == pageCount else {
            throw PDFParseError("updated file does not open with the same pages")
        }
        guard CGPDFDocument(url as CFURL)?.numberOfPages == pageCount else {
            throw PDFParseError("updated file does not render")
        }
        _ = try PDFFile(bytes: [UInt8](try Data(contentsOf: url))).pages()
        if let (index, pageLines) = lines.first(where: { !$0.value.isEmpty }) {
            let text = Self.letters(of: document.page(at: index)?.string ?? "")
            let expected = Self.letters(of: pageLines.map(\.text).joined())
            guard Self.recall(printed: expected, own: text) > 0.8 else {
                throw PDFParseError("added text does not read back on page \(index + 1)")
            }
        }
    }

    private func relativePath(of url: URL, root: URL?) -> String {
        let path = url.standardizedFileURL.path
        if let root {
            let base = root.standardizedFileURL.path
            if path.hasPrefix(base + "/") { return String(path.dropFirst(base.count + 1)) }
        }
        return url.lastPathComponent
    }

    /// Mirrors the file's path (relative to the home folder) under the backup folder
    private func makeBackup(of url: URL, in directory: URL) throws -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        var path = url.standardizedFileURL.path
        if path.hasPrefix(home + "/") { path = String(path.dropFirst(home.count + 1)) }
        var destination = directory.appendingPathComponent(path)
        if FileManager.default.fileExists(atPath: destination.path) {
            let stamp = Int(Date().timeIntervalSince1970)
            destination = destination.deletingPathExtension().appendingPathExtension("\(stamp).pdf")
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: url, to: destination)
        return destination
    }

    private func appendLog(in directory: URL, url: URL, original: [UInt8], backup: URL?, summary: String) {
        let digest = SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined()
        let fields = [
            ISO8601DateFormatter().string(from: Date()), url.standardizedFileURL.path, String(original.count),
            digest, backup?.path ?? "", summary,
        ]
        let line = fields.joined(separator: "\t") + "\n"
        logLock.lock()
        defer { logLock.unlock() }
        let log = directory.appendingPathComponent("log.tsv")
        if let handle = try? FileHandle(forWritingTo: log) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: log)
        }
    }
}
