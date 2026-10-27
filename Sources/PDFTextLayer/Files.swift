import CoreServices
import CryptoKit
import Foundation

public enum PDFFinder {
    /// PDFs under the given files and folders, each with the folder it was found from. Hidden files
    /// and folders (build caches, .git) are left out.
    public static func files(in urls: [URL]) -> [(URL, URL)] {
        var found: [(URL, URL)] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if !isDirectory.boolValue {
                found.append((url, url.deletingLastPathComponent()))
                continue
            }
            let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )
            while let item = enumerator?.nextObject() as? URL {
                if isPDF(item) { found.append((item, url)) }
            }
        }
        return found.sorted { $0.0.path < $1.0.path }
    }

    static func isPDF(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "pdf" && !url.lastPathComponent.hasPrefix(".")
    }
}

/// Undoes apply from the backup log.
public enum Restorer {
    public static func restore(_ url: URL, backupDirectory: URL) throws -> String {
        let log = (try? String(contentsOf: backupDirectory.appendingPathComponent("log.tsv"), encoding: .utf8)) ?? ""
        let path = url.standardizedFileURL.path
        guard let entry = log.split(separator: "\n").map({ $0.split(separator: "\t", omittingEmptySubsequences: false) })
            .last(where: { $0.count >= 6 && String($0[1]) == path }) else {
            throw PDFParseError("not in the backup log")
        }
        let originalSize = Int(entry[2]) ?? -1
        let digest = String(entry[3])
        let backup = String(entry[4])

        let current = try Data(contentsOf: url)
        // The update only appended, so the original is the start of the file as long as nothing rewrote it since
        if originalSize > 0, current.count > originalSize,
           SHA256.hash(data: current.prefix(originalSize)).map({ String(format: "%02x", $0) }).joined() == digest {
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(originalSize))
            try handle.close()
            return "cut back to the original \(originalSize) bytes"
        }
        guard !backup.isEmpty, FileManager.default.fileExists(atPath: backup) else {
            throw PDFParseError("file was changed since and no backup copy is kept")
        }
        let original = try Data(contentsOf: URL(fileURLWithPath: backup))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: original)
        try handle.close()
        return "copied back from \(backup) (changes made after apply are gone)"
    }
}

/// Watches a folder tree with FSEvents and hands PDFs to the processor once they have stopped changing.
public final class FolderWatcher {
    let folder: URL
    let settle: TimeInterval
    let processor: Processor
    private let stateQueue = DispatchQueue(label: "textlayer.watch.state")
    private let workQueue = DispatchQueue(label: "textlayer.watch.work", qos: .utility)
    private var pending: [String: Date] = [:]
    private var working = false
    private var stream: FSEventStreamRef?
    private var timer: DispatchSourceTimer?

    public init(folder: URL, settle: TimeInterval, processor: Processor) {
        self.folder = folder.standardizedFileURL
        self.settle = settle
        self.processor = processor
    }

    public func start() {
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            watcher.noticed(Array(list.prefix(count)))
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        stream = FSEventStreamCreate(
            nil, callback, &context, [folder.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 2, flags
        )
        guard let stream else {
            log("cannot watch \(folder.path)")
            exit(1)
        }
        FSEventStreamSetDispatchQueue(stream, stateQueue)
        FSEventStreamStart(stream)

        let timer = DispatchSource.makeTimerSource(queue: stateQueue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
        log("watching \(folder.path)")

        // A protected folder (iCloud Drive, Documents) sends no events until the command may read it;
        // reading it once now raises the permission prompt and says in the log whether it is allowed
        workQueue.async { [self] in
            do {
                _ = try FileManager.default.contentsOfDirectory(atPath: folder.path)
                log("can read \(folder.path)")
            } catch {
                log("cannot read \(folder.path): \(error.localizedDescription). Allow this command to read it in System Settings > Privacy & Security")
            }
        }
    }

    private func noticed(_ paths: [String]) {
        for path in paths {
            let url = URL(fileURLWithPath: path)
            guard PDFFinder.isPDF(url) else { continue }
            let relative = path.hasPrefix(folder.path) ? String(path.dropFirst(folder.path.count)) : path
            // Hidden folders hold build caches and git data
            guard !relative.split(separator: "/").contains(where: { $0.hasPrefix(".") }) else { continue }
            pending[path] = Date()
        }
    }

    private func tick() {
        guard !working else { return }
        let now = Date()
        let ready = pending.filter { path, noticed in
            guard now.timeIntervalSince(noticed) >= settle else { return false }
            let modified = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
            return modified.map { now.timeIntervalSince($0) >= settle } ?? true
        }.map(\.key).sorted()
        guard !ready.isEmpty else { return }
        for path in ready { pending[path] = nil }
        working = true
        // Opening a file can block on a permission prompt, so it happens away from the event queue
        workQueue.async { [self] in
            for path in ready where FileManager.default.fileExists(atPath: path) {
                switch processor.process(URL(fileURLWithPath: path), root: folder) {
                case .skipped: break
                case .updated(let summary): log("done\t\(path)\t\(summary)")
                case .failed(let reason): log("fail\t\(path)\t\(reason)")
                }
            }
            stateQueue.async { self.working = false }
        }
    }

    private func log(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        print("\(stamp)\t\(message)")
        fflush(stdout)
    }
}
