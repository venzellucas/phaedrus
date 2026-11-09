// App.swift: the macOS Service, the floating HUD, and the dictation session loop.
//
// Phaedrus provides the Service "Dictate with Phaedrus". It returns text to the app
// you are typing in, so no Accessibility permission is needed. The service is bound
// to F18, and scripts/mic-key.sh can remap the 🎤 key to F18.
//
// While a session runs:  🎤 / Return / click on the HUD = stop and insert,
//                        Esc = cancel (also while starting),
//                        silence for N seconds = stop and insert.
// macOS launches the app on demand; it quits after 15 idle minutes. Launching it
// yourself opens the settings window (SettingsView.swift).

import AppKit
import AVFoundation
import Carbon
import QuartzCore

/// Debug log to stderr, enabled with PHAEDRUS_DEBUG=1. Never pass transcript text to it.
func dlog(_ message: @autoclosure () -> String) {
    guard ProcessInfo.processInfo.environment["PHAEDRUS_DEBUG"] != nil else { return }
    FileHandle.standardError.write(Data("[\(String(format: "%.3f", Date().timeIntervalSince1970))] \(message())\n".utf8))
}

/// Runs `body` on the main thread through the main run loop, not the main dispatch queue.
/// A session runs a nested event loop, and when that loop itself runs inside a main-queue
/// block, libdispatch will not drain the main queue again. Run-loop blocks still fire.
func onMainRunLoop(_ body: @escaping @MainActor @Sendable () -> Void) {
    RunLoop.main.perform(inModes: [.default, .common]) { MainActor.assumeIsolated { body() } }
    CFRunLoopWakeUp(CFRunLoopGetMain())
}

/// A thread-safe boolean.
final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

// MARK: - Settings

enum Prefs {
    static var d: UserDefaults { .standard }
    static let maxLanguages = 3
    static let maxDictationSeconds: Double = 15 * 60
    /// Must match NSTimeout (milliseconds) in Info.plist.
    static let serviceTimeout: TimeInterval = 20 * 60
    static let idleQuitSeconds: TimeInterval = 15 * 60

    static var locales: [String] {
        let l = d.stringArray(forKey: "locales") ?? ["pt_BR", "en_US"]
        return Array((l.isEmpty ? ["en_US"] : l).prefix(maxLanguages))
    }
    static func num(_ k: String, _ def: Double) -> Double { d.object(forKey: k) == nil ? def : d.double(forKey: k) }
    static func flag(_ k: String, _ def: Bool) -> Bool { d.object(forKey: k) == nil ? def : d.bool(forKey: k) }
    static var silence: Double { num("silenceSeconds", 3) }
    static var noSpeech: Double { num("noSpeechSeconds", 10) }
    static var maxSeconds: Double { min(num("maxSeconds", 300), maxDictationSeconds) }
    static var copyToClipboard: Bool { flag("copyToClipboard", true) }
    static var playSounds: Bool { flag("playSounds", true) }
    static func sound(_ name: String) { if playSounds { NSSound(named: name)?.play() } }
}

// MARK: - HUD

@MainActor
final class HUD {
    enum Mode { case preparing, listening, transcribing, error }

    private let panel: NSPanel
    private let dot = CALayer()
    private let label = NSTextField(labelWithString: "")
    var onClick: (() -> Void)?

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 48),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false

        let bg = NSVisualEffectView(frame: panel.contentRect(forFrameRect: panel.frame))
        bg.material = .hudWindow
        bg.state = .active
        bg.blendingMode = .behindWindow
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 24
        bg.layer?.masksToBounds = true
        panel.contentView = bg

        dot.bounds = CGRect(x: 0, y: 0, width: 14, height: 14)
        dot.position = CGPoint(x: 26, y: 24)
        dot.cornerRadius = 7
        bg.layer?.addSublayer(dot)

        label.frame = NSRect(x: 46, y: 14, width: 360, height: 20)
        label.font = .systemFont(ofSize: 14)
        label.textColor = .labelColor
        label.maximumNumberOfLines = 1
        bg.addSubview(label)

        bg.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(clicked)))
    }

    @objc private func clicked() { onClick?() }

    func show(_ mode: Mode, _ text: String) {
        label.stringValue = text
        // the live preview keeps its newest words visible; status and errors keep their start
        label.lineBreakMode = mode == .listening ? .byTruncatingHead : .byTruncatingTail
        dot.removeAllAnimations()
        switch mode {
        case .preparing: dot.backgroundColor = NSColor.systemGray.cgColor
        case .transcribing: dot.backgroundColor = NSColor.systemOrange.cgColor
        case .error: dot.backgroundColor = NSColor.systemYellow.cgColor
        case .listening:
            dot.backgroundColor = NSColor.systemRed.cgColor
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 0.8; scale.toValue = 1.35
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1.0; fade.toValue = 0.45
            let g = CAAnimationGroup()
            g.animations = [scale, fade]
            g.duration = 0.7
            g.autoreverses = true
            g.repeatCount = .infinity
            g.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            dot.add(g, forKey: "pulse")
        }
        if !panel.isVisible {
            let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
            if let f = screen?.visibleFrame {
                panel.setFrameOrigin(NSPoint(x: f.midX - panel.frame.width / 2, y: f.minY + 90))
            }
            panel.orderFrontRegardless()
        }
    }

    /// Updates the text only (keeps the current mode).
    func status(_ text: String) { label.stringValue = text }

    func preview(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        label.stringValue = t.isEmpty ? "Listening…" : t
    }

    func hide() { panel.orderOut(nil) }
}

// MARK: - Global keys (registered only during a session; no permission needed)

enum KeyAction: UInt32 { case stop = 1, cancel = 2 }

@MainActor
final class HotKeys {
    private var refs: [EventHotKeyRef] = []
    private static var installed = false
    static var handler: ((KeyAction) -> Void)?

    private static func installOnce() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            if let a = KeyAction(rawValue: id.id) {
                MainActor.assumeIsolated { HotKeys.handler?(a) }   // Carbon delivers on the main thread
            }
            return noErr
        }, 1, &spec, nil, nil)
    }

    func register() {
        guard refs.isEmpty else { return }
        HotKeys.installOnce()
        let keys: [(Int, KeyAction)] = [(kVK_F18, .stop), (kVK_Return, .stop), (kVK_ANSI_KeypadEnter, .stop), (kVK_Escape, .cancel)]
        for (code, action) in keys {
            var ref: EventHotKeyRef?
            let st = RegisterEventHotKey(UInt32(code), 0, EventHotKeyID(signature: OSType(0x5068_6472 /* "Phdr" */), id: action.rawValue),
                                         GetApplicationEventTarget(), 0, &ref)
            if st == noErr, let ref { refs.append(ref) }
        }
    }

    func unregister() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
    }
}

// MARK: - Controller

@MainActor
final class Controller: NSObject, NSApplicationDelegate {
    private let hud = HUD()
    private let keys = HotKeys()
    private var busy = false
    private var inServiceCall = false
    private var idleTimer: Timer?
    private var settingsWindow: SettingsWindow?
    private var settingsAutoOpenedAt: Date?
    private var servedRequest = false
    var onceMode = false

    // per-session state, main thread only
    private var sessionID = 0
    private var sessionStart = Date()
    private var listening = false
    private var listeningSince = Date()
    private var stopRequest: KeyAction?
    private var finished = false
    private var resultText: String?
    private var errorText: String?

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        HotKeys.handler = { [weak self] a in self?.requestStop(a) }
        hud.onClick = { [weak self] in self?.requestStop(.stop) }
        scheduleIdleQuit()

        // Opened by the user rather than by a dictation request? Show the settings.
        if CommandLine.arguments.contains("--settings") {
            showSettings()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self, !self.busy, !self.onceMode, !self.servedRequest else { return }
                self.settingsAutoOpenedAt = Date()
                self.showSettings()
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    func showSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindow { [weak self] in
                guard let self else { return }
                self.settingsWindow = nil
                // opened just for the settings: quit when they are closed
                if !self.busy && !self.inServiceCall { NSApp.terminate(nil) }
            }
        }
        settingsWindow?.show()
    }

    private func scheduleIdleQuit() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: Prefs.idleQuitSeconds, repeats: false) { _ in
            MainActor.assumeIsolated {
                if self.settingsWindow != nil || self.busy { self.scheduleIdleQuit() } else { NSApp.terminate(nil) }
            }
        }
    }

    private func requestStop(_ a: KeyAction) {
        guard busy, stopRequest == nil, !finished else { return }
        // ignore an auto-repeat of the key that started the session
        if Date().timeIntervalSince(sessionStart) < 0.4 { return }
        stopRequest = a
    }

    // MARK: service

    /// The service entry point (NSMessage "dictate" in Info.plist).
    @objc func dictate(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        servedRequest = true
        inServiceCall = true
        defer { inServiceCall = false }
        // a cold launch by the service can be slow; close settings we opened by mistake
        if let t = settingsAutoOpenedAt, Date().timeIntervalSince(t) < 5 { settingsWindow?.close() }

        if busy {   // invoked again while running = "stop"
            requestStop(.stop)
            error.pointee = "Dictation already running" as NSString
            return
        }
        guard let text = runSession() else {
            error.pointee = "No text" as NSString
            return
        }
        pboard.clearContents()
        pboard.setString(text, forType: .string)
        if Prefs.copyToClipboard {
            let general = NSPasteboard.general
            general.prepareForNewContents(with: .currentHostOnly)   // not to other devices via Universal Clipboard
            general.setString(text, forType: .string)
        }
    }

    /// Terminal test mode (`--once`): one dictation, transcript to stdout, then exit.
    @objc func runOnce() {
        let t = runSession()
        print(t ?? "(nothing)")
        exit(t == nil ? 1 : 0)
    }

    // MARK: session

    /// Runs one dictation, pumping events until it finishes. Returns the text, or nil.
    func runSession() -> String? {
        busy = true
        idleTimer?.invalidate()
        defer { busy = false; scheduleIdleQuit() }

        sessionID += 1
        let id = sessionID
        sessionStart = Date()
        listening = false
        stopRequest = nil
        finished = false
        resultText = nil
        errorText = nil

        let engine = DictationEngine()
        let abandoned = AtomicFlag()    // set when the session ends before `start` returns
        var stopping = false
        var stopRequestedAt = Date()
        var preparingSince: Date?

        keys.register()                 // Esc works while starting, too
        hud.show(.preparing, "Starting…")
        engine.onPreview = { t in
            onMainRunLoop { [weak self] in
                if let self, self.sessionID == id, self.listening { self.hud.preview(t) }
            }
        }

        let locales = Prefs.locales
        Task.detached {
            do {
                dlog("starting engine: \(locales.joined(separator: ","))")
                try await engine.start(localeIDs: locales)
                if abandoned.isSet { await engine.abort(); return }
                dlog("listening")
                onMainRunLoop { [weak self] in self?.didStartListening(id, engine) }
            } catch {
                await engine.abort()
                if abandoned.isSet { return }
                let message = error.localizedDescription
                onMainRunLoop { [weak self] in
                    guard let self, self.sessionID == id else { return }
                    self.errorText = message
                    self.finished = true
                }
            }
        }

        // the caller of the service stops waiting after Prefs.serviceTimeout
        let deadline = sessionStart.addingTimeInterval(min(Prefs.serviceTimeout - 60, Prefs.maxSeconds + 120))

        while !finished {
            pump(0.05)
            let now = Date()

            if !listening && !stopping {
                // starting: any stop request cancels; watch for downloads and hangs
                if stopRequest != nil {
                    dlog("cancelled while starting")
                    abandoned.set()
                    finished = true
                    break
                }
                switch engine.phase {
                case .download:
                    let pct = Int((engine.downloadFraction ?? 0) * 100)
                    hud.status("Downloading speech model… \(pct)%")
                case .preparing:
                    if preparingSince == nil { preparingSince = now }
                    if now.timeIntervalSince(preparingSince!) > 30 {
                        abandoned.set()
                        errorText = "The speech engine did not start. Please try again."
                    }
                default:
                    break
                }
                if now > deadline {
                    abandoned.set()
                    errorText = "Starting took too long. Please try again."
                }
                if errorText != nil { finished = true }
                continue
            }

            if listening && stopRequest == nil {
                let quiet = now.timeIntervalSince(engine.lastActivity)
                if engine.heardSomething {
                    if quiet > Prefs.silence {
                        let a = engine.activityDetail
                        dlog(String(format: "silence stop: text %.1fs ago, voice %.1fs ago",
                                    now.timeIntervalSince(a.text), now.timeIntervalSince(a.voice)))
                        stopRequest = .stop
                    }
                } else if now.timeIntervalSince(listeningSince) > Prefs.noSpeech && quiet > Prefs.silence {
                    dlog("nothing heard")
                    stopRequest = .cancel
                }
                if now.timeIntervalSince(listeningSince) > Prefs.maxSeconds || now > deadline {
                    dlog("time limit")
                    stopRequest = .stop
                }
            }

            if let req = stopRequest, !stopping {
                dlog("stop request: \(req)")
                stopping = true
                stopRequestedAt = now
                listening = false
                keys.unregister()
                hud.show(.transcribing, req == .cancel ? "Cancelled" : "Transcribing…")
                Task.detached {
                    do {
                        let out = try await engine.stop(cancel: req == .cancel)
                        dlog("stopped: \(out.map { "\($0.text.count) chars, \($0.locale.identifier), confidence \(String(format: "%.2f", $0.confidence))" } ?? "no text")")
                        let text = out?.text
                        onMainRunLoop { [weak self] in
                            guard let self, self.sessionID == id else { return }
                            self.resultText = text
                            self.finished = true
                        }
                    } catch {
                        let message = error.localizedDescription
                        onMainRunLoop { [weak self] in
                            guard let self, self.sessionID == id else { return }
                            self.errorText = message
                            self.finished = true
                        }
                    }
                }
            }

            if stopping && now.timeIntervalSince(stopRequestedAt) > 20 {
                errorText = "Transcription did not finish. Please try again."
                finished = true
            }
        }

        keys.unregister()
        if let e = errorText {
            Prefs.sound("Basso")
            hud.show(.error, e)
            pump(2.5)
            hud.hide()
            return nil
        }
        hud.hide()
        Prefs.sound(resultText == nil ? "Funk" : "Pop")
        return resultText
    }

    private func didStartListening(_ id: Int, _ engine: DictationEngine) {
        guard sessionID == id, !finished else {
            Task.detached { await engine.abort() }   // the session ended while the engine was starting
            return
        }
        listening = true
        listeningSince = Date()
        Prefs.sound("Tink")
        hud.show(.listening, "Listening…")
    }

    private func pump(_ seconds: TimeInterval) {
        let until = Date(timeIntervalSinceNow: seconds)
        while Date() < until {
            if let ev = NSApp.nextEvent(matching: .any, until: until, inMode: .default, dequeue: true) {
                NSApp.sendEvent(ev)
            }
        }
    }
}
