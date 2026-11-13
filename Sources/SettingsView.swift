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

enum SettingsPage: String, CaseIterable {
    case languages, cleanup, recording, shortcuts
    var title: String {
        switch self {
        case .languages: "Voice & languages"
        case .cleanup: "Smart cleanup"
        case .recording: "Recording"
        case .shortcuts: "Shortcuts & access"
        }
    }
    var symbol: String {
        switch self {
        case .languages: "globe"
        case .cleanup: "text.badge.checkmark"
        case .recording: "waveform"
        case .shortcuts: "keyboard"
        }
    }
    var subtitle: String {
        switch self {
        case .languages: "Speak naturally, in the languages you use."
        case .cleanup: "Choose how your spoken words become written text."
        case .recording: "A quiet space to speak, with a finish that feels right."
        case .shortcuts: "Your next thought is one shortcut away."
        }
    }
}

struct SettingsView: View {
    @ObservedObject var m: SettingsModel
    @ObservedObject var pausedDictation: PausedDictationControls
    @State private var page: SettingsPage
    @State private var languageSearch = ""
    @Environment(\.colorSchemeContrast) private var contrast

    init(m: SettingsModel, pausedDictation: PausedDictationControls, initialPage: SettingsPage = .languages) {
        self.m = m
        self.pausedDictation = pausedDictation
        _page = State(initialValue: initialPage)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(page.title).font(.system(size: 24, weight: .semibold))
                            .accessibilityAddTraits(.isHeader)
                        SettingsNote(page.subtitle)
                    }
                    Spacer(minLength: 0)
                }
                .padding(PhaedrusTheme.pagePadding)
                if pausedDictation.isPaused { pausedControls.padding(.horizontal, PhaedrusTheme.pagePadding).padding(.bottom, 16) }
                ScrollView {
                    VStack(alignment: .leading, spacing: PhaedrusTheme.space * 2) {
                        switch page {
                        case .languages: languageSettings
                        case .cleanup: SmartCleanupSettings(m: m)
                        case .recording: recordingSettings
                        case .shortcuts: shortcutSettings
                        }
                    }
                    .padding(.horizontal, PhaedrusTheme.pagePadding)
                    .padding(.bottom, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .id(page) // Start each page at the top, including when pausing to change languages.
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .font(.system(size: PhaedrusTheme.bodySize))
        .tint(PhaedrusTheme.accent)
        .background(PhaedrusTheme.canvas)
        .frame(minWidth: 780, idealWidth: 800, minHeight: 620, idealHeight: 680)
        .onChange(of: pausedDictation.isPaused) { _, paused in
            if paused { page = .languages; languageSearch = "" }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            m.refreshCleanupAvailability()
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 48, height: 48)
                    .accessibilityHidden(true)
                Text("Phaedrus").font(.system(size: 21, weight: .semibold))
                Text("A little space for your voice.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 32)
            VStack(spacing: 6) {
                ForEach(SettingsPage.allCases, id: \.self) { item in
                    Button { page = item } label: {
                        HStack(spacing: 9) {
                            Image(systemName: item.symbol).frame(width: 18)
                            Text(item.title).fontWeight(page == item ? .semibold : .regular)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 11)
                        .contentShape(Rectangle())
                        .foregroundStyle(page == item ? PhaedrusTheme.accent : Color.primary)
                        .background(page == item ? PhaedrusTheme.accent.opacity(0.11) : .clear,
                                    in: RoundedRectangle(cornerRadius: PhaedrusTheme.controlRadius))
                        .overlay {
                            if page == item {
                                RoundedRectangle(cornerRadius: PhaedrusTheme.controlRadius)
                                    .strokeBorder(PhaedrusTheme.accent.opacity(contrast == .increased ? 1 : 0.18))
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(page == item ? .isSelected : [])
                }
            }
            Spacer(minLength: 24)
            VStack(alignment: .leading, spacing: 9) {
                Label("On this Mac", systemImage: "desktopcomputer")
                    .font(.system(size: 12, weight: .medium))
                Text("Your audio stays here.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Rectangle()
                    .fill(LinearGradient(colors: PhaedrusTheme.ribbonColors.map { Color(nsColor: $0) },
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(height: 2).opacity(0.8).padding(.vertical, 5)
                    .accessibilityHidden(true)
                Text("Settings save automatically.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }.padding(12)
        }
        .padding(12)
        .frame(width: 208)
        .background(PhaedrusTheme.sidebar)
    }

    private var pausedControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Dictation paused", systemImage: "pause.circle.fill").fontWeight(.semibold)
                Spacer()
                Text("Microphone off").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            SettingsNote("Your earlier words are kept. Change settings, then pick up where you left off.")
            if let message = pausedDictation.message {
                Label(message, systemImage: "exclamationmark.circle").foregroundStyle(.red)
                    .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button("Resume dictation") { pausedDictation.action = .resume }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                Button("Finish and insert") { pausedDictation.action = .finish }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!pausedDictation.hasText)
                Button("Cancel") { pausedDictation.action = .cancel }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel("Cancel entire dictation")
            }
            Text("↵ Resume    ⌘↵ Finish    esc Cancel · Closing this window resumes.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if let warning = pausedDictation.deadlineWarning {
                Label(warning, systemImage: "clock").font(.system(size: 12))
                    .foregroundStyle(PhaedrusTheme.caution)
            }
        }
        .padding(16)
        .background(PhaedrusTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: PhaedrusTheme.cardRadius))
        .overlay {
            RoundedRectangle(cornerRadius: PhaedrusTheme.cardRadius)
                .strokeBorder(PhaedrusTheme.accent.opacity(contrast == .increased ? 0.8 : 0.25))
        }
    }

    private var filteredLanguages: [Locale] {
        m.supported.filter { languageSearch.isEmpty || m.name($0).localizedCaseInsensitiveContains(languageSearch)
            || $0.identifier.localizedCaseInsensitiveContains(languageSearch) }
            .sorted {
                if m.isOn($0) != m.isOn($1) { return m.isOn($0) }
                return m.name($0).localizedStandardCompare(m.name($1)) == .orderedAscending
            }
    }

    private var languageSettings: some View {
        VStack(alignment: .leading, spacing: PhaedrusTheme.space * 2) {
            SettingsCard(title: "Listening languages", symbol: "globe") {
                HStack(spacing: 6) {
                    ForEach(m.selected, id: \.self) { id in
                        let locale = Locale(identifier: id)
                        SettingsBadge(text: locale.language.languageCode?.identifier.uppercased() ?? id,
                                      symbol: "checkmark")
                            .help(m.name(locale))
                            .accessibilityLabel(m.name(locale) + ", selected")
                    }
                    Spacer()
                    Text("\(m.selected.count) of \(Prefs.maxLanguages) selected")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Find a language", text: $languageSearch).textFieldStyle(.plain)
                        .accessibilityLabel("Find a language")
                    if !languageSearch.isEmpty {
                        Button { languageSearch = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .accessibilityLabel("Clear language search")
                    }
                }
                .padding(10).background(PhaedrusTheme.inset, in: RoundedRectangle(cornerRadius: 8))
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if m.loadingLanguages {
                            Label("Loading languages…", systemImage: "ellipsis").foregroundStyle(.secondary).padding(8)
                        } else if m.supported.isEmpty {
                            SettingsNote("On-device languages are unavailable on this Mac.").padding(8)
                        } else if filteredLanguages.isEmpty {
                            SettingsNote("No languages match your search.").padding(8)
                        }
                        ForEach(filteredLanguages, id: \.identifier) { locale in
                            Toggle(isOn: Binding(get: { m.isOn(locale) }, set: { m.set(locale, $0) })) {
                                HStack {
                                    Text(m.name(locale)).frame(maxWidth: .infinity, alignment: .leading)
                                    if m.installed.contains(locale.identifier) {
                                        Image(systemName: "arrow.down.circle.fill")
                                            .foregroundStyle(PhaedrusTheme.success)
                                            .help("Speech model downloaded")
                                            .accessibilityLabel("Speech model downloaded")
                                    }
                                }
                            }
                            .toggleStyle(.checkbox)
                            .padding(.horizontal, 8).padding(.vertical, 9)
                            .background(m.isOn(locale) ? PhaedrusTheme.accent.opacity(0.06) : .clear,
                                        in: RoundedRectangle(cornerRadius: 7))
                            .disabled(m.isOn(locale) ? m.selected.count == 1 : m.selected.count >= Prefs.maxLanguages)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: pausedDictation.isPaused ? 140 : 190)
                SettingsNote("Choose up to three. Speech models download from Apple on first use; each extra language adds work while you speak.")
            }
            SettingsCard(title: "One thought, more than one language", symbol: "bubble.left.and.bubble.right") {
                SettingsToggle(title: "Mix languages in one dictation", isOn: $m.mixLanguages)
                    .disabled(m.selected.count < 2)
                HStack(alignment: .top, spacing: 10) {
                    SettingsBadge(text: "Experimental")
                    SettingsNote(m.selected.count < 2
                        ? "Select at least two languages to mix words within a sentence."
                        : "Keeps each word in the language you speak. Results can still be wrong; with mixing off, the best single-language transcript is used.")
                }
            }
        }
    }

    private var recordingSettings: some View {
        VStack(spacing: PhaedrusTheme.space * 2) {
            SettingsCard(title: "When to finish", symbol: "timer") {
                slider("Stop after silence", value: $m.silence, range: 1...8, step: 0.5, unit: "s")
                slider("Give up if nothing is heard", value: $m.noSpeech, range: 5...30, step: 1, unit: "s")
                slider("Longest dictation", value: $m.maxMinutes, range: 1...15, step: 1, unit: "min")
                Divider()
                SettingsNote("Finish early with the microphone key, Return, or a click on the recording panel. Esc cancels. While recording, Return and Esc go to Phaedrus.")
            }
            SettingsCard(title: "After dictating", symbol: "doc.on.clipboard") {
                SettingsToggle(title: "Also copy the text to the clipboard", detail: "Paste with ⌘V in apps that don’t accept Services text.", isOn: $m.copyToClipboard)
                SettingsNote("The copy stays on this Mac, outside Universal Clipboard. Clipboard managers can still record it.")
                Divider()
                SettingsToggle(title: "Play start and stop sounds", isOn: $m.playSounds)
            }
            Label {
                SettingsNote("The ribbon follows microphone activity. Live transcripts stay hidden so you can focus on speaking.")
            } icon: { Image(systemName: "waveform").foregroundStyle(PhaedrusTheme.accent) }
            .padding(.horizontal, 4)
        }
    }

    private var shortcutSettings: some View {
        VStack(spacing: PhaedrusTheme.space * 2) {
            SettingsCard(title: "Start with a key", symbol: "keyboard") {
                SettingsToggle(title: "Use the 🎤 key to dictate", isOn: Binding(get: { m.micKey }, set: { m.setMicKey($0) }))
                HStack { Text("Dictation shortcut"); Spacer(); KeyCap(text: m.shortcut) }
                Button("Change shortcut in System Settings…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
                }
                if let msg = m.message {
                    Label(msg, systemImage: "exclamationmark.circle").font(.system(size: 12)).foregroundStyle(.red)
                }
                SettingsNote("The microphone key is remapped to F18. In Keyboard Shortcuts → Services, assign shortcuts to “Dictate with Phaedrus” or “Phaedrus Settings”. The settings shortcut can also launch the app.")
            }
            SettingsCard(title: "While you speak", symbol: "command") {
                shortcutRow("Finish and insert", key: "↵")
                shortcutRow("Cancel dictation", key: "esc")
                shortcutRow("Pause and open settings", key: "⌘ ,")
                SettingsNote("While paused, Return or closing Settings resumes. ⌘Return finishes with the words already captured.")
            }
            SettingsCard(title: "Microphone access", symbol: "mic") {
                HStack {
                    SettingsBadge(text: micStatus, symbol: m.micAuth == .authorized ? "checkmark.circle" : "exclamationmark.circle",
                                  color: m.micAuth == .authorized ? PhaedrusTheme.success : PhaedrusTheme.caution)
                    Spacer()
                    if m.micAuth == .notDetermined {
                        Button("Allow microphone…") { m.requestMic() }
                    } else if m.micAuth != .authorized {
                        Button("Open Privacy Settings…") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                        }
                    }
                }
            }
        }
    }

    private var micStatus: String {
        switch m.micAuth {
        case .authorized: "Allowed"
        case .denied, .restricted: "Denied"
        default: "Not asked yet"
        }
    }

    private func shortcutRow(_ title: String, key: String) -> some View {
        HStack { Text(title); Spacer(); KeyCap(text: key) }
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                Spacer()
                Text(value.wrappedValue.truncatingRemainder(dividingBy: 1) == 0
                     ? "\(Int(value.wrappedValue)) \(unit)" : String(format: "%.1f \(unit)", value.wrappedValue))
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step).accessibilityLabel(title)
                .accessibilityValue("\(value.wrappedValue) \(unit)")
        }
    }
}

/// Kept together so readiness, setup guidance, and manual-check feedback agree.
struct SmartCleanupSettings: View {
    @ObservedObject var m: SettingsModel
    @Environment(\.colorSchemeContrast) private var contrast

    private func openSystemSettings() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }

    private func summary(_ style: CleanupStyle) -> String {
        switch style {
        case .conservative: "Recognized alternatives and final punctuation."
        case .natural: "Fewer repetitions, fillers, and abandoned starts."
        case .written: "Natural cleanup, plus grammar and word corrections."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PhaedrusTheme.space * 2) {
            SettingsCard(title: "On-device review", symbol: "sparkles") {
                SettingsToggle(title: "Use on-device Smart cleanup", detail: "Apple Intelligence reviews your text after dictation.", isOn: $m.smartCleanup)
                    .disabled(m.cleanupUnavailable != nil && !m.smartCleanup)
                HStack {
                    SettingsBadge(text: m.cleanupUnavailable != nil ? "Setup needed" : (m.smartCleanup ? "Ready · cleanup enabled" : "Ready · cleanup off"),
                                  symbol: m.cleanupUnavailable != nil ? "exclamationmark.circle" : "checkmark.circle",
                                  color: m.cleanupUnavailable != nil ? PhaedrusTheme.caution : PhaedrusTheme.success)
                    Spacer()
                    Button("Check availability") { m.checkCleanupAvailability() }
                        .help("Checks readiness only. Cleanup runs after you finish speaking.")
                }
                if let reason = m.cleanupUnavailable {
                    SettingsNote(reason)
                    Button("Open System Settings…", action: openSystemSettings)
                        .help("Choose Apple Intelligence & Siri in System Settings.")
                }
            }
            SettingsCard(title: "Review style", symbol: "text.badge.checkmark") {
                VStack(spacing: 8) {
                    ForEach(CleanupStyle.allCases, id: \.self) { style in
                        Button { m.cleanupStyle = style } label: {
                            HStack(spacing: 12) {
                                Image(systemName: m.cleanupStyle == style ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 18))
                                    .foregroundStyle(m.cleanupStyle == style ? PhaedrusTheme.accent : Color.secondary)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(style.title).fontWeight(.semibold).foregroundStyle(.primary)
                                    Text(summary(style)).font(.system(size: 12)).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .background(m.cleanupStyle == style ? PhaedrusTheme.accent.opacity(0.07) : PhaedrusTheme.inset,
                                        in: RoundedRectangle(cornerRadius: PhaedrusTheme.controlRadius))
                            .overlay {
                                RoundedRectangle(cornerRadius: PhaedrusTheme.controlRadius)
                                    .strokeBorder(m.cleanupStyle == style ? PhaedrusTheme.accent.opacity(0.7)
                                                  : Color.primary.opacity(contrast == .increased ? 0.4 : 0.06))
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(style.title + ". " + summary(style))
                        .accessibilityAddTraits(m.cleanupStyle == style ? .isSelected : [])
                        .disabled(!m.smartCleanup)
                    }
                }
                DisclosureGroup("What \(m.cleanupStyle.title) changes") {
                    VStack(alignment: .leading, spacing: 8) {
                        SettingsBadge(text: "Experimental")
                        SettingsNote(m.cleanupStyle.explanation)
                        SettingsNote("Enable language mixing to compare recognized alternatives across languages.")
                    }.padding(.top, 8)
                }
                SettingsNote("Up to \(Int(m.cleanupStyle.timeoutSeconds)) seconds. Text that cannot be reviewed is kept.")
            }
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
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.titlebarAppearsTransparent = true
        window.setContentSize(NSSize(width: 800, height: 680))
        window.contentMinSize = NSSize(width: 780, height: 620)
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
