// SettingsView.swift: the settings window, shown when you launch Phaedrus.app yourself.

import AppKit
import AVFoundation
import Speech
import SwiftUI

// MARK: - 🎤 key + service shortcut

enum Shortcut {
    /// Key of this service in the `pbs` NSServicesStatus dictionary: "<bundle id> - <menu item> - <message>".
    static let serviceKey = "\(Bundle.main.bundleIdentifier ?? "io.github.venzellucas.phaedrus") - Dictate with Phaedrus - dictate"
    static let f18 = "\u{F715}"

    /// Is the 🎤 → F18 remap active right now?
    static var micKeyRemapped: Bool {
        let out = run("/usr/bin/hidutil", ["property", "--get", "UserKeyMapping"]).output
        // 0xC000000CF (🎤) = 51539607759, 0x70000006D (F18) = 30064771181
        return out.contains("51539607759") && out.contains("30064771181")
    }

    /// Turns the remap (and its login item) on/off via the bundled mic-key.sh,
    /// and binds the service to F18 when turning it on.
    static func setMicKey(_ on: Bool) -> String? {
        guard let script = Bundle.main.path(forResource: "mic-key", ofType: "sh") else { return "mic-key.sh missing from the app" }
        let r = run("/bin/zsh", [script, on ? "on" : "off"])
        if on { setServiceShortcut(f18) }
        if r.status != 0 || micKeyRemapped != on {
            return "Could not change the 🎤 key: \(r.output.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
        return nil
    }

    static var serviceShortcut: String? {
        let pbs = UserDefaults(suiteName: "pbs")?.dictionary(forKey: "NSServicesStatus")
        return (pbs?[serviceKey] as? [String: Any])?["key_equivalent"] as? String
    }

    static func setServiceShortcut(_ key: String) {
        guard let pbs = UserDefaults(suiteName: "pbs") else { return }
        var all = pbs.dictionary(forKey: "NSServicesStatus") ?? [:]
        var mine = all[serviceKey] as? [String: Any] ?? [:]
        mine["key_equivalent"] = key
        mine["enabled_services_menu"] = true
        mine["enabled_context_menu"] = true
        all[serviceKey] = mine
        pbs.set(all, forKey: "NSServicesStatus")
        pbs.synchronize()
        _ = run("/System/Library/CoreServices/pbs", ["-update"])
    }

    /// "⌃⌥D", "F18 (🎤 key)", …
    static func describe(_ key: String?) -> String {
        guard let key, !key.isEmpty else { return "Not set" }
        var mods = "", rest = ""
        for ch in key {
            switch ch {
            case "@": mods += "⌘"
            case "^": mods += "⌃"
            case "~": mods += "⌥"
            case "$": mods += "⇧"
            default: rest.append(ch)
            }
        }
        if let u = rest.unicodeScalars.first, (0xF704...0xF726).contains(u.value) {
            let n = Int(u.value) - 0xF703
            return mods + "F\(n)" + (n == 18 && mods.isEmpty ? " (🎤 key)" : "")
        }
        return mods + rest.uppercased()
    }

    /// Runs a command and returns its exit status and combined output.
    @discardableResult
    static func run(_ path: String, _ args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()   // read before waiting: a full pipe would block the child
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}

// MARK: - Model

@MainActor
final class PausedDictationControls: ObservableObject {
    enum Action { case resume, finish, cancel }
    @Published var isPaused = false
    @Published var hasText = false
    @Published var message: String?
    @Published var deadlineWarning: String?
    var action: Action?
}

@MainActor
final class SettingsModel: ObservableObject {
    private let d = Prefs.d
    private let cleanupAvailabilityCheck: ([String]) -> String?

    @Published var supported: [Locale] = []
    @Published var loadingLanguages = true
    @Published var installed: Set<String> = []
    @Published var selected: [String] {
        didSet { d.set(selected, forKey: "locales"); refreshCleanupAvailability() }
    }
    @Published var silence: Double { didSet { d.set(silence, forKey: "silenceSeconds") } }
    @Published var noSpeech: Double { didSet { d.set(noSpeech, forKey: "noSpeechSeconds") } }
    @Published var maxMinutes: Double { didSet { d.set(maxMinutes * 60, forKey: "maxSeconds") } }
    @Published var copyToClipboard: Bool { didSet { d.set(copyToClipboard, forKey: "copyToClipboard") } }
    @Published var playSounds: Bool { didSet { d.set(playSounds, forKey: "playSounds") } }
    @Published var mixLanguages: Bool { didSet { d.set(mixLanguages, forKey: "mixLanguages") } }
    @Published var smartCleanup: Bool { didSet { d.set(smartCleanup, forKey: "smartCleanup") } }
    @Published var cleanupStyle: CleanupStyle { didSet { d.set(cleanupStyle.rawValue, forKey: "cleanupStyle") } }
    @Published var cleanupUnavailable: String? = "Checking Apple Intelligence…"
    @Published var showingCleanupAvailability = false

    @Published var micKey = false
    @Published var shortcut = "…"
    @Published var micAuth = AVCaptureDevice.authorizationStatus(for: .audio)
    @Published var message: String?
    private var refreshID = UUID()

    init(cleanupAvailabilityCheck: @escaping ([String]) -> String? = SmartCleanup.unavailableReason) {
        self.cleanupAvailabilityCheck = cleanupAvailabilityCheck
        selected = Prefs.locales
        silence = Prefs.silence
        noSpeech = Prefs.noSpeech
        maxMinutes = (Prefs.maxSeconds / 60).rounded()
        copyToClipboard = Prefs.copyToClipboard
        playSounds = Prefs.playSounds
        mixLanguages = Prefs.mixLanguages
        smartCleanup = Prefs.smartCleanup
        cleanupStyle = Prefs.cleanupStyle
    }

    func refresh() {
        micKey = Shortcut.micKeyRemapped
        shortcut = Shortcut.describe(Shortcut.serviceShortcut)
        micAuth = AVCaptureDevice.authorizationStatus(for: .audio)
        refreshCleanupAvailability()
        refreshID = UUID()
        loadingLanguages = true
        let id = refreshID
        // Settings may be opened inside a Service's nested event loop, where
        // main-queue Swift tasks cannot resume. Deliver through the run loop.
        Task.detached { [weak self] in
            let names = Locale.current
            let supported = await SpeechTranscriber.supportedLocales.sorted {
                (names.localizedString(forIdentifier: $0.identifier) ?? $0.identifier)
                    < (names.localizedString(forIdentifier: $1.identifier) ?? $1.identifier)
            }
            let installed = Set(await SpeechTranscriber.installedLocales.map(\.identifier))
            onMainRunLoop { [weak self] in
                guard let self, self.refreshID == id else { return }
                self.supported = supported
                self.installed = installed
                self.loadingLanguages = false
            }
        }
    }

    func refreshCleanupAvailability() {
        cleanupUnavailable = cleanupAvailabilityCheck(selected)
    }

    /// A manual check must acknowledge the click even when the status is unchanged.
    /// Automatic refreshes update the inline status without interrupting the user.
    func checkCleanupAvailability() {
        refreshCleanupAvailability()
        showingCleanupAvailability = true
    }

    func name(_ l: Locale) -> String { Locale.current.localizedString(forIdentifier: l.identifier) ?? l.identifier }

    func isOn(_ l: Locale) -> Bool { selected.contains(l.identifier) }

    func set(_ l: Locale, _ on: Bool) {
        if on, !selected.contains(l.identifier), selected.count < Prefs.maxLanguages { selected.append(l.identifier) }
        if !on, selected.count > 1 { selected.removeAll { $0 == l.identifier } }
    }

    func setMicKey(_ on: Bool) {
        message = Shortcut.setMicKey(on)
        micKey = Shortcut.micKeyRemapped
        shortcut = Shortcut.describe(Shortcut.serviceShortcut)
    }

    func requestMic() {
        Task.detached { [weak self] in
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            let status = AVCaptureDevice.authorizationStatus(for: .audio)
            onMainRunLoop { [weak self] in self?.micAuth = status }
        }
    }
}

// MARK: - View

struct SettingsView: View {
    @ObservedObject var m: SettingsModel
    @ObservedObject var pausedDictation: PausedDictationControls

    private var shortcutSection: some View {
        Section {
            Toggle("Use the 🎤 key to dictate", isOn: Binding(get: { m.micKey }, set: { m.setMicKey($0) }))
            LabeledContent("Shortcut", value: m.shortcut)
            LabeledContent("Settings while dictating", value: "⌘,")
            Button("Change shortcut in System Settings…") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
            }
            if let msg = m.message { Text(msg).font(.caption).foregroundStyle(.red) }
        } header: { Text("Shortcut") } footer: {
            Text("The 🎤 key is remapped to F18. In Keyboard Shortcuts → Services, you can assign shortcuts to “Dictate with Phaedrus” and “Phaedrus Settings”. The settings shortcut can also launch the app.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var micStatus: String {
        switch m.micAuth {
        case .authorized: "Allowed"
        case .denied, .restricted: "Denied"
        default: "Not asked yet"
        }
    }

    var body: some View {
        Form {
            if pausedDictation.isPaused {
                Section {
                    Label("Dictation paused", systemImage: "pause.circle.fill").font(.headline)
                    Text("The microphone is off. Change your languages, then resume. Your earlier words will be kept.")
                        .font(.callout).foregroundStyle(.secondary)
                    if let message = pausedDictation.message {
                        Text(message).font(.caption).foregroundStyle(.red)
                    }
                    HStack {
                        Button("Resume dictation") { pausedDictation.action = .resume }
                            .keyboardShortcut(.defaultAction)
                        Button("Finish and insert") { pausedDictation.action = .finish }
                            .keyboardShortcut(.return, modifiers: .command)
                            .disabled(!pausedDictation.hasText)
                        Button("Cancel dictation") { pausedDictation.action = .cancel }
                            .keyboardShortcut(.cancelAction)
                    }
                    Text("Return or close this window to resume. Esc cancels the entire dictation.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let warning = pausedDictation.deadlineWarning {
                        Text(warning).font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            if !pausedDictation.isPaused {
                Section {
                    HStack(spacing: 14) {
                        Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Phaedrus").font(.title2.bold())
                            Text("Press the shortcut, speak, and the text appears at your cursor. Transcription runs on this Mac.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if !pausedDictation.isPaused { shortcutSection }

            Section {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        if m.loadingLanguages {
                            Text("Loading languages…").foregroundStyle(.secondary)
                        } else if m.supported.isEmpty {
                            Text("On-device languages are unavailable on this Mac.").foregroundStyle(.secondary)
                        }
                        ForEach(m.supported, id: \.identifier) { l in
                            Toggle(isOn: Binding(get: { m.isOn(l) }, set: { m.set(l, $0) })) {
                                HStack {
                                    Text(m.name(l))
                                    if m.installed.contains(l.identifier) {
                                        Text("downloaded").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .disabled(m.isOn(l) ? m.selected.count == 1 : m.selected.count >= Prefs.maxLanguages)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 170)
                Toggle("Mix languages in one dictation (experimental)", isOn: $m.mixLanguages)
                    .disabled(m.selected.count < 2)
                Text("Keeps words in the language you speak, including switches within a sentence. Select at least two languages. Results can still be wrong; turn this off to use the best single-language transcript.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Languages") } footer: {
                Text("Phaedrus listens in every selected language at once (up to \(Prefs.maxLanguages)). Mixing is optional and runs entirely on this Mac. Each language's model is downloaded from Apple the first time it's used. Every extra language adds work while you speak.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if pausedDictation.isPaused { shortcutSection }

            Section("Stopping") {
                slider("Stop after silence", value: $m.silence, range: 1...8, step: 0.5, unit: "s")
                slider("Give up if nothing is heard", value: $m.noSpeech, range: 5...30, step: 1, unit: "s")
                slider("Longest dictation", value: $m.maxMinutes, range: 1...15, step: 1, unit: "min")
                Text("Stop early with 🎤, Return, or a click on the bubble; Esc cancels. While the bubble is shown, Return and Esc go to Phaedrus, not to other apps.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("The recording ribbon reacts to microphone input. Live transcripts stay hidden so you can focus on speaking.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            SmartCleanupSettings(m: m)

            Section("After dictating") {
                Toggle("Also copy the text to the clipboard", isOn: $m.copyToClipboard)
                Text("Useful in apps that don't accept Services text: just press ⌘V. The copy stays on this Mac (not shared via Universal Clipboard), but clipboard managers can record it.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Play start and stop sounds", isOn: $m.playSounds)
            }

            Section("Permissions") {
                LabeledContent("Microphone", value: micStatus)
                if m.micAuth == .notDetermined {
                    Button("Allow microphone…") { m.requestMic() }
                } else if m.micAuth != .authorized {
                    Button("Open Privacy Settings…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 700)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            m.refreshCleanupAvailability()
        }
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, unit: String) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: range, step: step).frame(width: 160)
                Text(value.wrappedValue.truncatingRemainder(dividingBy: 1) == 0
                     ? "\(Int(value.wrappedValue)) \(unit)" : String(format: "%.1f \(unit)", value.wrappedValue))
                    .monospacedDigit().frame(width: 52, alignment: .trailing)
            }
        }
    }
}

/// Kept together so readiness, setup guidance, and manual-check feedback agree.
struct SmartCleanupSettings: View {
    @ObservedObject var m: SettingsModel

    private func openSystemSettings() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }

    var body: some View {
        Section("Smart cleanup") {
            Toggle("Use on-device Smart cleanup (experimental)", isOn: $m.smartCleanup)
                .disabled(m.cleanupUnavailable != nil && !m.smartCleanup)
            Picker("Review style", selection: $m.cleanupStyle) {
                ForEach(CleanupStyle.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .disabled(!m.smartCleanup)
            Text("Uses Apple Intelligence to choose between recognized words and add missing sentence-ending punctuation. Enable language mixing above to compare languages. Your words stay on this Mac.")
                .font(.caption).foregroundStyle(.secondary)
            Text(m.cleanupStyle == .natural
                 ? "Natural removes accidental repetitions, fillers, and abandoned starts, and adjusts punctuation. Keeps the remaining words in their original language and order. Cuts can still change meaning; review the result."
                 : "Conservative chooses recognized alternatives and adds missing final punctuation. Keeps repetitions and spoken fillers.")
                .font(.caption).foregroundStyle(.secondary)
            Text("May take up to \(Int(m.cleanupStyle.timeoutSeconds)) seconds. If a passage cannot be reviewed, its existing text is kept.")
                .font(.caption).foregroundStyle(.secondary)
            if let reason = m.cleanupUnavailable {
                Label("Setup needed", systemImage: "exclamationmark.circle").font(.callout)
                Text(reason).font(.caption).foregroundStyle(.secondary)
            } else {
                Label(m.smartCleanup ? "Ready · cleanup is enabled" : "Ready · turn on the switch above",
                      systemImage: "checkmark.circle").font(.callout)
            }
            HStack {
                Button("Check availability") { m.checkCleanupAvailability() }
                if m.cleanupUnavailable != nil {
                    Button("Open System Settings…", action: openSystemSettings)
                        .help("Choose Apple Intelligence & Siri in System Settings.")
                }
            }
            Text("Checking availability only checks readiness. Cleanup runs after you finish a dictation.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .alert(m.cleanupUnavailable == nil ? "Smart cleanup is ready" : "Smart cleanup isn't available",
               isPresented: $m.showingCleanupAvailability) {
            if m.cleanupUnavailable != nil {
                Button("Open System Settings…", action: openSystemSettings)
            }
            Button("OK", role: .cancel) { }
        } message: {
            if let reason = m.cleanupUnavailable {
                Text(reason + "\n\nChecking availability does not turn on Apple Intelligence or download its model.")
            } else {
                Text(m.smartCleanup
                    ? "Smart cleanup is enabled and ready. It runs after you finish a dictation."
                    : "Apple Intelligence supports your selected languages. Turn on Use on-device Smart cleanup to apply it after dictation.")
            }
        }
    }
}

// MARK: - Window

@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let onClose: () -> Void
    private let model: SettingsModel

    init(pausedDictation: PausedDictationControls = PausedDictationControls(), onClose: @escaping () -> Void) {
        self.onClose = onClose
        model = SettingsModel()
        window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(m: model, pausedDictation: pausedDictation)))
        window.title = "Phaedrus Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        super.init()
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.center()
    }

    func show() {
        model.refresh()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() { window.close() }

    func windowWillClose(_ notification: Notification) { onClose() }
}
