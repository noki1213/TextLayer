import Foundation

/// What the settings file holds. Command-line options win over it for the run they are given to.
public struct Settings: Equatable {
    /// Folder `watch` watches when it is started without one; empty for none
    public var watchFolder = ""
    /// Seconds a file has to stay unchanged before `watch` reads it
    public var settleSeconds: Double = 30
    public var keepBackups = true
    public var backupFolder = "~/Library/Application Support/TextLayer/Originals"
    /// Pages read at once; 0 picks CPU cores - 2
    public var jobs = 0

    public init() {}

    public enum Key: String, CaseIterable {
        case watchFolder, settleSeconds, keepBackups, backupFolder, jobs
    }

    public static var automaticJobs: Int { max(1, ProcessInfo.processInfo.activeProcessorCount - 2) }

    public var watchFolderURL: URL? {
        let path = watchFolder.trimmingCharacters(in: .whitespaces)
        return path.isEmpty ? nil : URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    public var backupFolderURL: URL {
        let path = backupFolder.trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else { return ProcessOptions.defaultBackupDirectory }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }

    public var effectiveJobs: Int { jobs > 0 ? jobs : Self.automaticJobs }

    /// Values from a decoded file. A value of the wrong kind or out of range keeps its default and
    /// is named in `problems`.
    init(object: [String: Any], problems: inout [String]) {
        if let value = object[Key.watchFolder.rawValue] {
            if let string = value as? String { watchFolder = string } else { problems.append(Key.watchFolder.rawValue) }
        }
        if let value = object[Key.settleSeconds.rawValue] {
            if let number = Self.number(value), number.doubleValue >= 0 {
                settleSeconds = number.doubleValue
            } else { problems.append(Key.settleSeconds.rawValue) }
        }
        if let value = object[Key.keepBackups.rawValue] {
            if let flag = value as? NSNumber, Self.isBool(flag) { keepBackups = flag.boolValue } else { problems.append(Key.keepBackups.rawValue) }
        }
        if let value = object[Key.backupFolder.rawValue] {
            if let string = value as? String { backupFolder = string } else { problems.append(Key.backupFolder.rawValue) }
        }
        if let value = object[Key.jobs.rawValue] {
            if let number = Self.number(value), number.intValue >= 0, Double(number.intValue) == number.doubleValue {
                jobs = number.intValue
            } else { problems.append(Key.jobs.rawValue) }
        }
    }

    // JSON true and false decode as NSNumber too, and bridge to and from 1 and 0
    private static func isBool(_ number: NSNumber) -> Bool { CFGetTypeID(number) == CFBooleanGetTypeID() }

    private static func number(_ value: Any) -> NSNumber? {
        guard let number = value as? NSNumber, !isBool(number) else { return nil }
        return number
    }
}

/// The settings file, by default ~/.config/textlayer/settings.json. When it is a link, the link's
/// destination is read and written, so the link stays in place.
public final class SettingsFile {
    public static let defaultPath = "~/.config/textlayer/settings.json"

    /// The path as given, which may be a link
    public let path: URL

    public init(path: URL = URL(fileURLWithPath: (SettingsFile.defaultPath as NSString).expandingTildeInPath)) {
        self.path = path
    }

    /// The file actually read and written, resolved on every use so a link pointed elsewhere is followed
    public var resolvedURL: URL { path.resolvingSymlinksInPath() }

    public struct Reading {
        public var settings: Settings
        /// Why the file, or some of its values, could not be used; nil when all is well
        public var problem: String?
    }

    /// The settings in the file; defaults when there is no file yet
    public func read() -> Reading {
        let url = resolvedURL
        guard FileManager.default.fileExists(atPath: url.path) else { return Reading(settings: Settings()) }
        guard let object = Self.object(at: url) else {
            return Reading(settings: Settings(), problem: "\(path.path) can't be read as JSON; using the defaults")
        }
        var problems: [String] = []
        let settings = Settings(object: object, problems: &problems)
        let problem = problems.isEmpty ? nil : "\(path.path): \(problems.joined(separator: ", ")) not understood; using the default"
        return Reading(settings: settings, problem: problem)
    }

    /// Writes one value and leaves every other key in the file as it was. A file that exists but
    /// can't be read is left alone. Returns why it couldn't be saved, or nil once it is.
    @discardableResult
    public func write(_ value: Any, for key: Settings.Key) -> String? {
        let url = resolvedURL
        var object: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: url.path) {
            guard let existing = Self.object(at: url) else {
                return "\(path.path) can't be read as JSON. Fix the file to change settings here."
            }
            object = existing
        }
        object[key.rawValue] = value
        do {
            var data = try JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            data.append(0x0A)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            return "Couldn't save \(path.path): \(error.localizedDescription)"
        }
        return nil
    }

    /// The destination's path, modification date and size, to notice edits; nil when there is no file
    public func stamp() -> Stamp? { Stamp(of: resolvedURL) }

    public struct Stamp: Equatable {
        let path: String
        let modified: Date
        let size: Int

        init?(of url: URL) {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let modified = attributes[.modificationDate] as? Date
            else { return nil }
            path = url.path
            self.modified = modified
            size = (attributes[.size] as? Int) ?? 0
        }
    }

    private static func object(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
