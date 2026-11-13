// Exercise the real nested Service event loop and settings window with fake
// recognizers. No microphone, model downloads, clipboard or user defaults writes.
import AppKit
import Carbon
import SwiftUI

private final class FakeRecognizer: DictationRecognizing, @unchecked Sendable {
    struct Spec: Sendable {
        var text: String? = "Hello."
        var failStart = false
        var startDelay = 0.0
    }
    private let lock = NSLock()
    private let spec: Spec
    private var _phase = DictationEngine.Phase.permission
    private var _running = false
    private var _started: Date?
    private var _locales: [String] = []
    private var _stops = 0
    private var _aborted = false
    init(_ spec: Spec) { self.spec = spec }
    var phase: DictationEngine.Phase { lock.withLock { _phase } }
    var running: Bool { lock.withLock { _running } }
    var started: Date? { lock.withLock { _started } }
    var locales: [String] { lock.withLock { _locales } }
    var stops: Int { lock.withLock { _stops } }
    var aborted: Bool { lock.withLock { _aborted } }
    var downloadFraction: Double? { nil }
    var lastActivity: Date { spec.text == nil ? (started ?? Date()) : Date() }
    var activityDetail: (text: Date, voice: Date) { (lastActivity, lastActivity) }
    var heardSomething: Bool { spec.text != nil }
    var audioActivity: DictationEngine.AudioActivity { .init(level: 0.4, lastBuffer: running ? Date() : nil) }

    func start(localeIDs: [String], mixLanguages: Bool, smartCleanup: Bool) async throws {
        lock.withLock { _started = Date(); _locales = localeIDs; _phase = .preparing }
        if spec.startDelay > 0 { try await Task.sleep(for: .seconds(spec.startDelay)) }
        try Task.checkCancellation()
        if spec.failStart { throw PhaedrusError("Synthetic resume failure") }
        lock.withLock { _running = true; _phase = .running }
    }
    func stop(cancel: Bool) async throws -> DictationEngine.Outcome? {
        lock.withLock { _running = false; _stops += 1 }
        guard !cancel, let text = spec.text else { return nil }
        return .init(text: text, localeIDs: locales, confidence: 0.95, cleanupPlan: nil)
    }
    func abort() async { lock.withLock { _running = false; _aborted = true } }
}

private final class RecognizerFactory: @unchecked Sendable {
    private let lock = NSLock()
    private let specs: [FakeRecognizer.Spec]
    private var created: [FakeRecognizer] = []
    init(_ specs: [FakeRecognizer.Spec]) { self.specs = specs }
    var engines: [FakeRecognizer] { lock.withLock { created } }
    func make() -> any DictationRecognizing {
        lock.withLock {
            precondition(created.count < specs.count, "Unexpected recognizer restart")
            let engine = FakeRecognizer(specs[created.count])
            created.append(engine)
            return engine
        }
    }
}

@main
@MainActor
enum SessionSettingsTests {
    enum Scenario: CaseIterable { case resume, finish, cancel, failedResume, startupPause, silentResume, timeBudget }
    static var checks = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        precondition(condition(), message)
    }

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        // A real Service can be called from a main-queue block. Dispatching the
        // entire test here catches settings tasks that depend on that blocked queue.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                for scenario in Scenario.allCases { run(scenario) }
                Prefs.d.removeVolatileDomain(forName: "NSArgumentDomain")
                print("Passed \(checks) native session/settings checks")
                exit(0)
            }
        }
        app.run()
    }

    static func run(_ scenario: Scenario) {
        let preferences: [String: Any] = ["locales": ["en_US"], "playSounds": false,
            "smartCleanup": false, "mixLanguages": false, "silenceSeconds": 0.1,
            "noSpeechSeconds": 0.6, "maxSeconds": scenario == .timeBudget ? 1.4 : 30.0]
        Prefs.d.setVolatileDomain(preferences, forName: "NSArgumentDomain")
        var specs = [FakeRecognizer.Spec()]
        if scenario == .startupPause { specs[0].startDelay = 2 }
        if ![.finish, .cancel].contains(scenario) {
            specs.append(.init(text: scenario == .silentResume ? nil : "Olá.", failStart: scenario == .failedResume))
        }
        let factory = RecognizerFactory(specs)
        let controller = Controller(engineFactory: { factory.make() })
        controller.onceMode = true
        NSApp.delegate = controller
        controller.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        let started = Date()
        var stage = 0
        var pausedSince: Date?
        let timer = Timer(timeInterval: 0.03, repeats: true) { _ in
            MainActor.assumeIsolated {
                precondition(Date().timeIntervalSince(started) < 15, "Session/settings test timed out: \(scenario)")
                let engines = factory.engines
                if stage == 0, let first = engines.first,
                   let start = first.started, Date().timeIntervalSince(start) > 0.5 {
                    if scenario == .resume {
                        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                            timestamp: 0, windowNumber: 0, context: nil, characters: ",", charactersIgnoringModifiers: ",",
                            isARepeat: false, keyCode: UInt16(kVK_ANSI_Comma))!
                        expect(NSApp.mainMenu!.performKeyEquivalent(with: event), "Command-comma opens settings")
                    } else {
                        HotKeys.handler?(.settings)
                    }
                    HotKeys.handler?(.settings) // an auto-repeat must not finalize twice
                    stage = 1
                } else if stage == 1,
                          let window = NSApp.windows.first(where: { $0.isVisible && $0.title == "Phaedrus Settings" }),
                          let hosting = window.contentViewController as? NSHostingController<SettingsView> {
                    let controls = hosting.rootView.pausedDictation
                    if pausedSince == nil {
                        pausedSince = Date()
                        expect(controls.isPaused, "Settings show a paused recording")
                        expect(engines.allSatisfy { !$0.running }, "No microphone runs while settings are open")
                        if scenario == .startupPause {
                            expect(engines[0].aborted, "Startup fully aborts before settings open")
                        } else {
                            expect(engines[0].stops == 1, "Finalize the previous segment exactly once")
                        }
                    }
                    // This must complete inside the nested Service loop.
                    guard !hosting.rootView.m.loadingLanguages else { return }
                    if scenario == .resume && CommandLine.arguments.count > 1 {
                        savePreview(window, path: CommandLine.arguments[1])
                    }
                    if scenario == .timeBudget && Date().timeIntervalSince(pausedSince!) < 1.2 { return }
                    switch scenario {
                    case .finish: controls.action = .finish
                    case .cancel: HotKeys.handler?(.cancel)
                    default:
                        var updated = Prefs.d.volatileDomain(forName: "NSArgumentDomain")
                        updated["locales"] = ["pt_BR", "en_US"]
                        Prefs.d.setVolatileDomain(updated, forName: "NSArgumentDomain")
                        window.performClose(nil) // closing settings resumes
                    }
                    stage = 2
                } else if stage == 2, scenario == .failedResume,
                          let window = NSApp.windows.first(where: { $0.isVisible && $0.title == "Phaedrus Settings" }),
                          let hosting = window.contentViewController as? NSHostingController<SettingsView>,
                          hosting.rootView.pausedDictation.message != nil {
                    expect(hosting.rootView.pausedDictation.hasText, "A failed resume preserves saved words")
                    hosting.rootView.pausedDictation.action = .finish
                    stage = 3
                } else if stage == 2, engines.count == 2, let start = engines[1].started,
                          engines[1].running, Date().timeIntervalSince(start) > 0.5,
                          scenario != .silentResume && scenario != .timeBudget {
                    HotKeys.handler?(.stop)
                    stage = 3
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        let result = controller.runSession()
        timer.invalidate()
        let expected: String? = switch scenario {
        case .cancel: nil
        case .finish, .failedResume, .silentResume: "Hello."
        case .startupPause: "Olá."
        case .resume, .timeBudget: "Hello. Olá."
        }
        expect(result == expected, "Preserve/finish/cancel the entire draft correctly: \(scenario)")
        expect(factory.engines.allSatisfy { !$0.running }, "Every microphone is stopped after a session")
        if factory.engines.count == 2 {
            expect(factory.engines[1].locales == ["pt_BR", "en_US"], "Resume reads the new language selection")
        }
        expect(!NSApp.windows.contains { $0.isVisible && $0.title == "Phaedrus Settings" }, "Close paused settings on exit")
    }

    static func savePreview(_ window: NSWindow, path: String) {
        guard let view = window.contentView else { preconditionFailure("Settings view missing") }
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            preconditionFailure("Could not render paused settings")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            preconditionFailure("Could not encode paused settings")
        }
        let url = URL(fileURLWithPath: path)
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! data.write(to: url)
    }
}
