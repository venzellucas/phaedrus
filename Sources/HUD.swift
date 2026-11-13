// A quiet recording surface. The ribbon is an activity indicator, not a plot of
// the microphone waveform. Its energy follows real input; its shape stays fluid.

import AppKit
import QuartzCore

@MainActor
final class HUD {
    enum Mode { case preparing, listening, transcribing, error }

    private let panel: NSPanel
    private let surface: RecordingSurface
    private var animationTimer: Timer?
    var onClick: (() -> Void)?

    init() {
        let frame = NSRect(x: 0, y: 0, width: 420, height: 124)
        panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        // Draw the rounded surface and its shadow together. A rectangular window
        // or visual-effect backing must never show outside the rounded silhouette.
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        surface = RecordingSurface(frame: frame)
        panel.contentView = surface
        surface.onClick = { [weak self] in self?.onClick?() }
    }

    func languages(_ ids: [String]) {
        surface.languageText = ids.map {
            let locale = Locale(identifier: $0)
            let language = locale.language.languageCode?.identifier.uppercased() ?? $0
            return language
        }.joined(separator: " · ")
        surface.languageDescription = ids.map {
            Locale.current.localizedString(forIdentifier: $0) ?? $0
        }.joined(separator: ", ")
    }

    func show(_ mode: Mode, _ text: String) {
        surface.mode = mode
        surface.title.stringValue = text
        surface.title.toolTip = text
        surface.clock.stringValue = ""
        surface.targetLevel = 0
        surface.inputAvailable = false
        surface.updateLabels()
        if !panel.isVisible {
            let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
            if let f = screen?.visibleFrame {
                panel.setFrameOrigin(NSPoint(x: f.midX - panel.frame.width / 2, y: f.minY + 78))
            }
            panel.orderFrontRegardless()
        }
        if animationTimer == nil {
            let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.surface.tick() }
            }
            // The Service pumps a nested default-mode run loop.
            RunLoop.main.add(timer, forMode: .common)
            animationTimer = timer
        }
        surface.needsDisplay = true
    }

    func status(_ text: String) {
        surface.title.stringValue = text
        surface.title.toolTip = text
    }

    func updateAudio(_ activity: DictationEngine.AudioActivity, elapsed: TimeInterval) {
        let available = activity.lastBuffer.map { Date().timeIntervalSince($0) < 0.6 } ?? false
        surface.inputAvailable = available
        surface.targetLevel = available ? activity.level : 0
        let title = available || elapsed < 0.6 ? "Listening" : "Microphone interrupted"
        if surface.title.stringValue != title { surface.title.stringValue = title }
        let seconds = max(0, Int(elapsed))
        surface.clock.stringValue = String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    func hide() {
        animationTimer?.invalidate()
        animationTimer = nil
        panel.orderOut(nil)
    }
}

@MainActor
private final class RecordingSurface: NSView {
    let title = NSTextField(labelWithString: "")
    let clock = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: "")
    var mode = HUD.Mode.preparing
    var languageText = ""
    var languageDescription = ""
    var targetLevel: Double = 0
    var inputAvailable = false
    var onClick: (() -> Void)?
    private var level = 0.0
    private var phase = 0.0
    private var lastTick = CACurrentMediaTime()

    override var isOpaque: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        appearance = NSAppearance(named: .darkAqua)
        title.frame = NSRect(x: 34, y: 74, width: 302, height: 24)
        title.font = .systemFont(ofSize: 14, weight: .medium)
        title.textColor = .white
        title.lineBreakMode = .byTruncatingTail
        clock.frame = NSRect(x: 338, y: 76, width: 48, height: 20)
        clock.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        clock.textColor = NSColor(white: 0.78, alpha: 1)
        clock.alignment = .right
        detail.frame = NSRect(x: 34, y: 26, width: 130, height: 17)
        hint.frame = NSRect(x: 164, y: 26, width: 222, height: 17)
        hint.alignment = .right
        for label in [detail, hint] {
            label.font = .systemFont(ofSize: 11, weight: .medium)
            label.textColor = NSColor(white: 0.78, alpha: 1)
        }
        for label in [title, clock, detail, hint] { addSubview(label) }
        // Timer changes are visual only; don't announce elapsed time every frame.
        clock.setAccessibilityElement(false)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityHelp("Press Return or click to finish dictation. Press Escape to cancel.")
        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(clicked(_:))))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func clicked(_ recognizer: NSClickGestureRecognizer) {
        let point = recognizer.location(in: self)
        if silhouette.contains(point) { onClick?() }
    }

    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
    override func accessibilityLabel() -> String? {
        "Phaedrus. \(title.stringValue). \(mode == .listening ? languageDescription : "")"
    }

    func updateLabels() {
        detail.stringValue = mode == .listening ? languageText : "Phaedrus"
        detail.toolTip = mode == .listening ? languageDescription : nil
        hint.stringValue = switch mode {
        case .listening: "↵ finish    esc cancel"
        case .preparing: "esc cancel"
        case .transcribing: ""
        case .error: "Try again with the shortcut"
        }
        title.frame = mode == .error
            ? NSRect(x: 34, y: 52, width: 352, height: 48)
            : NSRect(x: 34, y: 74, width: 302, height: 24)
        title.maximumNumberOfLines = mode == .error ? 3 : 1
        title.lineBreakMode = mode == .error ? .byWordWrapping : .byTruncatingTail
    }

    func tick() {
        let now = CACurrentMediaTime()
        let dt = min(max(now - lastTick, 0), 0.1)
        lastTick = now
        let rate = targetLevel > level ? 12.0 : 4.0
        level += (targetLevel - level) * (1 - exp(-dt * rate))
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        // An interrupted microphone gets a still ribbon, never a fake signal.
        if !reduced && (mode != .listening || inputAvailable) { phase += dt * (mode == .listening ? 1.6 : 0.8) }
        needsDisplay = true
    }

    private var silhouette: NSBezierPath {
        NSBezierPath(roundedRect: bounds.insetBy(dx: 12, dy: 12), xRadius: 30, yRadius: 30)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let shape = silhouette
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 10
        shadow.shadowOffset = NSSize(width: 0, height: -3)
        shadow.set()
        NSColor(white: 0.09, alpha: 1).setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        let solid = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        if !solid {
            NSGradient(starting: NSColor(white: 0.17, alpha: 1), ending: NSColor(white: 0.075, alpha: 1))?
                .draw(in: bounds, angle: -90)
        }
        if mode != .error { drawRibbon() }
        NSGraphicsContext.restoreGraphicsState()
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        NSColor.white.withAlphaComponent(contrast ? 0.65 : 0.16).setStroke()
        shape.lineWidth = 1
        shape.stroke()
    }

    private func drawRibbon() {
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let energy = mode == .listening ? level : 0.18
        let amplitude = reduced ? 3.0 : 2.5 + energy * 8.5
        let colors: [NSColor] = [
            NSColor(srgbRed: 1, green: 0.47, blue: 0.43, alpha: 1),
            NSColor(srgbRed: 0.8, green: 0.47, blue: 1, alpha: 1),
            NSColor(srgbRed: 0.34, green: 0.67, blue: 1, alpha: 1),
            NSColor(srgbRed: 0.40, green: 0.90, blue: 0.77, alpha: 1)
        ]
        for ribbon in 0..<3 {
            let path = NSBezierPath()
            let offset = Double(ribbon) * 1.4
            let thickness = (ribbon == 0 ? 2.2 : 1.2) + energy * 1.4
            func point(_ step: Int, _ edge: Double) -> NSPoint {
                let x = Double(step) / 80
                let envelope = pow(sin(.pi * x), 1.4)
                let wave = sin(x * .pi * 2.2 - phase + offset) * 0.7
                    + sin(x * .pi * 3.4 + phase * 0.7 + offset) * 0.3
                return NSPoint(x: 34 + x * 352, y: 59 + envelope * (wave * amplitude + edge * thickness))
            }
            path.move(to: point(0, 1))
            for step in 1...80 { path.line(to: point(step, 1)) }
            for step in (0...80).reversed() { path.line(to: point(step, -1)) }
            path.close()
            let opacity = mode == .listening && !inputAvailable ? 0.25 : (ribbon == 0 ? 0.95 : 0.35)
            NSGradient(colors: colors.map { $0.withAlphaComponent(opacity) })?.draw(in: path, angle: 0)
        }
    }
}
