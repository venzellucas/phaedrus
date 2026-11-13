// Conservative, opt-in fusion of time-aligned transcripts. Confidence values from
// different language models are only a heuristic, not calibrated probabilities.
// Keep the primary transcript unless a complete alternative span aligns and wins
// by a margin. No translation, rewriting, or invented words.

import Foundation

enum TranscriptMerger {
    struct Word: Sendable {
        var text: String
        let start: Double
        let end: Double
        let confidence: Double
    }

    struct Transcript: Sendable {
        let localeID: String
        let text: String
        let words: [Word]
    }

    struct Token: Sendable {
        let word: Word
        let localeID: String
    }

    struct Result: Sendable {
        let text: String
        let localeIDs: [String]
        let tokens: [Token]

        init(text: String, localeIDs: [String], tokens: [Token] = []) {
            self.text = text; self.localeIDs = localeIDs; self.tokens = tokens
        }
    }

    struct Candidate: Sendable {
        let range: Range<Int>
        let localeID: String
        let words: [Word]
        let confidence: Double
        let originalConfidence: Double
        let duration: Double
    }

    /// `primary` is the existing whole-recording winner. All words must be final.
    static func merge(primary: Transcript, alternatives: [Transcript]) -> Result {
        let usable = isUsable(primary)
        let fallback = Result(text: primary.text.trimmingCharacters(in: .whitespacesAndNewlines),
                              localeIDs: [primary.localeID],
                              tokens: usable ? primary.words.map { Token(word: $0, localeID: primary.localeID) } : [])
        guard usable else { return fallback }
        let tracks = alternatives.filter { $0.localeID != primary.localeID && isUsable($0) }
        guard !tracks.isEmpty else { return fallback }
        let base = primary.words
        let n = base.count
        var scores = [Double](repeating: 0, count: n + 1)
        var choices = [Candidate?](repeating: nil, count: n)

        for i in (0..<n).reversed() {
            scores[i] = scores[i + 1]
            for candidate in candidates(at: i, in: base, alternatives: tracks) {
                guard candidate.confidence >= 0.72 else { continue }
                // Margin plus a switching cost favors coherent phrases and
                // keeps near-ties in the primary language.
                let gain = (candidate.confidence - candidate.originalConfidence - 0.08) * candidate.duration - 0.06
                let end = candidate.range.upperBound
                guard gain > 0, gain + scores[end] > scores[i] + 0.000001 else { continue }
                scores[i] = gain + scores[end]
                choices[i] = candidate
            }
        }

        var tokens: [Token] = []
        var i = 0
        while i < n {
            if let choice = choices[i] {
                tokens += choice.words.map { Token(word: $0, localeID: choice.localeID) }
                i = choice.range.upperBound
            } else {
                tokens.append(Token(word: base[i], localeID: primary.localeID))
                i += 1
            }
        }
        return render(tokens) ?? fallback
    }

    /// Shared audio-alignment rules for the heuristic merger and model choices.
    /// Callers must validate the baseline and alternative tracks first.
    static func candidates(at i: Int, in base: [Word], alternatives: [Transcript]) -> [Candidate] {
        var matches: [Candidate] = []
        for track in alternatives {
            let words = track.words
            var k = lowerBound(words, start: base[i].start - 0.12)
            while k < words.count && words[k].start <= base[i].start + 0.12 {
                for j in (i + 1)...min(i + 8, base.count) {
                    for l in (k + 1)...min(k + 8, words.count) {
                        if words[l - 1].end > base[j - 1].end + 0.12 { break }
                        let original = base[i..<j]
                        let candidate = words[k..<l]
                        guard aligned(original, candidate),
                              i == 0 || words[k].start >= base[i - 1].end - 0.025,
                              j == base.count || words[l - 1].end <= base[j].start + 0.025,
                              candidate.allSatisfy({ $0.confidence >= 0.5 }) else { continue }
                        matches.append(Candidate(range: i..<j, localeID: track.localeID,
                                                 words: Array(candidate), confidence: mean(candidate),
                                                 originalConfidence: mean(original),
                                                 duration: original.reduce(0) { $0 + $1.end - $1.start }))
                    }
                }
                k += 1
            }
        }
        return matches
    }

    /// Reconstruct only supplied tokens, preserving language seams and rejecting
    /// independent substitutions that repeat audio. No generated prose is used.
    static func render(_ tokens: [Token]) -> Result? {
        var text = ""
        var fragment = ""
        var locales: [String] = []
        var previousLocale: String?
        var previousEnd = -Double.infinity
        for token in tokens {
            guard token.word.start >= previousEnd - 0.025 else { return nil }
            if let previousLocale, previousLocale != token.localeID {
                text = text.isEmpty ? fragment : join(text, fragment)
                fragment = ""
            }
            fragment += token.word.text
            if !locales.contains(token.localeID) { locales.append(token.localeID) }
            previousLocale = token.localeID
            previousEnd = token.word.end
        }
        text = text.isEmpty ? fragment : join(text, fragment)
        return Result(text: text.trimmingCharacters(in: .whitespacesAndNewlines), localeIDs: locales, tokens: tokens)
    }

    static func isUsable(_ t: Transcript) -> Bool {
        guard !t.words.isEmpty, t.words.map(\.text).joined() == t.text else { return false }
        var end = -Double.infinity
        for w in t.words {
            guard w.start.isFinite, w.end.isFinite, w.start >= 0, w.end > w.start,
                  w.start >= end - 0.025, w.confidence.isFinite,
                  (0...1).contains(w.confidence) else { return false }
            end = w.end
        }
        return true
    }

    private static func lowerBound(_ words: [Word], start: Double) -> Int {
        var lo = 0, hi = words.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if words[mid].start < start { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    private static func mean(_ words: ArraySlice<Word>) -> Double {
        let duration = words.reduce(0) { $0 + $1.end - $1.start }
        return words.reduce(0) { $0 + $1.confidence * ($1.end - $1.start) } / duration
    }

    private static func aligned(_ a: ArraySlice<Word>, _ b: ArraySlice<Word>) -> Bool {
        let duration = a.last!.end - a.first!.start
        let tolerance = min(0.12, duration * 0.25)
        guard abs(a.first!.start - b.first!.start) <= tolerance,
              abs(a.last!.end - b.last!.end) <= tolerance else { return false }
        // Check each word, not just the outer bounds: an alternative with a hole
        // in the middle must not silently erase a difficult word in that hole.
        return covered(a, by: b) && covered(b, by: a)
    }

    private static func covered(_ words: ArraySlice<Word>, by other: ArraySlice<Word>) -> Bool {
        words.allSatisfy { word in
            var coverage = 0.0
            var end = word.start
            for candidate in other {
                let start = max(word.start, candidate.start, end)
                let stop = min(word.end, candidate.end)
                if stop > start { coverage += stop - start; end = stop }
            }
            return coverage >= (word.end - word.start) * 0.65
        }
    }

    /// Also used to join completed recordings across a settings pause.
    static func join(_ left: String, _ right: String) -> String {
        let a = left.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = right.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = a.last, let first = b.first else { return a + b }
        let closing = ",.;:!?%)]}，。！？、；：…’'"
        let opening = "([{“‘'"
        let space = !closing.contains(first) && !opening.contains(last)
            && !unspaced(last) && !unspaced(first)
        return a + (space ? " " : "") + b
    }

    private static func unspaced(_ ch: Character) -> Bool {
        // Keep CJK and Thai seams natural; Latin-to-Latin seams need a space.
        ch.unicodeScalars.contains {
            (0x3400...0x9FFF).contains($0.value) || (0x3040...0x30FF).contains($0.value)
                || (0x0E00...0x0E7F).contains($0.value)
        }
    }
}
