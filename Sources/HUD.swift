// A quiet recording surface. While listening, level bars show a short history
// of the real microphone meter. It indicates audio input, not recognition accuracy.

import AppKit
import QuartzCore

@MainActor
final class HUD {
    enum Mode { case preparing, listening, paused, transcribing, error }

    private static let frame = NSRect(x: 0, y: 0, width: 420, height: 124)
    private var panel: NSPanel?
    private let surface: RecordingSurface
    private var animationTimer: Timer?
    // Whether the panel should be on screen. Tracked here rather than read from
    // `isVisible`, which can stay true while WindowServer is not drawing it.
    private var presented = false
    private var shownAt = 0.0
    private var lastCheck = 0.0
    private var rebuilds = 0
    var onClick: (() -> Void)?

    // The optional override lets native previews exercise both accessibility
    // modes even on CI Macs that default to Reduce Motion. The app uses nil.
    init(reduceMotion: Bool? = nil, increaseContrast: Bool? = nil) {
        surface = RecordingSurface(frame: Self.frame)
        surface.reduceMotionOverride = reduceMotion
        surface.increaseContrastOverride = increaseContrast
        surface.onClick = { [weak self] in self?.onClick?() }
    }

    /// A fresh window for every presentation. A long-lived panel can end up in
    /// a state where it is ordered in but WindowServer never puts it on screen
    /// (seen after hours of uptime with several displays); a new window shows.
    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: Self.frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        // Draw the rounded surface and its shadow together. A rectangular window
        // or visual-effect backing must never show outside the rounded silhouette.
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.contentView = surface
        return panel
    }

    private func present() {
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel?.close()
        let panel = makePanel()
        self.panel = panel
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens.first
        if let f = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: f.midX - panel.frame.width / 2, y: f.minY + 78))
        }
        panel.orderFrontRegardless()
        shownAt = CACurrentMediaTime()
        lastCheck = shownAt
    }

    /// Ask WindowServer, not AppKit, whether the panel is actually on screen.
    private var isOnScreen: Bool {
        guard let panel, panel.windowNumber > 0,
              let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(panel.windowNumber))
                as? [[String: Any]],
              let window = info.first else { return false }
        return (window[kCGWindowIsOnscreen as String] as? Bool) ?? false
    }

    /// Called from the animation timer: if the panel has been ordered in for a
    /// moment but is still not on screen, replace it with a new window.
    private func checkOnScreen() {
        let now = CACurrentMediaTime()
        guard presented, rebuilds < 3, now - shownAt > 0.3, now - lastCheck > 0.5 else { return }
        lastCheck = now
        if isOnScreen { return }
        rebuilds += 1
        dlog("hud: panel not on screen, recreating (\(rebuilds))")
        present()
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
        if !presented {
            presented = true
            rebuilds = 0
            present()
        }
        if animationTimer == nil {
            let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.surface.tick()
                    self?.checkOnScreen()
                }
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
        presented = false
        panel?.orderOut(nil)
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
    var reduceMotionOverride: Bool?
    var increaseContrastOverride: Bool?
    private var reduceMotion: Bool {
        reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
    private var increaseContrast: Bool {
        increaseContrastOverride ?? NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }
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
        let reduced = reduceMotion
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
        if mode != .error, let cg = NSGraphicsContext.current?.cgContext { drawBars(cg) }
        NSGraphicsContext.restoreGraphicsState()
        let contrast = increaseContrast
        NSColor.white.withAlphaComponent(contrast ? 0.65 : 0.16).setStroke()
        shape.lineWidth = 1
        shape.stroke()
    }
}

// MARK: - Level bars
//
// One rule set: while listening, marks come only from the
// measured level history; a silent microphone rests flat; an interrupted one
// keeps its frozen history but drops to a dim neutral gray. Only preparing and
// transcribing get decorative motion, and Reduce Motion turns that off and
// replaces the traveling history with a stationary level indicator.

private extension RecordingSurface {
    enum BandState { case live, interrupted, working, paused }

    static let bandLeft = 34.0
    static let bandRight = 386.0
    static let bandCenter = 59.0
    static var bandWidth: Double { bandRight - bandLeft }

    /// sRGB components of PhaedrusTheme.ribbonColors, resolved once.
    static let palette: [SIMD3<Double>] = PhaedrusTheme.ribbonColors.map {
        let c = $0.usingColorSpace(.sRGB) ?? $0
        return SIMD3(Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
    }
    static let neutral: SIMD3<Double> = {
        let c = PhaedrusTheme.panelSecondary.usingColorSpace(.sRGB) ?? PhaedrusTheme.panelSecondary
        return SIMD3(Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
    }()

    var bandState: BandState {
        switch mode {
        case .listening: inputAvailable ? .live : .interrupted
        case .preparing, .transcribing: .working
        case .paused, .error: .paused
        }
    }

    static func paletteColor(_ t: Double) -> SIMD3<Double> {
        let stops = palette
        let x = min(1, max(0, t)) * Double(stops.count - 1)
        let i = min(stops.count - 2, Int(x))
        let f = x - Double(i)
        return stops[i] + (stops[i + 1] - stops[i]) * f
    }

    static func smoothstep(_ x: Double) -> Double {
        let t = min(1, max(0, x))
        return t * t * (3 - 2 * t)
    }

    /// Stationary Reduce Motion shape: tallest in the middle, scaled by level.
    static func bell(_ t: Double) -> Double {
        let s = sin(.pi * min(1, max(0, t)))
        return s * s
    }

    func stroke(_ cg: CGContext, _ rgb: SIMD3<Double>, _ alpha: Double) {
        cg.setStrokeColor(red: rgb.x, green: rgb.y, blue: rgb.z, alpha: min(1, max(0, alpha)))
    }

    /// A soft highlight sweeping across the band, for preparing/transcribing only.
    func sweep(_ t: Double, width: Double) -> Double {
        let head = (phase * 0.45).truncatingRemainder(dividingBy: 1.5) - 0.25
        let d = (t - head) / width
        return exp(-d * d)
    }

    // MARK: Bars — one capsule per meter sample

    func drawBars(_ cg: CGContext) {
        let pitch = 4.0, barWidth = 2.2, maxHalf = 16.0
        let rest = barWidth / 2
        let state = bandState
        let contrast = increaseContrast
        let reduced = reduceMotion
        let traveling = mode == .listening && !reduced
        let count = Int(Self.bandWidth / pitch) + (traveling ? 1 : 0)
        let newest = AudioRibbon.sampleCount - 1
        cg.setLineCap(.round)
        cg.setLineWidth(barWidth)
        for i in 0..<count {
            // Newest at the right; bars glide left by the sub-sample progress so
            // a 30 Hz meter does not visibly step.
            let cx = traveling
                ? Self.bandRight + pitch / 2 - (Double(i) + ribbon.progress) * pitch
                : Self.bandRight - pitch / 2 - Double(i) * pitch
            let t = (cx - Self.bandLeft) / Self.bandWidth
            var amount = 0.0
            if mode == .listening {
                amount = reduced ? ribbon.level * Self.bell(t) : ribbon.sample(newest - i)
            }
            // Old history fades out on the left; a new bar fades in on the right.
            var edge = Self.smoothstep((cx - Self.bandLeft) / 56)
            if traveling { edge *= Self.smoothstep((Self.bandRight + pitch / 2 - cx) / (pitch * 0.6)) }
            if mode != .listening { edge = Self.smoothstep(min(cx - Self.bandLeft, Self.bandRight - cx) / 28) }
            let rgb: SIMD3<Double>
            let alpha: Double
            switch state {
            case .live:
                rgb = Self.paletteColor(t)
                let restAlpha = contrast ? 0.72 : 0.46
                alpha = restAlpha + (1 - restAlpha) * min(1, amount * 5)
            case .interrupted:
                rgb = Self.neutral
                alpha = contrast ? 0.45 : 0.2
            case .working:
                rgb = Self.paletteColor(t)
                let glow = reduced ? 0 : sweep(t, width: 0.12)
                alpha = (contrast ? 0.55 : 0.28) + 0.65 * glow
            case .paused:
                rgb = Self.neutral
                alpha = contrast ? 0.5 : 0.26
            }
            let half = max(rest, amount * maxHalf)
            stroke(cg, rgb, alpha * edge)
            cg.move(to: CGPoint(x: cx, y: Self.bandCenter - half + rest))
            cg.addLine(to: CGPoint(x: cx, y: Self.bandCenter + half - rest + 0.001))
            cg.strokePath()
        }
    }
}
