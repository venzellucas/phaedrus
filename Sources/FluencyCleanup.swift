// Natural cleanup may remove spoken disfluencies and repunctuate the remaining
// words. Its output is still constrained to the source wording and order.
import Foundation

enum CleanupStyle: String, CaseIterable, Sendable {
    case conservative, natural
    var title: String { self == .natural ? "Natural" : "Conservative" }
    var timeoutSeconds: Double { self == .natural ? 10 : 5 }
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
            if let accepted = validated(rewritten, source: piece.text, localeIDs: localeIDs) { result[i] = accepted }
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
            guard tail.allSatisfy(fillerWords.contains)
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

    private struct Word { let text: String; let key: String }
    private static func words(_ text: String) -> [Word] {
        matches("[\\p{L}\\p{M}\\p{N}]+(?:['’][\\p{L}\\p{M}\\p{N}]+)*", in: text).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            let value = String(text[range])
            return Word(text: value, key: value.precomposedStringWithCanonicalMapping.lowercased().replacingOccurrences(of: "’", with: "'"))
        }
    }
    private static func matches(_ pattern: String, in text: String) -> [NSTextCheckingResult] {
        (try? NSRegularExpression(pattern: pattern).matches(in: text, range: NSRange(text.startIndex..., in: text))) ?? []
    }
    private static let fillerWords = Set("uh um er ah eh hum hmm hmmm tipo né neh assim então enfim bom bem sabe like well okay ok actually basically literally you know i mean".split(separator: " ").map(String.init))
    private static let criticalWords = Set("não nao nunca jamais nem sem só somente apenas exceto talvez no not never neither nor without unless only except maybe perhaps could might must should can't cannot won't wouldn't shouldn't couldn't isn't aren't wasn't weren't don't doesn't didn't zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty thirty forty fifty sixty seventy eighty ninety hundred thousand million billion um uma dois duas três tres quatro cinco seis sete oito nove dez onze doze treze catorze quatorze quinze dezesseis dezasseis dezessete dezassete dezoito dezenove dezanove vinte trinta quarenta cinquenta sessenta setenta oitenta noventa cem cento duzentos trezentos quatrocentos quinhentos seiscentos setecentos oitocentos novecentos mil milhão milhões bilhão bilhões uno una dos cuatro seis siete ocho nueve diez cien sin ni solo quizás".split(separator: " ").map(String.init))
    private static let commonCapitals = fillerWords.union("a o os as eu nós nos você vocês voce voces ele ela eles elas isso isto esse essa este esta e mas ou se de do da dos das em para por que porque como quando the i we you he she it they this that these those and but or if to of for in on with please preciso quero vou vamos can is are".split(separator: " ").map(String.init))

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

    private static func technicalAtoms(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).compactMap { atom in
            guard atom.contains(where: { "@/\\_=$#%+*<>|&`".contains($0) })
                || atom.contains(where: \.isNumber)
                || !matches("[\\p{L}\\p{N}][.-][\\p{L}\\p{N}]", in: String(atom)).isEmpty else { return nil }
            return String(atom).trimmingCharacters(in: CharacterSet(charactersIn: ".,;!?\"“”()"))
                .replacingOccurrences(of: "’", with: "'")
        }
    }
}
