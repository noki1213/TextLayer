import Foundation

/// Deletes copies of originals once they are older than the kept number of days. Their lines in
/// log.tsv stay with the copy's path emptied, so restore can still cut an untouched file back to its
/// original length. Age comes from the time logged when the copy was made: a copy keeps the original's
/// modification date, which says nothing about when it was taken. Only files inside the backup
/// folder are ever deleted.
public enum BackupPruner {
    public struct Result: Equatable {
        public var deleted = 0
        public var bytes: Int64 = 0
    }

    public static func prune(in directory: URL, keepDays: Int, now: Date = Date()) -> Result {
        var result = Result()
        guard keepDays > 0 else { return result }
        let logURL = directory.appendingPathComponent("log.tsv")
        guard let data = try? Data(contentsOf: logURL), let text = String(data: data, encoding: .utf8) else {
            return result
        }
        let root = directory.standardizedFileURL.path
        let cutoff = now.addingTimeInterval(-Double(keepDays) * 86400)
        let parser = ISO8601DateFormatter()
        let fileManager = FileManager.default
        var kept: [String] = []
        var emptied = Set<URL>()
        var changed = false

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 6, let made = parser.date(from: String(fields[0])), made < cutoff,
                  !fields[4].isEmpty
            else {
                kept.append(String(line))
                continue
            }
            let backup = URL(fileURLWithPath: String(fields[4])).standardizedFileURL
            let source = URL(fileURLWithPath: String(fields[1])).standardizedFileURL
            guard backup.path.hasPrefix(root + "/"), backup.path != source.path, backup.path != logURL.path else {
                kept.append(String(line))
                continue
            }
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: backup.path, isDirectory: &isDirectory) {
                guard !isDirectory.boolValue else {
                    kept.append(String(line))
                    continue
                }
                let size = ((try? fileManager.attributesOfItem(atPath: backup.path))?[.size] as? Int64) ?? 0
                do {
                    try fileManager.removeItem(at: backup)
                } catch {
                    kept.append(String(line))
                    continue
                }
                result.deleted += 1
                result.bytes += size
            }
            emptied.insert(backup.deletingLastPathComponent())
            var cleared = fields
            cleared[4] = ""
            kept.append(cleared.joined(separator: "\t"))
            changed = true
        }
        guard changed else { return result }

        // Lines logged while the copies were being deleted are kept as they were written
        let current = (try? Data(contentsOf: logURL)) ?? data
        var rewritten = Data(kept.joined(separator: "\n").utf8)
        if current.count > data.count, current.prefix(data.count) == data {
            rewritten.append(current.suffix(from: data.count))
        }
        try? rewritten.write(to: logURL, options: .atomic)

        for folder in emptied { removeEmptyFolders(from: folder, below: root) }
        return result
    }

    /// Removes the folder and then each parent that is left empty, stopping at the backup folder
    private static func removeEmptyFolders(from folder: URL, below root: String) {
        let fileManager = FileManager.default
        var current = folder.standardizedFileURL
        while current.path.hasPrefix(root + "/") {
            guard let items = try? fileManager.contentsOfDirectory(atPath: current.path) else { return }
            let leftovers = items.filter { $0 != ".DS_Store" }
            guard leftovers.isEmpty else { return }
            for item in items { try? fileManager.removeItem(at: current.appendingPathComponent(item)) }
            guard (try? fileManager.removeItem(at: current)) != nil else { return }
            current = current.deletingLastPathComponent()
        }
    }
}
