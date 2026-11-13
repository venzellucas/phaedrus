import Foundation

@main
@MainActor
enum TranscriptMergerTests {
    typealias Word = TranscriptMerger.Word
    typealias Transcript = TranscriptMerger.Transcript
    static var checks = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        guard condition() else { fatalError(message) }
    }

    static func track(_ locale: String, _ words: [Word]) -> Transcript {
        .init(localeID: locale, text: words.map(\.text).joined(), words: words)
    }

    static func word(_ text: String, _ start: Double, _ end: Double, _ confidence: Double) -> Word {
        .init(text: text, start: start, end: end, confidence: confidence)
    }

    static func main() {
        let pt = track("pt_BR", [word("Preciso ", 0, 0.5, 0.96), word("fazer ", 0.5, 1, 0.96),
                                  word("o ", 1, 1.2, 0.94), word("de ", 1.2, 1.5, 0.30),
                                  word("plói ", 1.5, 1.9, 0.35), word("hoje.", 1.9, 2.4, 0.95)])
        let en = track("en_US", [word("Pre see so ", 0, 0.5, 0.40), word("fuzz air ", 0.5, 1, 0.40),
                                  word("oh ", 1, 1.2, 0.45), word("deploy ", 1.2, 1.9, 0.98),
                                  word("oh gee.", 1.9, 2.4, 0.35)])
        let mixed = TranscriptMerger.merge(primary: pt, alternatives: [en])
        expect(mixed.text == "Preciso fazer o deploy hoje.", "Portuguese → English → Portuguese, two words to one")
        expect(mixed.localeIDs == ["pt_BR", "en_US"], "Report actual languages used")
        expect(TranscriptMerger.merge(primary: pt, alternatives: []).text == pt.text, "Single language unchanged")
        expect(TranscriptMerger.merge(primary: pt, alternatives: [pt]).text == pt.text, "Ignore duplicate locale")

        let primary = track("en_US", [word("Send ", 0, 0.5, 0.95), word("the ", 0.5, 0.8, 0.9),
                                       word("pull request ", 0.8, 1.8, 0.95), word("poor favor.", 1.8, 2.8, 0.35)])
        let portuguese = track("pt_BR", [word("por ", 1.8, 2.2, 0.97), word("favor.", 2.2, 2.8, 0.97)])
        expect(TranscriptMerger.merge(primary: primary, alternatives: [portuguese]).text == "Send the pull request por favor.",
               "English → Portuguese, one run to two words")

        let baseline = track("pt_BR", [word("Bom ", 0, 0.6, 0.9), word("dia.", 0.6, 1.2, 0.9)])
        let tie = track("en_US", [word("Boom ", 0, 0.6, 0.94), word("dear.", 0.6, 1.2, 0.94)])
        expect(TranscriptMerger.merge(primary: baseline, alternatives: [tie]).text == "Bom dia.", "Near ties don't switch")

        let missing = Transcript(localeID: "pt_BR", text: pt.text, words: [])
        expect(TranscriptMerger.merge(primary: missing, alternatives: [en]).text == pt.text, "Missing baseline timing falls back")
        let incomplete = Transcript(localeID: "en_US", text: "something omitted", words: en.words)
        expect(TranscriptMerger.merge(primary: pt, alternatives: [incomplete]).text == pt.text, "Incomplete timing cannot drop text")
        let invalid = track("en_US", [word("bad", .nan, 1, 0.99)])
        expect(TranscriptMerger.merge(primary: pt, alternatives: [invalid]).text == pt.text, "Reject invalid times")
        let badConfidence = track("en_US", [word("bad", 1.2, 1.9, .nan)])
        expect(TranscriptMerger.merge(primary: pt, alternatives: [badConfidence]).text == pt.text, "Reject invalid confidence")

        let holes = track("en_US", [word("missing", 1.2, 1.35, 0.99), word(" word", 1.8, 1.9, 0.99)])
        expect(TranscriptMerger.merge(primary: pt, alternatives: [holes]).text == pt.text, "Don't erase speech inside a timing hole")
        let shifted = track("en_US", [word("deploy", 1.38, 2.08, 0.99)])
        expect(TranscriptMerger.merge(primary: pt, alternatives: [shifted]).text == pt.text, "Reject misaligned boundary")
        let overlap = track("en_US", [word("deploy ", 1.15, 1.95, 0.99)])
        expect(TranscriptMerger.merge(primary: pt, alternatives: [overlap]).text == pt.text, "Don't duplicate neighboring audio")

        let noSpaces = track("en_US", [word("deploy", 1.2, 1.9, 0.99)])
        expect(TranscriptMerger.merge(primary: pt, alternatives: [noSpaces]).text == "Preciso fazer o deploy hoje.",
               "Restore spaces at language seams")
        let punctuated = track("pt_BR", [word("Diga: ", 0, 0.5, 0.95), word("olá", 0.5, 1.3, 0.3),
                                         word(", depois continue.", 1.3, 2, 0.95)])
        let hello = track("en_US", [word("hello", 0.5, 1.3, 0.99)])
        expect(TranscriptMerger.merge(primary: punctuated, alternatives: [hello]).text == "Diga: hello, depois continue.",
               "No space before punctuation")

        let three = track("pt_BR", [word("Diga ", 0, 0.5, 0.95), word("olá ", 0.5, 1.3, 0.3), word("mundo.", 1.3, 2, 0.3)])
        let es = track("es_ES", [word("mundo.", 1.3, 2, 0.99)])
        let triple = TranscriptMerger.merge(primary: three, alternatives: [hello, es])
        expect(triple.text == "Diga hello mundo.", "Three languages")
        expect(triple.localeIDs == ["pt_BR", "en_US", "es_ES"], "Three contributing locales")

        let cjk = track("ja_JP", [word("今日", 0, 0.7, 0.95), word("展開", 0.7, 1.4, 0.2)])
        let cjkAlternative = track("en_US", [word("deploy", 0.7, 1.4, 0.99)])
        expect(TranscriptMerger.merge(primary: cjk, alternatives: [cjkAlternative]).text == "今日deploy", "Unspaced script seam")
        let empty = track("pt_BR", [])
        expect(TranscriptMerger.merge(primary: empty, alternatives: [en]).text.isEmpty, "No invented words from empty baseline")

        // A full-length session: ensure monotonic alignment keeps all words and
        // runs in practical time without an unbounded cross-product of tracks.
        let longBase = track("pt_BR", (0..<2700).map { word("a ", Double($0) / 3, Double($0 + 1) / 3, 0.9) })
        let longOther = track("en_US", (0..<2700).map { word("b ", Double($0) / 3, Double($0 + 1) / 3, 0.92) })
        let started = Date()
        expect(TranscriptMerger.merge(primary: longBase, alternatives: [longOther]).text == longBase.text.trimmingCharacters(in: .whitespaces),
               "15-minute near-tie transcript stays intact")
        print("Passed \(checks) merge checks; 15-minute fixture: \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
    }
}
