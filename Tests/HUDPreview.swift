// Render the real AppKit panel with synthetic levels, without opening a
// microphone or invoking the speech engine. Used to inspect UI changes in CI.
import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

@main
@MainActor
enum HUDPreview {
    static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        print("System Reduce Motion: \(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion); previewing both modes")
        let hud = HUD(reduceMotion: false)
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
            let start = Date()
            let end = start.addingTimeInterval(name == "listening" ? 2.7 : 0.7)
            while Date() < end {
                if let level {
                    let input = name == "listening" ? speechLevel(at: Date().timeIntervalSince(start)) : max(0, level)
                    hud.updateAudio(.init(level: input, lastBuffer: level < 0 ? nil : Date()), elapsed: 42)
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
        try liveRibbonPreview(hud: hud, in: directory)
        hud.hide()
        try reducedMotionPreview(in: directory)
        if let icon = NSImage(contentsOfFile: "docs/icon.png") { app.applicationIconImage = icon }
        try settingsPreviews(in: directory)
    }

    /// Synthetic syllables separated by silence, so the preview can establish
    /// that the picture follows the supplied levels instead of a decorative sine.
    static func speechLevel(at time: Double) -> Double {
        let pulses: [(Double, Double, Double)] = [
            (0.65, 0.10, 0.55), (0.95, 0.08, 0.90), (1.20, 0.07, 0.60),
            (1.60, 0.12, 1.00), (2.12, 0.09, 0.70), (2.40, 0.10, 0.45),
            (3.25, 0.08, 0.60), (3.55, 0.14, 0.95), (3.95, 0.10, 0.65)
        ]
        return min(1, pulses.reduce(0.0) { level, pulse in
            let distance = (time - pulse.0) / pulse.1
            return level + pulse.2 * exp(-0.5 * distance * distance)
        })
    }

    /// Export real AppKit frames as a GIF; no generated artwork or microphone.
    static func liveRibbonPreview(hud: HUD, in directory: URL) throws {
        let frames = 150
        let interval = 0.05
        let url = directory.appendingPathComponent("listening-live.gif")
        guard let gif = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames, nil) else {
            throw PhaedrusError("Could not create the recording animation preview")
        }
        CGImageDestinationSetProperties(gif, [kCGImagePropertyGIFDictionary:
            [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        hud.show(.listening, "Listening")
        let start = Date()
        for frame in 0..<frames {
            let end = start.addingTimeInterval(Double(frame + 1) * interval)
            let time = Date().timeIntervalSince(start)
            // The real Service supplies meter updates roughly every 50 ms too.
            hud.updateAudio(.init(level: speechLevel(at: time), lastBuffer: Date()), elapsed: time)
            repeat {
                RunLoop.current.run(until: Date().addingTimeInterval(1.0 / 60))
            } while Date() < end
            guard let view = NSApp.windows.first(where: { $0.isVisible })?.contentView,
                  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                throw PhaedrusError("Could not capture the recording animation")
            }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let cgImage = bitmap.cgImage else { throw PhaedrusError("Recording frame is missing") }
            CGImageDestinationAddImage(gif, cgImage, [kCGImagePropertyGIFDictionary:
                [kCGImagePropertyGIFDelayTime: interval]] as CFDictionary)
        }
        guard CGImageDestinationFinalize(gif) else { throw PhaedrusError("Could not finish the recording animation") }
    }

    static func reducedMotionPreview(in directory: URL) throws {
        let hud = HUD(reduceMotion: true)
        hud.languages(["pt_BR", "en_US"])
        hud.show(.listening, "Listening")
        let end = Date().addingTimeInterval(0.5)
        while Date() < end {
            hud.updateAudio(.init(level: 0.8, lastBuffer: Date()), elapsed: 42)
            RunLoop.current.run(until: Date().addingTimeInterval(1.0 / 30))
        }
        defer { hud.hide() }
        guard let view = NSApp.windows.first(where: { $0.isVisible })?.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw PhaedrusError("Could not render the reduced-motion recording panel")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw PhaedrusError("Could not encode the reduced-motion recording panel")
        }
        try data.write(to: directory.appendingPathComponent("listening-reduced-motion.png"))
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
