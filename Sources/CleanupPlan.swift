// A language model may choose candidate IDs, never supply text to be pasted.
// Keep preparation and output validation independent of Foundation Models so the
// failure paths can be tested without a model or microphone.

import Foundation

struct CleanupPlan: Sendable {
    enum Ending: String, Sendable { case keep, period, question, exclamation }
    struct Decision: Sendable { let choices: [Int]; let ending: Ending }
    struct Option: Sendable {
        let tokens: [TranscriptMerger.Token]
        let confidence: Double
        var text: String { TranscriptMerger.render(tokens)?.text ?? "" }
    }
    struct Passage: Sendable {
        let range: Range<Int>
        let options: [Option]   // 0 always keeps the existing merged transcript
    }

    let fallback: TranscriptMerger.Result
    let passages: [Passage]
    let allowEnding: Bool
    let prompt: String
    let localeIDs: [String]
    static let maxPassages = 6
    static let maxPromptBytes = 6_000

    /// Model injection keeps the real success/fallback path testable on machines
    /// without Apple Intelligence. No provider text is ever used as final prose.
    func refined(seconds: Double,
                 choosing: @escaping @Sendable (String) async throws -> Decision?) async -> TranscriptMerger.Result {
        let response = await CleanupDeadline.run(seconds: seconds) { try await choosing(prompt) }
        guard let response, let decision = response, !Task.isCancelled else { return fallback }
        return applying(decision)
    }

    static func make(fallback: TranscriptMerger.Result, alternatives: [TranscriptMerger.Transcript],
                     localeIDs: [String]) -> CleanupPlan? {
        let tokens = fallback.tokens
        guard !tokens.isEmpty else { return nil }
        let base = tokens.map(\.word)
        let tracks = alternatives.filter(TranscriptMerger.isUsable)
        var passages: [Passage] = []
        var i = 0
        while i < base.count && passages.count < maxPassages {
            let candidates = TranscriptMerger.candidates(at: i, in: base, alternatives: tracks).filter { candidate in
                let original = base[candidate.range]
                return candidate.confidence >= 0.65 && original.contains { $0.confidence < 0.85 }
                    && lexemes(candidate.words.map(\.text).joined()).map { $0.lowercased() }
                        != lexemes(original.map(\.text).joined()).map { $0.lowercased() }
                    && preservesProtectedWords(original, candidate.words)
                    && candidate.words.map(\.text).joined().utf8.count <= 512
            }.sorted {
                if $0.range.count != $1.range.count { return $0.range.count < $1.range.count }
                if $0.confidence != $1.confidence { return $0.confidence > $1.confidence }
                return $0.localeID < $1.localeID
            }
            guard let first = candidates.first else { i += 1; continue }
            let original = Array(tokens[first.range])
            var options = [Option(tokens: original, confidence: first.originalConfidence)]
            var seen = Set([options[0].text])
            for candidate in candidates where candidate.range == first.range {
                let option = Option(tokens: candidate.words.map { .init(word: $0, localeID: candidate.localeID) },
                                    confidence: candidate.confidence)
                if seen.insert(option.text).inserted { options.append(option) }
                if options.count == 3 { break }
            }
            passages.append(Passage(range: first.range, options: options))
            i = first.range.upperBound
        }

        let allowEnding = canAddEnding(to: tokens.last!.word.text)
        // Bound prompt size independently of recording length. Excess disputes
        // keep the existing merged text; no part of the dictation is truncated.
        while !passages.isEmpty || allowEnding {
            if let prompt = encodePrompt(passages, tokens: tokens, localeIDs: localeIDs, allowEnding: allowEnding),
               prompt.utf8.count <= maxPromptBytes {
                return CleanupPlan(fallback: fallback, passages: passages, allowEnding: allowEnding,
                                   prompt: prompt, localeIDs: localeIDs)
            }
            guard !passages.isEmpty else { break }
            passages.removeLast()
        }
        return nil
    }

    /// Reject the entire response if any ID/count is invalid. Reconstruct from
    /// stored recognition tokens and recheck their seams before accepting it.
    func applying(_ decision: Decision) -> TranscriptMerger.Result {
        guard decision.choices.count == passages.count,
              zip(passages, decision.choices).allSatisfy({ passage, choice in passage.options.indices.contains(choice) }),
              allowEnding || decision.ending == .keep else { return fallback }
        var tokens: [TranscriptMerger.Token] = []
        var offset = 0
        for (passage, choice) in zip(passages, decision.choices) {
            tokens += fallback.tokens[offset..<passage.range.lowerBound]
            tokens += passage.options[choice].tokens
            offset = passage.range.upperBound
        }
        tokens += fallback.tokens[offset...]
        if decision.ending != .keep {
            guard let last = tokens.last, Self.canAddEnding(to: last.word.text) else { return fallback }
            var word = last.word
            while word.text.last?.isWhitespace == true { word.text.removeLast() }
            let punctuation = switch decision.ending {
            case .keep: ""
            case .period: "."
            case .question: "?"
            case .exclamation: "!"
            }
            word.text += punctuation
            tokens[tokens.count - 1] = .init(word: word, localeID: last.localeID)
        }
        return TranscriptMerger.render(tokens) ?? fallback
    }

    private static func lexemes(_ text: String) -> [String] {
        text.split { !$0.isLetter && !$0.isNumber && $0 != "'" && $0 != "’" }.map(String.init)
    }

    private static func looksProtected(_ word: TranscriptMerger.Word) -> Bool {
        word.text.contains { $0.isNumber || $0.isUppercase || "@/\\_=$#%".contains($0) }
    }

    private static func preservesProtectedWords(_ original: ArraySlice<TranscriptMerger.Word>,
                                                _ candidate: [TranscriptMerger.Word]) -> Bool {
        // Preserve strong recognitions, numerals, capitalized names and common
        // code/URL spellings. This is deliberately conservative about capitalization.
        let required = original.filter { $0.confidence >= 0.90 || looksProtected($0) }.flatMap { lexemes($0.text) }
        let proposed = lexemes(candidate.map(\.text).joined())
        var cursor = proposed.startIndex
        for word in required {
            guard let index = proposed[cursor...].firstIndex(of: word) else { return false }
            cursor = index + 1
        }
        // Don't introduce a different number, capitalized name or code token.
        let originalLexemes = lexemes(original.map(\.text).joined())
        return candidate.filter(looksProtected).allSatisfy { word in
            lexemes(word.text).allSatisfy(originalLexemes.contains)
        }
    }

    private static func canAddEnding(to text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.last?.isLetter == true
            && !trimmed.contains { $0.isNumber || "@/\\_=$#%".contains($0) }
    }

    private struct PromptOption: Encodable {
        let id: Int
        let text: String
        let languages: [String]
        let confidence: Double
    }
    private struct PromptPassage: Encodable {
        let id: Int
        let before: String
        let after: String
        let options: [PromptOption]
    }
    private struct PromptData: Encodable {
        let languages: [String]
        let passages: [PromptPassage]
        let endingContext: String
        let allowEnding: Bool
    }

    private static func encodePrompt(_ passages: [Passage], tokens: [TranscriptMerger.Token],
                                     localeIDs: [String], allowEnding: Bool) -> String? {
        func context(_ range: Range<Int>) -> String { TranscriptMerger.render(Array(tokens[range]))?.text ?? "" }
        let data = PromptData(languages: localeIDs, passages: passages.enumerated().map { id, passage in
            let range = passage.range
            return PromptPassage(id: id,
                before: String(context(max(0, range.lowerBound - 12)..<range.lowerBound).suffix(180)),
                after: String(context(range.upperBound..<min(tokens.count, range.upperBound + 12)).prefix(180)),
                options: passage.options.enumerated().map { index, option in
                    PromptOption(id: index, text: option.text,
                                 languages: Array(Set(option.tokens.map(\.localeID))).sorted(),
                                 confidence: (option.confidence * 100).rounded() / 100)
                })
        }, endingContext: String(context(max(0, tokens.count - 16)..<tokens.count).suffix(240)), allowEnding: allowEnding)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let encoded = try? encoder.encode(data) else { return nil }
        return String(data: encoded, encoding: .utf8)
    }
}
