// Render the real AppKit panel with synthetic levels, without opening a
// microphone or invoking the speech engine. Used to inspect UI changes in CI.
import AppKit

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
            ("interrupted", .listening, "Listening", -1),
            ("preparing", .preparing, "Downloading speech model… 45%", nil),
            ("finishing", .transcribing, "Finishing…", nil),
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
    }
}
