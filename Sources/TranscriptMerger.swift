// Conservative, opt-in fusion of time-aligned transcripts. Confidence values from
// different language models are only a heuristic, not calibrated probabilities.
// Keep the primary transcript unless a complete alternative span aligns and wins
// by a margin. No translation, rewriting, or invented words.

import Foundation

enum TranscriptMerger {
    struct Word {
        var text: String
        let start: Double
        let end: Double
        let confidence: Double
    }

    struct Transcript {
        let localeID: String
        let text: String
        let words: [Word]
    }

    struct Result {
        let text: String
        let localeIDs: [String]
    }

    private struct Replacement {
        let end: Int
        let track: Int
        let words: Range<Int>
    }

    /// `primary` is the existing whole-recording winner. All words must be final.
    static func merge(primary: Transcript, alternatives: [Transcript]) -> Result {
        let fallback = Result(text: primary.text.trimmingCharacters(in: .whitespacesAndNewlines),
                              localeIDs: [primary.localeID])
        guard isUsable(primary) else { return fallback }
        let tracks = alternatives.filter { $0.localeID != primary.localeID && isUsable($0) }
        guard !tracks.isEmpty else { return fallback }
        let base = primary.words
        let n = base.count
        var scores = [Double](repeating: 0, count: n + 1)
        var choices = [Replacement?](repeating: nil, count: n)

        // A bounded, many-to-many alignment handles, for example, one English
        // word misheard as two Portuguese words. The baseline always remains a
        // valid path, so a missing/weak alternative cannot remove baseline words.
        for i in (0..<n).reversed() {
            scores[i] = scores[i + 1]
            for (trackIndex, track) in tracks.enumerated() {
                let words = track.words
                var k = lowerBound(words, start: base[i].start - 0.12)
                while k < words.count && words[k].start <= base[i].start + 0.12 {
                    for j in (i + 1)...min(i + 8, n) {
                        for l in (k + 1)...min(k + 8, words.count) {
                            if words[l - 1].end > base[j - 1].end + 0.12 { break }
                            let original = base[i..<j]
                            let candidate = words[k..<l]
                            guard aligned(original, candidate),
                                  i == 0 || words[k].start >= base[i - 1].end - 0.025,
                                  j == n || words[l - 1].end <= base[j].start + 0.025,
                                  candidate.allSatisfy({ $0.confidence >= 0.5 }) else { continue }
                            let confidence = mean(candidate)
                            guard confidence >= 0.72 else { continue }
                            let duration = original.reduce(0) { $0 + $1.end - $1.start }
                            // Margin plus a fixed switching cost favors coherent
                            // phrases and keeps near-ties in the primary language.
                            let gain = (confidence - mean(original) - 0.08) * duration - 0.06
                            guard gain > 0, gain + scores[j] > scores[i] + 0.000001 else { continue }
                            scores[i] = gain + scores[j]
                            choices[i] = Replacement(end: j, track: trackIndex, words: k..<l)
                        }
                    }
                    k += 1
                }
            }
        }

        var text = ""
        var locales: [String] = []
        var previousLocale: String?
        var previousEnd = -Double.infinity
        var i = 0
        while i < n {
            let locale: String
            let words: ArraySlice<Word>
            if let choice = choices[i] {
                let track = tracks[choice.track]
                locale = track.localeID
                words = track.words[choice.words]
                i = choice.end
            } else {
                locale = primary.localeID
                words = base[i..<(i + 1)]
                i += 1
            }
            // Independent substitutions must not repeat audio at their seam.
            guard words.first!.start >= previousEnd - 0.025 else { return fallback }
            let fragment = words.map(\.text).joined()
            text = previousLocale == nil || previousLocale == locale
                ? text + fragment : join(text, fragment)
            if !locales.contains(locale) { locales.append(locale) }
            previousLocale = locale
            previousEnd = words.last!.end
        }
        return Result(text: text.trimmingCharacters(in: .whitespacesAndNewlines), localeIDs: locales)
    }

    private static func isUsable(_ t: Transcript) -> Bool {
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

    private static func join(_ left: String, _ right: String) -> String {
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
