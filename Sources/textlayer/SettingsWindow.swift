import AppKit
import PDFTextLayer
import SwiftUI
import UniformTypeIdentifiers

typealias TextLayerSettings = PDFTextLayer.Settings

/// `textlayer settings`: an ordinary window with the sections on the left and their settings on the
/// right. Every change is written to the settings file at once; Esc or the close button quits.
enum SettingsWindow {
    static func run(file: SettingsFile) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.mainMenu = editMenu()
        let model = SettingsModel(file: file)
        let window = makeWindow(size: NSSize(width: 640, height: 420))
        window.contentView = NSHostingView(rootView: SettingsView(model: model))
        placeOnMouseScreen(window)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            app.terminate(nil)
        }

        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let editing = window.firstResponder is NSTextView
            switch event.keyCode {
            case 53: // Esc
                if editing {
                    window.makeFirstResponder(nil)
                } else {
                    app.terminate(nil)
                }
                return nil
            case 126 where !editing: // ↑
                model.move(by: -1)
                return nil
            case 125 where !editing: // ↓
                model.move(by: 1)
                return nil
            default:
                return event
            }
        }

        app.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        app.run()
        exit(0)
    }

    /// A titled window tinted 70% black with no blur, so it reads the same in every focus state and
    /// window managers treat it like any other window.
    private static func makeWindow(size: NSSize) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "TextLayer Settings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = NSColor(calibratedWhite: 0, alpha: 0.7)
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        return window
    }

    private static func placeOnMouseScreen(_ window: NSWindow) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        window.setFrameOrigin(NSPoint(x: visible.midX - window.frame.width / 2, y: visible.midY - window.frame.height / 2))
    }

    /// Hidden from view in an app without a menu bar, but it gives the text fields copy, paste
    /// and undo, and ⌘W and ⌘Q close the window
    private static func editMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Close", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "w")
        appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        return main
    }
}

// MARK: - Model

final class SettingsModel: ObservableObject {
    enum Section: String, CaseIterable, Identifiable {
        case watching = "Watching"
        case backups = "Backups"
        case reading = "Reading"

        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .watching: return "eye"
            case .backups: return "clock.arrow.circlepath"
            case .reading: return "text.viewfinder"
            }
        }
    }

    @Published var section: Section = .watching
    @Published private(set) var settings: TextLayerSettings
    /// Why the file couldn't be read or written; nil when all is well
    @Published private(set) var problem: String?

    let file: SettingsFile
    private var stamp: SettingsFile.Stamp?
    private var timer: Timer?

    init(file: SettingsFile) {
        self.file = file
        let reading = file.read()
        settings = reading.settings
        problem = reading.problem
        stamp = file.stamp()
        // Edits made to the file in an editor while the window is open show up here too
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.reloadIfEdited() }
    }

    var filePath: String { (file.path.path as NSString).abbreviatingWithTildeInPath }

    func move(by step: Int) {
        let all = Section.allCases
        guard let index = all.firstIndex(of: section) else { return }
        let next = all[max(0, min(all.count - 1, index + step))]
        withAnimation(Motion.select) { section = next }
    }

    func set<Value: Equatable>(_ keyPath: WritableKeyPath<TextLayerSettings, Value>, _ value: Value, key: TextLayerSettings.Key, json: Any) {
        guard settings[keyPath: keyPath] != value else { return }
        if let error = file.write(json, for: key) {
            problem = error
            return
        }
        settings[keyPath: keyPath] = value
        stamp = file.stamp()
        problem = file.read().problem
    }

    private func reloadIfEdited() {
        let now = file.stamp()
        guard now != stamp else { return }
        stamp = now
        let reading = file.read()
        settings = reading.settings
        problem = reading.problem
    }
}

// MARK: - Look

enum Palette {
    static let black = Color(red: 0x26 / 255, green: 0x24 / 255, blue: 0x27 / 255)
    static let green = Color(red: 0x33 / 255, green: 0xA5 / 255, blue: 0xA5 / 255)
    static let red = Color(red: 0xFC / 255, green: 0x9C / 255, blue: 0x9C / 255)
    static let white = Color(red: 0xC4 / 255, green: 0xC4 / 255, blue: 0xC4 / 255)
    static let brightWhite = Color(red: 0xFC / 255, green: 0xFC / 255, blue: 0xFA / 255)
    static let faint = Color(red: 0xC4 / 255, green: 0xC4 / 255, blue: 0xC4 / 255).opacity(0.7)
}

enum Motion {
    static let select = Animation.spring(response: 0.28, dampingFraction: 1)
}

// MARK: - Views

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @Namespace private var highlight

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1).padding(.vertical, 18)
            VStack(alignment: .leading, spacing: 0) {
                content
                    .id(model.section)
                    .transition(.opacity)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                footer
            }
            .padding(24)
        }
        .frame(width: 640, height: 420)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("TextLayer")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.faint)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            ForEach(SettingsModel.Section.allCases) { section in
                let selected = model.section == section
                HStack(spacing: 10) {
                    Image(systemName: section.symbol).frame(width: 18)
                    Text(section.rawValue)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 14))
                .foregroundStyle(selected ? Palette.brightWhite : Palette.white)
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Palette.green.opacity(0.30))
                            .matchedGeometryEffect(id: "section", in: highlight)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    NSApp.keyWindow?.makeFirstResponder(nil)
                    withAnimation(Motion.select) { model.section = section }
                }
            }
            Spacer()
        }
        .padding(.top, 22)
        .padding(.horizontal, 12)
        .frame(width: 180)
    }

    @ViewBuilder
    private var content: some View {
        switch model.section {
        case .watching: WatchingSection(model: model)
        case .backups: BackupsSection(model: model)
        case .reading: ReadingSection(model: model)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let problem = model.problem {
                Text(problem).foregroundStyle(Palette.red)
            }
            Text("Saved to \(model.filePath). A running textlayer watch picks changes up.")
                .foregroundStyle(Palette.faint)
        }
        .font(.system(size: 12))
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct SectionTitle: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(Palette.brightWhite)
            .padding(.bottom, 18)
    }
}

/// A label, its control, and a line on what it does
struct SettingRow<Control: View>: View {
    let label: String
    let note: String
    @ViewBuilder let control: Control

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 14)).foregroundStyle(Palette.brightWhite)
            control
            Text(note)
                .font(.system(size: 12))
                .foregroundStyle(Palette.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 20)
    }
}

/// A folder path typed in or dropped from Finder. Saved on ⏎ or when the field loses focus.
struct FolderField: View {
    let value: String
    let placeholder: String
    let commit: (String) -> Void
    @State private var text = ""
    @State private var dropping = false
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text, prompt: Text(placeholder).foregroundColor(Palette.faint.opacity(0.6)))
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .foregroundStyle(Palette.brightWhite)
            .focused($focused)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.white.opacity(dropping ? 0.14 : 0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(focused || dropping ? Palette.green : Color.white.opacity(0.12), lineWidth: 1)
            )
            .onAppear { text = value }
            .onChange(of: value) { newValue in if !focused { text = newValue } }
            .onChange(of: focused) { isFocused in if !isFocused { commit(text) } }
            .onSubmit { commit(text) }
            .onDrop(of: [UTType.fileURL], isTargeted: $dropping) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    var isDirectory: ObjCBool = false
                    FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                    let folder = isDirectory.boolValue ? url : url.deletingLastPathComponent()
                    let path = (folder.path as NSString).abbreviatingWithTildeInPath
                    DispatchQueue.main.async {
                        text = path
                        commit(path)
                    }
                }
                return true
            }
    }
}

/// − value + as text, for whole numbers in a range
struct NumberStepper: View {
    let value: Int
    let range: ClosedRange<Int>
    let step: Int
    let label: (Int) -> String
    let change: (Int) -> Void

    var body: some View {
        HStack(spacing: 14) {
            button("−", to: value - step)
            Text(label(value))
                .font(.system(size: 14).monospacedDigit())
                .foregroundStyle(Palette.brightWhite)
                .frame(minWidth: 90)
            button("+", to: value + step)
        }
    }

    private func button(_ title: String, to target: Int) -> some View {
        let next = min(range.upperBound, max(range.lowerBound, target))
        let enabled = next != value
        return Text(title)
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(enabled ? Palette.green : Palette.faint.opacity(0.4))
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
            .onTapGesture { if enabled { change(next) } }
    }
}

struct WatchingSection: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(title: "Watching")
            SettingRow(
                label: "Folder",
                note: "Watched by textlayer watch when it is started without a folder. Type a path or drop a folder here."
            ) {
                FolderField(value: model.settings.watchFolder, placeholder: "~/Documents/Papers") { path in
                    let trimmed = path.trimmingCharacters(in: .whitespaces)
                    model.set(\.watchFolder, trimmed, key: .watchFolder, json: trimmed)
                }
            }
            SettingRow(
                label: "Wait before reading",
                note: "How long a new or changed PDF has to stay unchanged before it is read, so files still being written or synced are left alone."
            ) {
                NumberStepper(
                    value: Int(model.settings.settleSeconds.rounded()),
                    range: 0...600,
                    step: 5,
                    label: { "\($0) s" },
                    change: { model.set(\.settleSeconds, Double($0), key: .settleSeconds, json: $0) }
                )
            }
        }
    }
}

struct BackupsSection: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(title: "Backups")
            SettingRow(
                label: "Keep a copy of each original",
                note: "Copies let textlayer restore put back files that were changed again after the text layer was added."
            ) {
                Toggle("", isOn: Binding(
                    get: { model.settings.keepBackups },
                    set: { model.set(\.keepBackups, $0, key: .keepBackups, json: $0) }
                ))
                .toggleStyle(.switch)
                .tint(Palette.green)
                .labelsHidden()
            }
            SettingRow(
                label: "Backup folder",
                note: "Copies and the log of changed files go here, under each file's path in your home folder."
            ) {
                FolderField(value: model.settings.backupFolder, placeholder: TextLayerSettings().backupFolder) { path in
                    let trimmed = path.trimmingCharacters(in: .whitespaces)
                    let folder = trimmed.isEmpty ? TextLayerSettings().backupFolder : trimmed
                    model.set(\.backupFolder, folder, key: .backupFolder, json: folder)
                }
            }
            .opacity(model.settings.keepBackups ? 1 : 0.45)
        }
    }
}

struct ReadingSection: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(title: "Reading")
            SettingRow(
                label: "Pages read at once",
                note: "More is faster and keeps more of the Mac busy. Auto leaves two cores free."
            ) {
                NumberStepper(
                    value: model.settings.jobs,
                    range: 0...ProcessInfo.processInfo.activeProcessorCount,
                    step: 1,
                    label: { $0 == 0 ? "Auto (\(TextLayerSettings.automaticJobs))" : "\($0)" },
                    change: { model.set(\.jobs, $0, key: .jobs, json: $0) }
                )
            }
        }
    }
}
