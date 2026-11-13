// Natural cleanup may remove spoken disfluencies and repunctuate the remaining
// words. Its output is still constrained to the source wording and order.
import Foundation

enum CleanupStyle: String, CaseIterable, Sendable {
    case conservative, natural, written
    var title: String {
        switch self {
        case .conservative: "Conservative"
        case .natural: "Natural"
        case .written: "Written"
        }
    }
    var timeoutSeconds: Double {
        switch self {
        case .conservative: 5
        case .natural: 10
        case .written: 15
        }
    }
    var explanation: String {
        switch self {
        case .conservative:
            "Conservative chooses recognized alternatives and adds missing final punctuation. Keeps repetitions and spoken fillers."
        case .natural:
            "Natural removes accidental repetitions, fillers, and abandoned starts, and adjusts punctuation. Keeps the remaining words in their original language and order. Cuts can still change meaning; review the result."
        case .written:
            "Written also corrects grammar, spelling, and likely recognition mistakes using context. Aims to keep your voice, grammatical person, meaning, language switches, and order of ideas. It can replace words and make incorrect guesses; review the result."
        }
    }
}

enum FluencyCleanup {
    static let maxChunkBytes = 1_800
    static let maxChunkWords = 120

    struct Part: Sendable {
        let text: String
        let editable: Bool
    }

    /// Preserve separators and unprocessed chunks exactly. A shared deadline
    /// bounds the whole pass, including a provider that ignores cancellation.
    static func refine(_ text: String, localeIDs: [String], seconds: Double,
                       validation: @escaping @Sendable (String, String, [String]) -> String? = FluencyCleanup.validated,
                       rewriting: @escaping @Sendable (String) async throws -> String?) async -> String {
        let pieces = parts(text)
        var result = pieces.map(\.text)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(max(0, seconds)))
        for (i, piece) in pieces.enumerated() where piece.editable {
            let remaining = clock.now.duration(to: deadline)
            guard remaining > .zero, !Task.isCancelled else { break }
            struct Input: Encodable { let languages: [String]; let text: String }
            guard let data = try? JSONEncoder().encode(Input(languages: localeIDs, text: piece.text)),
                  let prompt = String(data: data, encoding: .utf8) else { continue }
            let budget = Double(remaining.components.seconds) + Double(remaining.components.attoseconds) / 1e18
            let response = await CleanupDeadline.run(seconds: budget) { try await rewriting(prompt) }
            guard !Task.isCancelled else { return text }
            guard let response, let rewritten = response else { break }
            if let accepted = validation(rewritten, piece.text, localeIDs) {
                result[i] = accepted
            } else if let partial = salvagingRepetitions(rewritten, source: piece.text, localeIDs: localeIDs) {
                result[i] = partial
            }
        }
        return Task.isCancelled ? text : result.joined()
    }

    /// Split at paragraph boundaries, then at whitespace near sentence ends.
    /// The literal pieces ensure deadlines, very long tokens, and skipped parts
    /// never truncate a dictation or collapse its paragraph separators.
    static func parts(_ text: String) -> [Part] {
        let ranges = matches("\\S+", in: text).compactMap { Range($0.range, in: text) }
        guard let first = ranges.first else { return [.init(text: text, editable: false)] }
        var pieces: [Part] = []
        var cursor = text.startIndex
        var start = first.lowerBound
        var end = first.upperBound
        var count = 1
        func flush() {
            if cursor < start { pieces.append(.init(text: String(text[cursor..<start]), editable: false)) }
            let chunk = String(text[start..<end])
            pieces.append(.init(text: chunk, editable: chunk.utf8.count <= maxChunkBytes))
            cursor = end
        }
        for range in ranges.dropFirst() {
            let gap = text[end..<range.lowerBound]
            let sentenceEnd = text[text.index(before: end)].unicodeScalars.contains { ".!?".unicodeScalars.contains($0) }
            if gap.contains(where: \.isNewline) || count >= maxChunkWords
                || text[start..<range.upperBound].utf8.count > maxChunkBytes || (count >= 80 && sentenceEnd) {
                flush()
                start = range.lowerBound
                count = 0
            }
            end = range.upperBound
            count += 1
        }
        flush()
        if cursor < text.endIndex { pieces.append(.init(text: String(text[cursor...]), editable: false)) }
        return pieces
    }

    /// These are guardrails against obvious corruption, not proof that a cut
    /// preserves meaning. The model still decides whether a word is a filler.
    static func validated(_ proposal: String, source: String, localeIDs: [String] = ["pt_BR", "en_US"]) -> String? {
        let output = proposal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty, output.utf8.count <= source.utf8.count + 64,
              !output.contains(where: \.isNewline) else { return nil }
        let original = words(source)
        let proposed = words(output)
        guard !original.isEmpty, !proposed.isEmpty,
              proposed.count <= original.count,
              proposed.count * 2 >= original.count else { return nil }

        // No added words, paraphrases, translations, or reordered clauses.
        var kept = Set<Int>()
        var cursor = 0
        for word in proposed {
            guard let index = original[cursor...].firstIndex(where: { $0.key == word.key }) else { return nil }
            kept.insert(index)
            cursor = index + 1
        }
        // A truncated response often looks like a valid prefix. Only allow a
        // removed tail made entirely of fillers or an adjacent repeated phrase.
        if cursor < original.count {
            let tail = Array(original[cursor...].map(\.key))
            let preceding = Array(original[..<cursor].map(\.key))
            guard isFillerTail(tail)
                || (tail.count <= preceding.count && Array(preceding.suffix(tail.count)) == tail) else { return nil }
        }
        var removedRun = 0
        for i in original.indices {
            removedRun = kept.contains(i) ? 0 : removedRun + 1
            guard removedRun <= 12 else { return nil }
        }
        // Keep important words and their order. Consecutive exact repetitions
        // may collapse ("não, não quero"), separate negations may not disappear.
        let names = Set(original.filter { $0.text.contains(where: \.isUppercase) && !commonCapitals.contains($0.key) }.map(\.key))
        let protectUm = localeIDs.contains { Locale(identifier: $0).language.languageCode?.identifier == "pt" }
        guard protectedWords(original, names: names, protectUm: protectUm)
            == protectedWords(proposed, names: names, protectUm: protectUm) else { return nil }
        guard technicalAtoms(source) == technicalAtoms(output) else { return nil }
        // Sentence punctuation is editable; other symbols must already exist.
        let punctuation = CharacterSet(charactersIn: ".,!?;:…—–-\"'’“”()")
        let sourceSymbols = Set(source.unicodeScalars.filter { !CharacterSet.alphanumerics.contains($0) })
        guard output.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0)
            || CharacterSet.whitespacesAndNewlines.contains($0) || punctuation.contains($0)
            || sourceSymbols.contains($0) }) else { return nil }
        return output
    }

    /// An otherwise rejected rewrite may still identify simple stutters. Keep
    /// only those local deletions, reconstructing from the original string. No
    /// replacement wording or punctuation from the rejected response is used.
    static func salvagingRepetitions(_ proposal: String, source: String, localeIDs: [String]) -> String? {
        let original = words(source)
        let proposed = words(proposal)
        let originalCounts = Dictionary(grouping: original, by: \.key).mapValues(\.count)
        let proposedCounts = Dictionary(grouping: proposed, by: \.key).mapValues(\.count)
        let matchingWords = proposedCounts.reduce(0) { $0 + min($1.value, originalCounts[$1.key, default: 0]) }
        guard !proposed.isEmpty, proposal.utf8.count <= source.utf8.count + 128,
              matchingWords * 10 >= proposed.count * 7,
              matchingWords * 5 >= original.count * 2 else { return nil }
        var remaining = originalCounts
        var removals: [Range<String.Index>] = []
        var i = 0
        while i < original.count {
            let first = original[i]
            var end = i + 1
            while end < original.count, original[end].key == first.key,
                  source[original[end - 1].range.upperBound..<original[end].range.lowerBound].allSatisfy(\.isWhitespace) {
                end += 1
            }
            // A retained occurrence in the proposal is necessary evidence for
            // collapsing a stutter. Refusals/empty text do not request deletion.
            if stutterWords.contains(first.key), let retained = proposedCounts[first.key], retained > 0 {
                let count = min(end - i - 1, max(0, remaining[first.key, default: 0] - retained))
                if count > 0 {
                    removals.append(first.range.upperBound..<original[i + count].range.upperBound)
                    remaining[first.key, default: 0] -= count
                }
            }
            i = end
        }
        guard !removals.isEmpty else { return nil }
        var candidate = ""
        var cursor = source.startIndex
        for range in removals {
            candidate += source[cursor..<range.lowerBound]
            cursor = range.upperBound
        }
        candidate += source[cursor...]
        return validated(candidate, source: source, localeIDs: localeIDs)
    }

    // Deliberately excludes names, numbers, negations, and intensifiers such as
    // "very"/"muito". Punctuated repetitions ("go, go!") are also left intact.
    private static let stutterWords = Set("i eu the a o os as de da das dos em para to and e que it we they he she is are was up go".split(separator: " ").map(String.init))

    private struct Word { let text: String; let key: String; let range: Range<String.Index> }
    private static func words(_ text: String) -> [Word] {
        matches("[\\p{L}\\p{M}\\p{N}]+(?:['’][\\p{L}\\p{M}\\p{N}]+)*", in: text).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            let value = String(text[range])
            return Word(text: value, key: value.precomposedStringWithCanonicalMapping.lowercased().replacingOccurrences(of: "’", with: "'"), range: range)
        }
    }
    private static func matches(_ pattern: String, in text: String) -> [NSTextCheckingResult] {
        (try? NSRegularExpression(pattern: pattern).matches(in: text, range: NSRange(text.startIndex..., in: text))) ?? []
    }
    static let fillerWords = Set("uh um er ah eh é hum hmm hmmm tipo né neh assim então enfim bom bem sabe like well okay ok actually basically literally".split(separator: " ").map(String.init))
    private static func isFillerTail(_ words: [String]) -> Bool {
        let phrases = [["you", "know"], ["i", "mean"], ["kind", "of"], ["sort", "of"]]
        var i = 0
        while i < words.count {
            if let phrase = phrases.first(where: { Array(words[i...].prefix($0.count)) == $0 }) {
                i += phrase.count
            } else if fillerWords.contains(words[i]) {
                i += 1
            } else { return false }
        }
        return true
    }
    static let criticalWords = Set("não nao nunca jamais nem sem só somente apenas exceto talvez no not never neither nor without unless only except maybe perhaps could might must should can't cannot won't wouldn't shouldn't couldn't isn't aren't wasn't weren't don't doesn't didn't zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty thirty forty fifty sixty seventy eighty ninety hundred thousand million billion um uma dois duas três tres quatro cinco seis sete oito nove dez onze doze treze catorze quatorze quinze dezesseis dezasseis dezessete dezassete dezoito dezenove dezanove vinte trinta quarenta cinquenta sessenta setenta oitenta noventa cem cento duzentos trezentos quatrocentos quinhentos seiscentos setecentos oitocentos novecentos mil milhão milhões bilhão bilhões uno una dos cuatro seis siete ocho nueve diez cien sin ni solo quizás".split(separator: " ").map(String.init))
    // ASR often capitalizes discourse markers after a pause. Capitalization
    // alone must not turn "So", "Yeah", or "Just" into protected names. This
    // does not remove them automatically; the model still considers context.
    static let commonCapitals = fillerWords.union("a o os as eu nós nos você vocês voce voces ele ela eles elas isso isto esse essa este esta e mas ou se de do da dos das em para por que porque como quando the i we you he she it they this that these those and but or if to of for in on with please preciso quero vou vamos can is are so yeah just".split(separator: " ").map(String.init))

    private static func protectedWords(_ words: [Word], names: Set<String>, protectUm: Bool) -> [String] {
        var result: [String] = []
        for (i, word) in words.enumerated() {
            let isName = names.contains(word.key)
            let critical = criticalWords.contains(word.key) && (word.key != "um" || protectUm)
            guard isName || word.text.contains(where: \.isNumber) || critical else { continue }
            if i > 0 && words[i - 1].key == word.key { continue }
            result.append(word.key)
        }
        return result
    }

    static func technicalAtoms(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).compactMap { atom in
            guard atom.contains(where: { "@/\\_=$#%+*<>|&`".contains($0) })
                || atom.contains(where: \.isNumber)
                || !matches("[\\p{L}\\p{N}][.-][\\p{L}\\p{N}]", in: String(atom)).isEmpty else { return nil }
            return String(atom).trimmingCharacters(in: CharacterSet(charactersIn: ".,;!?\"“”()"))
                .replacingOccurrences(of: "’", with: "'")
        }
    }
}
