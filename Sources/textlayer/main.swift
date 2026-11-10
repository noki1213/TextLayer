import Foundation
import PDFTextLayer

let usage = """
    Usage:
      textlayer check <file-or-folder>...      Show what each PDF needs, without changing anything
      textlayer apply [options] <file-or-folder>...
                                               Add a text layer to PDFs that need one
      textlayer restore <file>...              Put files back as they were before apply
      textlayer watch [options] [<folder>]     Keep watching a folder and apply to new or changed PDFs
                                               (default: watchFolder in the settings file)
      textlayer settings                       Open the settings window

    Options for apply and watch:
      --backup-dir <dir>   Where copies of the originals go
                           (default: ~/Library/Application Support/TextLayer/Originals)
      --no-backup          Keep no copies
      --output-dir <dir>   Write updated copies here and leave the originals alone (apply only)
      --jobs <n>           Pages read at once (default: CPU cores - 2)
      --settle <seconds>   How long a file has to stay unchanged before watch reads it (default: 30)

    Settings: \(SettingsFile.defaultPath)
    Options given on the command line win over the settings file. watch reads the file again
    whenever it changes.

    """

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

var arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first, !["-h", "--help", "help"].contains(command) else {
    print(usage, terminator: "")
    exit(0)
}
arguments.removeFirst()

/// Options given on the command line; nil for those left to the settings file
struct Overrides {
    var backupDirectory: URL??
    var outputDirectory: URL?
    var jobs: Int?
    var settle: TimeInterval?

    func options(from settings: Settings) -> ProcessOptions {
        var options = ProcessOptions()
        options.backupDirectory = backupDirectory ?? (settings.keepBackups ? settings.backupFolderURL : nil)
        options.outputDirectory = outputDirectory
        options.jobs = jobs ?? settings.effectiveJobs
        return options
    }

    func settle(from settings: Settings) -> TimeInterval { settle ?? settings.settleSeconds }
}

func readSettings(_ file: SettingsFile) -> Settings {
    let reading = file.read()
    if let problem = reading.problem { FileHandle.standardError.write(Data((problem + "\n").utf8)) }
    return reading.settings
}

let settingsFile = SettingsFile()
var overrides = Overrides()
var paths: [String] = []
var index = 0
while index < arguments.count {
    let argument = arguments[index]
    func value() -> String {
        index += 1
        guard index < arguments.count else { fail("\(argument) needs a value") }
        return arguments[index]
    }
    switch argument {
    case "--backup-dir": overrides.backupDirectory = URL(fileURLWithPath: (value() as NSString).expandingTildeInPath)
    case "--no-backup": overrides.backupDirectory = .some(nil)
    case "--output-dir": overrides.outputDirectory = URL(fileURLWithPath: (value() as NSString).expandingTildeInPath)
    case "--jobs":
        guard let jobs = Int(value()), jobs > 0 else { fail("--jobs needs a positive number") }
        overrides.jobs = jobs
    case "--settle":
        guard let seconds = TimeInterval(value()), seconds >= 0 else { fail("--settle needs a number of seconds") }
        overrides.settle = seconds
    case "-h", "--help":
        print(usage, terminator: "")
        exit(0)
    default:
        if argument.hasPrefix("--") { fail("Unknown option \(argument)\n\n" + usage) }
        paths.append(argument)
    }
    index += 1
}

switch command {
case "check", "apply":
    guard !paths.isEmpty else { fail(usage) }
    var options = overrides.options(from: readSettings(settingsFile))
    options.dryRun = command == "check"
    let processor = Processor(options: options)
    let files = PDFFinder.files(in: paths.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) })
    var failures = 0
    let printLock = NSLock()
    let fileQueue = OperationQueue()
    fileQueue.maxConcurrentOperationCount = min(options.jobs, 3)
    for (url, root) in files {
        fileQueue.addOperation {
            let outcome = processor.process(url, root: root)
            printLock.lock()
            defer { printLock.unlock() }
            switch outcome {
            case .skipped(let reason): print("skip\t\(url.path)\t\(reason)")
            case .updated(let summary): print("\(options.dryRun ? "needs" : "done")\t\(url.path)\t\(summary)")
            case .failed(let reason):
                failures += 1
                print("fail\t\(url.path)\t\(reason)")
            }
            fflush(stdout)
        }
    }
    fileQueue.waitUntilAllOperationsAreFinished()
    exit(failures == 0 ? 0 : 1)

case "restore":
    guard !paths.isEmpty else { fail(usage) }
    let settings = readSettings(settingsFile)
    let directory = (overrides.backupDirectory ?? nil) ?? settings.backupFolderURL
    var failures = 0
    for path in paths {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        do {
            print("restored\t\(url.path)\t\(try Restorer.restore(url, backupDirectory: directory))")
        } catch {
            failures += 1
            print("fail\t\(url.path)\t\(error)")
        }
    }
    exit(failures == 0 ? 0 : 1)

case "watch":
    guard paths.count <= 1 else { fail(usage) }
    overrides.outputDirectory = nil
    let givenFolder = paths.first.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
    var settings = readSettings(settingsFile)
    var stamp = settingsFile.stamp()
    var watcher: FolderWatcher?

    func watch(_ settings: Settings) {
        let folder = (givenFolder ?? settings.watchFolderURL)?.standardizedFileURL
        let processor = Processor(options: overrides.options(from: settings))
        let settle = overrides.settle(from: settings)
        if let watcher, watcher.folder == folder {
            watcher.update(settle: settle, processor: processor)
            return
        }
        watcher?.stop()
        watcher = nil
        guard let folder else {
            log("no folder to watch: give one, or set watchFolder in \(settingsFile.path.path)")
            return
        }
        let next = FolderWatcher(folder: folder, settle: settle, processor: processor)
        next.start()
        watcher = next
    }

    func log(_ message: String) {
        print("\(ISO8601DateFormatter().string(from: Date()))\t\(message)")
        fflush(stdout)
    }

    watch(settings)
    let settingsTimer = DispatchSource.makeTimerSource(queue: .main)
    settingsTimer.schedule(deadline: .now() + 2, repeating: 2)
    settingsTimer.setEventHandler {
        let now = settingsFile.stamp()
        guard now != stamp else { return }
        stamp = now
        let next = readSettings(settingsFile)
        guard next != settings else { return }
        settings = next
        log("settings changed")
        watch(settings)
    }
    settingsTimer.resume()
    dispatchMain()

case "settings":
    SettingsWindow.run(file: settingsFile)

default:
    fail("Unknown command \(command)\n\n" + usage)
}
