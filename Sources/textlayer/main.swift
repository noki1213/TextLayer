import Foundation
import PDFTextLayer

let usage = """
    Usage:
      textlayer check <file-or-folder>...      Show what each PDF needs, without changing anything
      textlayer apply [options] <file-or-folder>...
                                               Add a text layer to PDFs that need one
      textlayer restore <file>...              Put files back as they were before apply
      textlayer watch [options] <folder>       Keep watching a folder and apply to new or changed PDFs

    Options for apply and watch:
      --backup-dir <dir>   Where copies of the originals go
                           (default: ~/Library/Application Support/TextLayer/Originals)
      --no-backup          Keep no copies
      --output-dir <dir>   Write updated copies here and leave the originals alone (apply only)
      --jobs <n>           Pages read at once (default: CPU cores - 2)
      --settle <seconds>   How long a file has to stay unchanged before watch reads it (default: 30)

    """

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

var arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    print(usage, terminator: "")
    exit(0)
}
arguments.removeFirst()

var options = ProcessOptions()
options.backupDirectory = ProcessOptions.defaultBackupDirectory
var settle: TimeInterval = 30
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
    case "--backup-dir": options.backupDirectory = URL(fileURLWithPath: (value() as NSString).expandingTildeInPath)
    case "--no-backup": options.backupDirectory = nil
    case "--output-dir": options.outputDirectory = URL(fileURLWithPath: (value() as NSString).expandingTildeInPath)
    case "--jobs":
        guard let jobs = Int(value()), jobs > 0 else { fail("--jobs needs a positive number") }
        options.jobs = jobs
    case "--settle":
        guard let seconds = TimeInterval(value()), seconds >= 0 else { fail("--settle needs a number of seconds") }
        settle = seconds
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
    let directory = options.backupDirectory ?? ProcessOptions.defaultBackupDirectory
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
    guard paths.count == 1 else { fail(usage) }
    options.outputDirectory = nil
    let folder = URL(fileURLWithPath: (paths[0] as NSString).expandingTildeInPath)
    let watcher = FolderWatcher(folder: folder, settle: settle, processor: Processor(options: options))
    watcher.start()
    dispatchMain()

default:
    fail("Unknown command \(command)\n\n" + usage)
}
