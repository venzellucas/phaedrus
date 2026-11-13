// Render the real AppKit panel with synthetic levels, without opening a
// microphone or invoking the speech engine. Used to inspect UI changes in CI.
import AppKit
import SwiftUI

@main
@MainActor
enum HUDPreview {
    static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let hud = HUD()
        hud.languages(["pt_BR", "en_US", "es_ES"])
        let states: [(String, HUD.Mode, String, Double?)] = [
            ("listening", .listening, "Listening", 0.8),
            ("quiet", .listening, "Listening", 0.02),
            ("paused", .paused, "Paused · microphone off", nil),
            ("interrupted", .listening, "Listening", -1),
            ("preparing", .preparing, "Downloading speech model… 45%", nil),
            ("finishing", .transcribing, "Finishing…", nil),
            ("refining", .transcribing, "Refining…", nil),
            ("error", .error, "Microphone access denied. Allow it in System Settings → Privacy & Security → Microphone", nil)
        ]
        for (name, mode, title, level) in states {
            hud.show(mode, title)
            let end = Date().addingTimeInterval(0.7)
            while Date() < end {
                if let level {
                    hud.updateAudio(.init(level: max(0, level), lastBuffer: level < 0 ? nil : Date()), elapsed: 42)
                }
                RunLoop.current.run(until: Date().addingTimeInterval(1.0 / 30))
            }
            guard let view = app.windows.first(where: { $0.isVisible })?.contentView,
                  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                throw PhaedrusError("Could not render the recording panel")
            }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else {
                throw PhaedrusError("Could not encode the recording panel")
            }
            try data.write(to: directory.appendingPathComponent(name + ".png"))
        }
        hud.hide()
        if let icon = NSImage(contentsOfFile: "docs/icon.png") { app.applicationIconImage = icon }
        try settingsPreviews(in: directory)
    }

    /// Render the real settings in both appearances with stable, synthetic states.
    /// No microphone permission, speech model download, or changes to the app’s preference domain.
    static func settingsPreviews(in directory: URL) throws {
        Prefs.d.setVolatileDomain(["locales": ["pt_BR", "en_US"], "smartCleanup": true,
                                  "mixLanguages": true, "cleanupStyle": "written"], forName: "NSArgumentDomain")
        defer { Prefs.d.removeVolatileDomain(forName: "NSArgumentDomain") }
        for dark in [false, true] {
            for page in SettingsPage.allCases {
                try settingsPreview(page: page, dark: dark, in: directory)
            }
        }
        try settingsPreview(page: .languages, dark: false, paused: true, compact: true, in: directory)
        try settingsPreview(page: .cleanup, dark: false, unavailable: true, in: directory)
        try settingsPreview(page: .cleanup, dark: true, compact: true, highContrast: true, in: directory)
    }

    static func settingsPreview(page: SettingsPage, dark: Bool, paused: Bool = false,
                                compact: Bool = false, unavailable: Bool = false,
                                highContrast: Bool = false, in directory: URL) throws {
        let model = SettingsModel(cleanupAvailabilityCheck: { _ in
            unavailable ? "Turn on Apple Intelligence in System Settings → Apple Intelligence & Siri. Return here when its model is ready." : nil
        })
        model.loadingLanguages = false
        model.supported = ["en_US", "pt_BR", "es_ES", "fr_FR", "de_DE", "it_IT", "ja_JP", "ko_KR", "zh_CN"].map { Locale(identifier: $0) }
        model.installed = ["en_US", "pt_BR"]
        model.micAuth = .authorized
        model.shortcut = "F18 (🎤 key)"
        model.refreshCleanupAvailability()
        if unavailable { model.smartCleanup = false }
        let controls = PausedDictationControls()
        controls.isPaused = paused
        controls.hasText = paused
        let view = SettingsView(m: model, pausedDictation: controls, initialPage: page)
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: highContrast
            ? (dark ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua)
            : (dark ? .darkAqua : .aqua))
        window.setContentSize(NSSize(width: compact ? 780 : 800, height: compact ? 620 : 680))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer { window.close() }
        // Hosting views need a completed layout pass before bitmap capture.
        let end = Date().addingTimeInterval(0.4)
        while Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        guard let content = window.contentView else { throw PhaedrusError("Settings content is missing") }
        content.layoutSubtreeIfNeeded()
        guard content.bounds.width > 0, content.bounds.height > 0,
              let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
            throw PhaedrusError("Could not render settings")
        }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw PhaedrusError("Could not encode settings")
        }
        let name = "settings-\(page.rawValue)-\(dark ? "dark" : "light")"
            + (paused ? "-paused" : "") + (compact ? "-compact" : "")
            + (unavailable ? "-setup" : "") + (highContrast ? "-contrast" : "")
        try data.write(to: directory.appendingPathComponent(name + ".png"))
    }

}
