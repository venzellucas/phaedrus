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
final class SettingsModel: ObservableObject {
    private let d = Prefs.d

    @Published var supported: [Locale] = []
    @Published var installed: Set<String> = []
    @Published var selected: [String] { didSet { d.set(selected, forKey: "locales") } }
    @Published var silence: Double { didSet { d.set(silence, forKey: "silenceSeconds") } }
    @Published var noSpeech: Double { didSet { d.set(noSpeech, forKey: "noSpeechSeconds") } }
    @Published var maxMinutes: Double { didSet { d.set(maxMinutes * 60, forKey: "maxSeconds") } }
    @Published var copyToClipboard: Bool { didSet { d.set(copyToClipboard, forKey: "copyToClipboard") } }
    @Published var playSounds: Bool { didSet { d.set(playSounds, forKey: "playSounds") } }
    @Published var mixLanguages: Bool { didSet { d.set(mixLanguages, forKey: "mixLanguages") } }

    @Published var micKey = false
    @Published var shortcut = "…"
    @Published var micAuth = AVCaptureDevice.authorizationStatus(for: .audio)
    @Published var message: String?

    init() {
        selected = Prefs.locales
        silence = Prefs.silence
        noSpeech = Prefs.noSpeech
        maxMinutes = (Prefs.maxSeconds / 60).rounded()
        copyToClipboard = Prefs.copyToClipboard
        playSounds = Prefs.playSounds
        mixLanguages = Prefs.mixLanguages
    }

    func refresh() async {
        micKey = Shortcut.micKeyRemapped
        shortcut = Shortcut.describe(Shortcut.serviceShortcut)
        micAuth = AVCaptureDevice.authorizationStatus(for: .audio)
        let names = Locale.current
        supported = await SpeechTranscriber.supportedLocales.sorted {
            (names.localizedString(forIdentifier: $0.identifier) ?? $0.identifier)
                < (names.localizedString(forIdentifier: $1.identifier) ?? $1.identifier)
        }
        installed = Set(await SpeechTranscriber.installedLocales.map(\.identifier))
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

    func requestMic() async {
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        micAuth = AVCaptureDevice.authorizationStatus(for: .audio)
    }
}

// MARK: - View

struct SettingsView: View {
    @ObservedObject var m: SettingsModel

    private var micStatus: String {
        switch m.micAuth {
        case .authorized: "Allowed"
        case .denied, .restricted: "Denied"
        default: "Not asked yet"
        }
    }

    var body: some View {
        Form {
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

            Section {
                Toggle("Use the 🎤 key to dictate", isOn: Binding(get: { m.micKey }, set: { m.setMicKey($0) }))
                LabeledContent("Shortcut", value: m.shortcut)
                Button("Change shortcut in System Settings…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
                }
                if let msg = m.message { Text(msg).font(.caption).foregroundStyle(.red) }
            } header: { Text("Shortcut") } footer: {
                Text("The 🎤 key is remapped to F18, so Apple Dictation stops using it. You can also pick any shortcut under Keyboard Shortcuts → Services → Text → “Dictate with Phaedrus”.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
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

            Section("Stopping") {
                slider("Stop after silence", value: $m.silence, range: 1...8, step: 0.5, unit: "s")
                slider("Give up if nothing is heard", value: $m.noSpeech, range: 5...30, step: 1, unit: "s")
                slider("Longest dictation", value: $m.maxMinutes, range: 1...15, step: 1, unit: "min")
                Text("Stop early with 🎤, Return, or a click on the bubble; Esc cancels. While the bubble is shown, Return and Esc go to Phaedrus, not to other apps.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("The recording ribbon reacts to microphone input. Live transcripts stay hidden so you can focus on speaking.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("After dictating") {
                Toggle("Also copy the text to the clipboard", isOn: $m.copyToClipboard)
                Text("Useful in apps that don't accept Services text: just press ⌘V. The copy stays on this Mac (not shared via Universal Clipboard), but clipboard managers can record it.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Play start and stop sounds", isOn: $m.playSounds)
            }

            Section("Permissions") {
                LabeledContent("Microphone", value: micStatus)
                if m.micAuth == .notDetermined {
                    Button("Allow microphone…") { Task { await m.requestMic() } }
                } else if m.micAuth != .authorized {
                    Button("Open Privacy Settings…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 700)
        .task { await m.refresh() }
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

// MARK: - Window

@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
        window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(m: SettingsModel())))
        window.title = "Phaedrus Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        super.init()
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.center()
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() { window.close() }

    func windowWillClose(_ notification: Notification) { onClose() }
}
