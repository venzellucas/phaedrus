// A quiet recording surface. While listening, the ribbon shows a short history
// of the real microphone meter. It indicates audio input, not recognition accuracy.

import AppKit
import QuartzCore

@MainActor
final class HUD {
    enum Mode { case preparing, listening, paused, transcribing, error }

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
        surface.resetAudio()
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
        let time = String(format: "%d:%02d", seconds / 60, seconds % 60)
        if surface.clock.stringValue != time { surface.clock.stringValue = time }
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
    var inputAvailable = false {
        didSet { if inputAvailable != oldValue { needsDisplay = true } }
    }
    var onClick: (() -> Void)?
    private var ribbon = AudioRibbon()
    private var phase = 0.0
    private var lastTick = CACurrentMediaTime()

    override var isOpaque: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        appearance = NSAppearance(named: .darkAqua)
        title.frame = NSRect(x: 34, y: 74, width: 302, height: 24)
        title.font = .systemFont(ofSize: PhaedrusTheme.panelTitleSize, weight: .medium)
        title.textColor = .white
        title.lineBreakMode = .byTruncatingTail
        clock.frame = NSRect(x: 338, y: 76, width: 48, height: 20)
        clock.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        clock.textColor = PhaedrusTheme.panelSecondary
        clock.alignment = .right
        detail.frame = NSRect(x: 34, y: 26, width: 130, height: 17)
        hint.frame = NSRect(x: 164, y: 26, width: 222, height: 17)
        hint.alignment = .right
        for label in [detail, hint] {
            label.font = .systemFont(ofSize: PhaedrusTheme.captionSize, weight: .medium)
            label.textColor = PhaedrusTheme.panelSecondary
        }
        for label in [title, clock, detail, hint] { addSubview(label) }
        // Timer changes are visual only; don't announce elapsed time every frame.
        clock.setAccessibilityElement(false)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityHelp("Press Return or click to finish dictation. Press Escape to cancel. Press Command-comma to pause and change settings.")
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
        setAccessibilityHelp(mode == .paused
            ? "The microphone is off. Press Return or click to resume. Press Escape to cancel the entire dictation."
            : "Press Return or click to finish dictation. Press Escape to cancel. Press Command-comma to pause and change settings.")
        detail.stringValue = mode == .listening ? languageText : "Phaedrus"
        detail.toolTip = mode == .listening ? languageDescription : nil
        hint.stringValue = switch mode {
        case .listening: "↵ finish   esc cancel   ⌘, settings"
        case .preparing: "esc cancel   ⌘, settings"
        case .paused: "↵ resume    esc cancel"
        case .transcribing: ""
        case .error: "Try again with the shortcut"
        }
        title.frame = mode == .error
            ? NSRect(x: 34, y: 52, width: 352, height: 48)
            : NSRect(x: 34, y: 74, width: 302, height: 24)
        title.maximumNumberOfLines = mode == .error ? 3 : 1
        title.lineBreakMode = mode == .error ? .byWordWrapping : .byTruncatingTail
    }

    func resetAudio() {
        targetLevel = 0
        inputAvailable = false
        ribbon.reset()
        lastTick = CACurrentMediaTime()
        phase = 0
    }

    func tick() {
        let now = CACurrentMediaTime()
        let dt = min(max(now - lastTick, 0), 0.1)
        lastTick = now
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if mode == .listening && inputAvailable {
            let wasQuiet = ribbon.isQuiet
            ribbon.advance(target: targetLevel, delta: dt)
            if !wasQuiet || !ribbon.isQuiet { needsDisplay = true }
        } else if !reduced && (mode == .preparing || mode == .transcribing) {
            // A decorative progress wave belongs only to non-recording states.
            phase += dt * 0.8
            needsDisplay = true
        }
        // A flat silent ribbon, a pause, and an interrupted input need no redraw.
    }

    private var silhouette: NSBezierPath {
        NSBezierPath(roundedRect: bounds.insetBy(dx: 12, dy: 12), xRadius: PhaedrusTheme.panelRadius, yRadius: PhaedrusTheme.panelRadius)
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
        PhaedrusTheme.panelBase.setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        let solid = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        if !solid {
            NSGradient(starting: PhaedrusTheme.panelTop, ending: PhaedrusTheme.panelBottom)?
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
        let listening = mode == .listening
        let colors = PhaedrusTheme.ribbonColors
        let interrupted = listening && !inputAvailable
        for layer in 0..<3 {
            let path = NSBezierPath()
            func point(_ step: Int, _ edge: Double) -> NSPoint {
                let x = Double(step) / 120
                // Fade just the ends, so new speech is visible near the right edge.
                let ends = min(1, min(x, 1 - x) / 0.08)
                let taper = ends * ends * (3 - 2 * ends)
                let height: Double
                let center: Double
                if listening {
                    // Reduce Motion gets a stationary, symmetric level indicator;
                    // level changes remain visible without a traveling waveform.
                    let amplitude = reduced ? ribbon.level * pow(sin(.pi * x), 2) : ribbon.amplitude(at: x)
                    height = 0.65 + amplitude * (14.0 - Double(layer) * 3.5)
                    center = 59
                } else {
                    let envelope = pow(sin(.pi * x), 1.4)
                    let wave = reduced || mode == .paused ? 0
                        : sin(x * .pi * 2.2 - phase + Double(layer) * 1.4)
                    center = 59 + envelope * wave * 3.5
                    height = mode == .paused ? 0.65 : 1.3
                }
                return NSPoint(x: 34 + x * 352, y: center + edge * height * taper)
            }
            path.move(to: point(0, 1))
            for step in 1...120 { path.line(to: point(step, 1)) }
            for step in (0...120).reversed() { path.line(to: point(step, -1)) }
            path.close()
            // Layer the same measured envelope; never add decorative oscillation
            // to a silent or interrupted microphone.
            let opacity = interrupted ? 0.15 : (layer == 0 ? 0.35 : (layer == 1 ? 0.55 : 0.95))
            NSGradient(colors: colors.map { $0.withAlphaComponent(opacity) })?.draw(in: path, angle: 0)
        }
    }
}
