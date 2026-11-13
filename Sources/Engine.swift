// Engine.swift: on-device transcription with optional mixed-language fusion.
//
// One SpeechAnalyzer runs one SpeechTranscriber per configured language on the
// same microphone audio. When recording stops, the language whose words have the
// highest mean confidence is the baseline. Experimental mixing can replace
// aligned spans using other languages' finalized words. Everything runs locally.
//
// Threading: `start`, `stop` and `abort` are never called concurrently. The
// Controller only calls `stop` after `start` returned, and only calls `abort`
// from the task that ran `start`. State shared with the audio tap and the
// result readers is guarded by `lock`.

import AVFoundation
import CoreMedia
import Foundation
import Speech

struct PhaedrusError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

/// Allows the session controller to be exercised without a microphone or models.
protocol DictationRecognizing: AnyObject, Sendable {
    var phase: DictationEngine.Phase { get }
    var downloadFraction: Double? { get }
    var lastActivity: Date { get }
    var activityDetail: (text: Date, voice: Date) { get }
    var heardSomething: Bool { get }
    var audioActivity: DictationEngine.AudioActivity { get }
    func start(localeIDs: [String], mixLanguages: Bool, smartCleanup: Bool) async throws
    func stop(cancel: Bool) async throws -> DictationEngine.Outcome?
    func abort() async
}

final class DictationEngine: DictationRecognizing, @unchecked Sendable {
    struct Outcome: Sendable {
        let text: String
        let localeIDs: [String]
        let confidence: Double
        let cleanupPlan: CleanupPlan?
    }
    struct AudioActivity { let level: Double; let lastBuffer: Date? }

    /// What `start` is currently doing (shown in the HUD; used by the startup watchdog).
    enum Phase { case permission, download, preparing, running }

    /// One language. Its mutable fields are only touched while holding the engine's `lock`.
    private final class Track: @unchecked Sendable {
        let locale: Locale
        let module: SpeechTranscriber
        var finalText = ""
        var volatileText = ""
        var confSum = 0.0, confCount = 0           // finalized words
        var volConfSum = 0.0, volConfCount = 0     // current volatile words
        var lastUpdate = Date.distantPast
        var finalWords: [TranscriptMerger.Word] = []
        var timingComplete = true
        var readerFailed = false
        var reader: Task<Void, Error>?

        init(locale: Locale) {
            self.locale = locale
            module = SpeechTranscriber(
                locale: locale,
                transcriptionOptions: [],
                reportingOptions: [.volatileResults],
                attributeOptions: [.transcriptionConfidence, .audioTimeRange])
        }

        /// Mean word confidence over finalized and volatile words.
        var confidence: Double {
            let n = confCount + volConfCount
            return n > 0 ? (confSum + volConfSum) / Double(n) : 0
        }
        var text: String { finalText + volatileText }
    }

    private let lock = NSLock()
    private var tracks: [Track] = []
    private var analyzer: SpeechAnalyzer?
    private var audioEngine: AVAudioEngine?
    private var feed: AsyncStream<AnalyzerInput>.Continuation?

    // guarded by `lock`
    private var _phase = Phase.permission
    private var _download: Progress?
    private var _lastActivity = Date()
    private var _lastText = Date()
    private var _lastVoice = Date()
    private var _heardSomething = false
    private var noiseFloorDB: Float?
    private var _audioLevel = 0.0
    private var _lastAudioBuffer: Date?
    private var mixLanguages = false
    private var smartCleanup = false

    var phase: Phase { lock.withLock { _phase } }
    /// Fraction of the model download, while `phase == .download`.
    var downloadFraction: Double? { lock.withLock { _download?.fractionCompleted } }
    /// Last time speech was heard (audio level) or new text arrived.
    var lastActivity: Date { lock.withLock { _lastActivity } }
    /// For debug logs: (last text result, last loud audio).
    var activityDetail: (text: Date, voice: Date) { lock.withLock { (_lastText, _lastVoice) } }
    /// True once any text has been recognized.
    var heardSomething: Bool { lock.withLock { _heardSomething } }
    var audioActivity: AudioActivity {
        lock.withLock { AudioActivity(level: _audioLevel, lastBuffer: _lastAudioBuffer) }
    }

    // MARK: start

    func start(localeIDs: [String], mixLanguages: Bool = false, smartCleanup: Bool = false) async throws {
        try Task.checkCancellation()
        self.mixLanguages = mixLanguages
        self.smartCleanup = smartCleanup
        guard SpeechTranscriber.isAvailable else { throw PhaedrusError("On-device speech is not available on this Mac") }
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            throw PhaedrusError("Microphone access denied. Allow it in System Settings → Privacy & Security → Microphone")
        }
        try Task.checkCancellation()

        var locales: [Locale] = []
        for id in localeIDs {
            guard let l = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: id)) else {
                throw PhaedrusError("Language \(id) is not supported for on-device dictation")
            }
            if !locales.contains(l) { locales.append(l) }
        }
        guard !locales.isEmpty else { throw PhaedrusError("No languages selected") }
        try Task.checkCancellation()

        let tracks = locales.map(Track.init)
        let modules = tracks.map(\.module)
        lock.withLock {
            self.tracks = tracks
            _lastActivity = Date(); _lastText = Date(); _lastVoice = Date()
            _heardSomething = false
            noiseFloorDB = nil
            _audioLevel = 0
            _lastAudioBuffer = nil
        }

        let installed = Set(await SpeechTranscriber.installedLocales.map(\.identifier))
        if !locales.allSatisfy({ installed.contains($0.identifier) }),
           let req = try await AssetInventory.assetInstallationRequest(supporting: modules) {
            lock.withLock { _phase = .download; _download = req.progress }
            dlog("downloading speech models")
            try await req.downloadAndInstall()
            lock.withLock { _download = nil }
        }
        try Task.checkCancellation()
        lock.withLock { _phase = .preparing }

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules) else {
            throw PhaedrusError("No compatible audio format")
        }
        let analyzer = SpeechAnalyzer(modules: modules)
        self.analyzer = analyzer
        try await analyzer.prepareToAnalyze(in: format)
        try Task.checkCancellation()

        for t in tracks {
            t.reader = Task { [weak self] in
                for try await r in t.module.results { self?.handle(r, t) }
            }
        }

        let (stream, feed) = AsyncStream<AnalyzerInput>.makeStream()
        self.feed = feed
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let micFormat = input.outputFormat(forBus: 0)
        guard micFormat.sampleRate > 0 else { throw PhaedrusError("No microphone input available") }
        guard let converter = AVAudioConverter(from: micFormat, to: format) else {
            throw PhaedrusError("Cannot convert microphone audio")
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: micFormat) { [weak self] buf, _ in
            self?.measureVoice(buf)
            let cap = AVAudioFrameCount(Double(buf.frameLength) * format.sampleRate / micFormat.sampleRate) + 1024
            guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: cap) else { return }
            // convert(to:error:withInputFrom:) calls the input block synchronously on this thread
            nonisolated(unsafe) var fed = false
            nonisolated(unsafe) let input = buf
            var err: NSError?
            converter.convert(to: out, error: &err) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return input
            }
            if out.frameLength > 0 { feed.yield(AnalyzerInput(buffer: out)) }
        }
        self.audioEngine = engine

        try await analyzer.start(inputSequence: stream)
        try Task.checkCancellation()
        try engine.start()
        lock.withLock { _phase = .running }
    }

    // MARK: voice activity (audio level vs. an adaptive noise floor)

    private func measureVoice(_ buf: AVAudioPCMBuffer) {
        guard let ch = buf.floatChannelData?[0], buf.frameLength > 0 else { return }
        let n = Int(buf.frameLength)
        var sum: Float = 0
        for i in 0..<n { sum += ch[i] * ch[i] }
        let db = 10 * log10(max(sum / Float(n), 1e-10))
        lock.withLock {
            // The floor starts at the first buffer's level, drops immediately to quieter
            // levels, and rises slowly (~1.2 dB/s at 4096-frame buffers) to absorb steady noise.
            var floor = noiseFloorDB ?? db
            floor = db < floor ? db : floor + 0.1
            noiseFloorDB = floor
            _lastAudioBuffer = Date()
            // Meter the microphone independently of text results. A quiet input
            // stays calm; actual voice energy expands the ribbon smoothly.
            let relative = max(0, (db - max(-60, floor + 3)) / 30)
            let absolute = max(0, (db + 60) / 45) * 0.25
            _audioLevel = Double(min(1, max(relative, absolute)))
            if db > floor + 10 && db > -55 {
                _lastVoice = Date()
                _lastActivity = Date()
            }
        }
    }

    // MARK: results

    private func handle(_ r: SpeechTranscriber.Result, _ t: Track) {
        let s = String(r.text.characters)
        var sum = 0.0, count = 0
        for run in r.text.runs {
            if let c = run.transcriptionConfidence { sum += c; count += 1 }
        }
        let words = r.isFinal && (mixLanguages || smartCleanup) ? Self.timedWords(r.text) : nil
        lock.withLock {
            if r.isFinal {
                t.finalText += s
                t.volatileText = ""
                t.confSum += sum; t.confCount += count
                t.volConfSum = 0; t.volConfCount = 0
                if mixLanguages || smartCleanup {
                    if let words { t.finalWords.append(contentsOf: words) }
                    else { t.timingComplete = false }
                }
            } else {
                t.volatileText = s
                t.volConfSum = sum; t.volConfCount = count
            }
            t.lastUpdate = Date()
            if !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                _lastText = Date()
                _lastActivity = Date()
                _heardSomething = true
            }
        }
        dlog("result \(t.locale.identifier) final=\(r.isFinal) chars=\(s.count)")
    }

    /// Preserve every character, including whitespace and punctuation runs that
    /// have no timing of their own. Missing timing/confidence on spoken text makes
    /// this track unsuitable for fusion; its ordinary transcript still works.
    private static func timedWords(_ text: AttributedString) -> [TranscriptMerger.Word]? {
        var words: [TranscriptMerger.Word] = []
        var prefix = ""
        for run in text.runs {
            let fragment = String(text[run.range].characters)
            let hasWord = fragment.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
            guard hasWord else {
                if words.isEmpty { prefix += fragment }
                else { words[words.count - 1].text += fragment }
                continue
            }
            guard let range = run.audioTimeRange, let confidence = run.transcriptionConfidence else { return nil }
            let start = CMTimeGetSeconds(range.start)
            let end = CMTimeGetSeconds(CMTimeRangeGetEnd(range))
            guard start.isFinite, end.isFinite, end > start, confidence.isFinite else { return nil }
            words.append(.init(text: prefix + fragment, start: start, end: end, confidence: confidence))
            prefix = ""
        }
        // A punctuation-only final result can be preserved by the fallback, but
        // must not silently disappear from a fused transcript.
        return prefix.isEmpty ? words : nil
    }

    /// The language currently winning. Caller must hold `lock`.
    private func leader() -> Track? {
        tracks.filter { !$0.readerFailed && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.max { a, b in
            a.confidence != b.confidence ? a.confidence < b.confidence : a.lastUpdate < b.lastUpdate
        }
    }

    // MARK: stop

    private func stopAudio() {
        if let e = audioEngine {
            e.stop()
            e.inputNode.removeTap(onBus: 0)
        }
        audioEngine = nil
        feed?.finish()
        feed = nil
    }

    /// Stops recording. Returns nil when cancelled or nothing was recognized.
    func stop(cancel: Bool) async throws -> Outcome? {
        stopAudio()
        guard let analyzer else { return nil }
        self.analyzer = nil
        let tracks = lock.withLock { self.tracks }

        if cancel {
            await analyzer.cancelAndFinishNow()
            tracks.forEach { $0.reader?.cancel() }
            return nil
        }
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        var readerError: Error?
        for t in tracks {
            do { try await t.reader?.value }
            catch {
                readerError = error
                lock.withLock { t.readerFailed = true }
            }
        }
        if let readerError, lock.withLock({ tracks.allSatisfy(\.readerFailed) }) { throw readerError }

        let snapshot = lock.withLock { () -> (TranscriptMerger.Transcript, [TranscriptMerger.Transcript], Double)? in
            guard let best = leader() else { return nil }
            func transcript(_ track: Track) -> TranscriptMerger.Transcript {
                .init(localeID: track.locale.identifier, text: track.text,
                      words: track.timingComplete && track.volatileText.isEmpty ? track.finalWords : [])
            }
            let alternatives = mixLanguages ? tracks.filter {
                $0 !== best && !$0.readerFailed && $0.timingComplete && $0.volatileText.isEmpty
            }.map(transcript) : []
            return (transcript(best), alternatives, best.confidence)
        }
        guard let (primary, alternatives, confidence) = snapshot else { return nil }
        let merged = TranscriptMerger.merge(primary: primary, alternatives: alternatives)
        guard !merged.text.isEmpty else { return nil }
        // Include the primary recognizer too: a contextual choice can undo an
        // uncertain heuristic substitution. Mixing off permits punctuation only.
        let plan = smartCleanup ? CleanupPlan.make(fallback: merged,
            alternatives: mixLanguages ? [primary] + alternatives : [],
            localeIDs: mixLanguages ? tracks.map { $0.locale.identifier } : merged.localeIDs) : nil
        return Outcome(text: merged.text, localeIDs: merged.localeIDs, confidence: confidence, cleanupPlan: plan)
    }

    /// Tears everything down (start failed half-way, or the session was abandoned).
    func abort() async {
        stopAudio()
        if let a = analyzer { await a.cancelAndFinishNow() }
        analyzer = nil
        lock.withLock { tracks }.forEach { $0.reader?.cancel() }
    }
}
