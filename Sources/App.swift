// App.swift: the macOS Service, the floating HUD, and the dictation session loop.
//
// Phaedrus provides the Service "Dictate with Phaedrus". It returns text to the app
// you are typing in, so no Accessibility permission is needed. The service is bound
// to F18, and scripts/mic-key.sh can remap the 🎤 key to F18.
//
// While a session runs:  🎤 / Return / click on the HUD = stop and insert,
//                        Esc = cancel (also while starting),
//                        Command-comma = pause and change settings,
//                        silence for N seconds = stop and insert.
// macOS launches the app on demand; it quits after 15 idle minutes. Launching it
// yourself opens the settings window (SettingsView.swift).

import AppKit
import AVFoundation
import Carbon

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
        let l = d.stringArray(forKey: "locales") ?? ["en_US"]
        return Array((l.isEmpty ? ["en_US"] : l).prefix(maxLanguages))
    }
    static func num(_ k: String, _ def: Double) -> Double { d.object(forKey: k) == nil ? def : d.double(forKey: k) }
    static func flag(_ k: String, _ def: Bool) -> Bool { d.object(forKey: k) == nil ? def : d.bool(forKey: k) }
    static var silence: Double { num("silenceSeconds", 3) }
    static var noSpeech: Double { num("noSpeechSeconds", 10) }
    static var maxSeconds: Double { min(num("maxSeconds", 300), maxDictationSeconds) }
    static var copyToClipboard: Bool { flag("copyToClipboard", true) }
    static var playSounds: Bool { flag("playSounds", true) }
    static var mixLanguages: Bool { flag("mixLanguages", false) }
    static var smartCleanup: Bool { flag("smartCleanup", false) }
    static func sound(_ name: String) { if playSounds { NSSound(named: name)?.play() } }
}

// MARK: - Global keys (registered only during a session; no permission needed)

enum KeyAction: UInt32 { case stop = 1, cancel = 2, settings = 3 }

@MainActor
final class HotKeys {
    private var refs: [EventHotKeyRef] = []
    private static var installed = false
    static var handler: ((KeyAction) -> Void)?

    private static func installOnce() -> Bool {
        guard !installed else { return true }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            if let a = KeyAction(rawValue: id.id) {
                MainActor.assumeIsolated { HotKeys.handler?(a) }   // Carbon delivers on the main thread
            }
            return noErr
        }, 1, &spec, nil, nil)
        installed = status == noErr
        return installed
    }

    func register() -> Bool {
        guard refs.isEmpty else { return true }
        guard HotKeys.installOnce() else { return false }
        let keys: [(Int, UInt32, KeyAction)] = [
            (kVK_F18, 0, .stop), (kVK_Return, 0, .stop), (kVK_ANSI_KeypadEnter, 0, .stop),
            (kVK_Escape, 0, .cancel), (kVK_ANSI_Comma, UInt32(cmdKey), .settings)
        ]
        for (code, modifiers, action) in keys {
            var ref: EventHotKeyRef?
            let st = RegisterEventHotKey(UInt32(code), modifiers, EventHotKeyID(signature: OSType(0x5068_6472 /* "Phdr" */), id: action.rawValue),
                                         GetApplicationEventTarget(), 0, &ref)
            guard st == noErr, let ref else {
                dlog("hotkey registration failed: key=\(code), status=\(st)")
                unregister()
                return false
            }
            refs.append(ref)
        }
        return true
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
    private let makeEngine: @Sendable () -> any DictationRecognizing
    private let pausedDictation = PausedDictationControls()
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
    private var refiningSince: Date?
    private var segmentSeconds = 0.0
    private var segmentCanPause = true

    init(engineFactory: @escaping @Sendable () -> any DictationRecognizing = { DictationEngine() }) {
        makeEngine = engineFactory
        super.init()
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        installMenu()
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

    @objc func showSettings() {
        if busy && !pausedDictation.isPaused {
            if stopRequest == .stop { stopRequest = .settings }
            else { requestStop(.settings) }
            return
        }
        openSettingsWindow()
    }

    private func openSettingsWindow() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindow(pausedDictation: pausedDictation) { [weak self] in
                guard let self else { return }
                self.settingsWindow = nil
                if self.pausedDictation.isPaused && self.pausedDictation.action == nil {
                    self.pausedDictation.action = .resume
                }
                // opened just for the settings: quit when they are closed
                if !self.busy && !self.inServiceCall { NSApp.terminate(nil) }
            }
        }
        settingsWindow?.show()
    }

    private func installMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem(title: "Phaedrus", action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: "Phaedrus")
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Phaedrus", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        appMenu.addItem(quit)
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        windowItem.submenu = windowMenu
        menu.addItem(windowItem)
        NSApp.mainMenu = menu
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
        if busy && pausedDictation.isPaused {
            switch a {
            case .stop: pausedDictation.action = .resume
            case .cancel: pausedDictation.action = .cancel
            case .settings: openSettingsWindow()
            }
            return
        }
        guard busy, stopRequest == nil, !finished else { return }
        // ignore an auto-repeat of the key that started the session
        if a != .settings && Date().timeIntervalSince(sessionStart) < 0.4 { return }
        stopRequest = a
    }

    // MARK: service

    /// No-input/no-output Service: users can assign a separate global shortcut
    /// in macOS, including one that launches Phaedrus when it is not running.
    @objc func openSettings(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        servedRequest = true
        error.pointee = nil
        showSettings()
    }

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

        let target = NSWorkspace.shared.frontmostApplication
        settingsWindow?.close()
        // Pauses don't consume recording time, but the original Service call has
        // a wall-clock deadline. Finish saved text before its caller times out.
        let deadline = Date().addingTimeInterval(Prefs.serviceTimeout - 60)
        var text = ""
        var recordedSeconds = 0.0
        var hasPaused = false
        while Date() < deadline {
            let remaining = Prefs.maxSeconds - recordedSeconds
            guard remaining > 0 else { break }
            let segment = runSegment(maxSeconds: remaining, elapsedBefore: recordedSeconds,
                                     serviceDeadline: deadline, hasPreviousText: !text.isEmpty)
            recordedSeconds += segmentSeconds
            if stopRequest == .cancel { return nil }
            if let segment { text = TranscriptMerger.join(text, segment) }
            guard segmentCanPause else { break }
            guard stopRequest == .settings || (hasPaused && errorText != nil) else { break }
            hasPaused = true
            let action = pauseForSettings(hasText: !text.isEmpty, message: errorText, deadline: deadline)
            if target?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                target?.activate(options: [])
            }
            switch action {
            case .resume: continue
            case .finish: return text.isEmpty ? nil : text
            case .cancel: return nil
            }
        }
        return text.isEmpty ? nil : text
    }

    private func pauseForSettings(hasText: Bool, message: String?, deadline: Date) -> PausedDictationControls.Action {
        keys.unregister()
        pausedDictation.action = nil
        pausedDictation.hasText = hasText
        pausedDictation.message = message
        pausedDictation.deadlineWarning = nil
        pausedDictation.isPaused = true
        hud.show(.paused, "Paused · microphone off")
        openSettingsWindow()
        defer {
            pausedDictation.isPaused = false
            settingsWindow?.close()
            hud.hide()
        }
        while pausedDictation.action == nil && Date() < deadline {
            pump(0.05)
            let seconds = Int(ceil(deadline.timeIntervalSinceNow))
            if seconds <= 60 {
                let warning = "This session will finish in \(max(0, seconds)) seconds."
                if pausedDictation.deadlineWarning != warning { pausedDictation.deadlineWarning = warning }
            }
        }
        return pausedDictation.action ?? .finish
    }

    /// One microphone run. Finalize before opening settings so no speech model
    /// or microphone from the previous language selection keeps recording.
    private func runSegment(maxSeconds: Double, elapsedBefore: Double,
                            serviceDeadline: Date, hasPreviousText: Bool) -> String? {

        sessionID += 1
        let id = sessionID
        sessionStart = Date()
        listening = false
        stopRequest = nil
        finished = false
        resultText = nil
        errorText = nil
        refiningSince = nil
        segmentSeconds = 0
        segmentCanPause = true
        var completionTask: Task<Void, Never>?
        defer { completionTask?.cancel() }

        let engine = makeEngine()
        let abandoned = AtomicFlag()    // set when the session ends before `start` returns
        let startupSettled = AtomicFlag()
        var stopping = false
        var stopRequestedAt = Date()
        var preparingSince: Date?
        var startupCancelledAt: Date?

        // Register every stop/cancel key before starting the microphone.
        guard keys.register() else {
            errorText = "Dictation shortcut unavailable. Check for conflicts."
            Prefs.sound("Basso")
            hud.show(.error, "Dictation shortcut unavailable. Check for conflicts.")
            pump(2.5)
            hud.hide()
            return nil
        }
        hud.show(.preparing, "Starting…")

        let locales = Prefs.locales
        let mixLanguages = Prefs.mixLanguages
        let smartCleanup = Prefs.smartCleanup
        hud.languages(locales)
        let startupTask = Task.detached {
            defer { startupSettled.set() }
            do {
                dlog("starting engine: \(locales.joined(separator: ","))")
                try await engine.start(localeIDs: locales, mixLanguages: mixLanguages, smartCleanup: smartCleanup)
                if abandoned.isSet { await engine.abort(); return }
                let accepted = await withCheckedContinuation { continuation in
                    onMainRunLoop { [weak self] in
                        continuation.resume(returning: self?.didStartListening(id) ?? false)
                    }
                }
                if !accepted { await engine.abort() }
            } catch {
                await engine.abort()
                if abandoned.isSet { return }
                let message = error.localizedDescription
                onMainRunLoop { [weak self] in
                    guard let self, self.sessionID == id, !self.finished else { return }
                    self.errorText = message
                    self.finished = true
                }
            }
        }
        defer { startupTask.cancel() }

        // the caller of the service stops waiting after Prefs.serviceTimeout
        let deadline = min(serviceDeadline, sessionStart.addingTimeInterval(maxSeconds + 120))

        while !finished {
            pump(0.05)
            if finished { break }
            let now = Date()

            if !listening && !stopping {
                // starting: any stop request cancels; watch for downloads and hangs
                if stopRequest != nil {
                    if startupCancelledAt == nil {
                        dlog("cancelled while starting")
                        startupCancelledAt = now
                        abandoned.set()
                        startupTask.cancel()
                    }
                    if stopRequest != .settings || startupSettled.isSet {
                        finished = true
                        break
                    }
                    // Don't announce microphone-off or start a second engine
                    // until the abandoned startup has fully torn down.
                    hud.status("Pausing…")
                    if now.timeIntervalSince(startupCancelledAt!) > 5 {
                        segmentCanPause = false
                        errorText = "Speech is still stopping. Please try again."
                        finished = true
                    }
                    continue
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

            if listening {
                hud.updateAudio(engine.audioActivity, elapsed: elapsedBefore + now.timeIntervalSince(listeningSince))
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
                    stopRequest = hasPreviousText ? .stop : .cancel
                }
                if now.timeIntervalSince(listeningSince) > maxSeconds || now > deadline {
                    dlog("time limit")
                    stopRequest = .stop
                }
            }

            if let req = stopRequest, !stopping {
                dlog("stop request: \(req)")
                stopping = true
                stopRequestedAt = now
                segmentSeconds = now.timeIntervalSince(listeningSince)
                listening = false
                keys.unregister()
                hud.show(.transcribing, req == .cancel ? "Cancelled" : (req == .settings ? "Pausing…" : "Finishing…"))
                completionTask = Task.detached {
                    do {
                        let out = try await engine.stop(cancel: req == .cancel)
                        dlog("stopped: \(out.map { "\($0.text.count) chars, \($0.localeIDs.joined(separator: "+")), confidence \(String(format: "%.2f", $0.confidence))" } ?? "no text")")
                        var text = out?.text
                        if let plan = out?.cleanupPlan, !Task.isCancelled {
                            let ready = await withCheckedContinuation { continuation in
                                onMainRunLoop { [weak self] in
                                    guard let self, self.sessionID == id, !self.finished else {
                                        continuation.resume(returning: false)
                                        return
                                    }
                                    self.resultText = plan.fallback.text
                                    self.refiningSince = Date()
                                    self.hud.status("Refining…")
                                    continuation.resume(returning: true)
                                }
                            }
                            guard ready else { return }
                            text = await SmartCleanup.refine(plan).text
                        }
                        let finalText = text
                        onMainRunLoop { [weak self] in
                            guard let self, self.sessionID == id, !self.finished else { return }
                            self.resultText = finalText
                            self.finished = true
                        }
                    } catch {
                        let message = error.localizedDescription
                        onMainRunLoop { [weak self] in
                            guard let self, self.sessionID == id, !self.finished else { return }
                            self.errorText = message
                            self.finished = true
                        }
                    }
                }
            }

            if let refiningSince {
                // The async deadline normally returns first. Keep the finalized
                // transcript even if a framework/scheduler stalls during cleanup.
                if now.timeIntervalSince(refiningSince) > SmartCleanup.timeoutSeconds + 1 {
                    completionTask?.cancel()
                    finished = true
                }
            } else if stopping && now.timeIntervalSince(stopRequestedAt) > 20 {
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
        if stopRequest != .settings {
            Prefs.sound(stopRequest == .cancel || (resultText == nil && !hasPreviousText) ? "Funk" : "Pop")
        }
        return resultText
    }

    private func didStartListening(_ id: Int) -> Bool {
        guard sessionID == id, !finished, stopRequest == nil else { return false }
        listening = true
        listeningSince = Date()
        dlog("listening")
        Prefs.sound("Tink")
        hud.show(.listening, "Listening")
        return true
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
