import Foundation

@main
enum NativeCleanupSmoke {
    static func main() async {
        let primary = TranscriptMerger.Transcript(localeID: "en_US", text: "This is a test", words: [
            .init(text: "This is a test", start: 0, end: 2, confidence: 0.95)
        ])
        let fallback = TranscriptMerger.merge(primary: primary, alternatives: [])
        let plan = CleanupPlan.make(fallback: fallback, alternatives: [], localeIDs: ["en_US"])!
        let unavailable = SmartCleanup.unavailableReason(localeIDs: ["en_US"])
        let result = await SmartCleanup.refine(plan)
        if let unavailable {
            precondition(result.text == fallback.text, "Unavailable model must keep the transcript")
            print("Native cleanup fallback passed: \(unavailable)")
        } else {
            precondition([fallback.text, fallback.text + ".", fallback.text + "?", fallback.text + "!"].contains(result.text),
                         "Only missing terminal punctuation may change")
            print("Native cleanup bounded-output smoke check passed; bilingual accuracy still needs evaluation")
        }
        // Exercise Natural even when no timed-word cleanup plan exists.
        let spoken = "Uh, I I need the pull request today."
        let natural = await SmartCleanup.process(text: spoken, localeIDs: ["en_US"], plan: nil, style: .natural)
        if unavailable != nil {
            precondition(natural == spoken, "Unavailable model must preserve Natural input")
        } else {
            precondition(FluencyCleanup.validated(natural, source: spoken) != nil, "Natural output must satisfy its validation")
        }
        print("Native Natural cleanup success/fallback check passed; fluency quality still needs real model evaluation")
        let dictated = "Eu tô testando pra ver se eles vai entender."
        let written = await SmartCleanup.process(text: dictated, localeIDs: ["pt_BR"], plan: nil, style: .written)
        if SmartCleanup.unavailableReason(localeIDs: ["pt_BR"]) != nil {
            precondition(written == dictated, "Unavailable model must preserve Written input")
        } else {
            precondition(WrittenCleanup.validated(written, source: dictated, localeIDs: ["pt_BR"]) != nil,
                         "Written output must satisfy its validation")
        }
        print("Native Written cleanup success/fallback check passed; fidelity and grammar still need real model evaluation")
        // Contextual: an English recognizer heard the loanwords the Portuguese one garbled.
        let draft = "Eu preciso fazer o de ploy da Brent hoje."
        func words(_ spec: [(String, Double)]) -> [TranscriptMerger.Word] {
            spec.enumerated().map { .init(text: ($0.offset == 0 ? "" : " ") + $0.element.0, start: Double($0.offset), end: Double($0.offset) + 0.5, confidence: $0.element.1) }
        }
        let pt = words([("Eu", 0.95), ("preciso", 0.95), ("fazer", 0.95), ("o", 0.95), ("de", 0.3), ("ploy", 0.2), ("da", 0.9), ("Brent", 0.3), ("hoje.", 0.95)])
        let en = words([("Oh", 0.2), ("pressure", 0.2), ("the", 0.6), ("deploy", 0.85), ("the", 0.5), ("branch", 0.8), ("hoje.", 0.2)])
        let evidence = CleanupEvidence(draftWords: pt, recognitions: [
            .init(localeID: "pt_BR", text: draft, words: pt),
            .init(localeID: "en_US", text: en.map(\.text).joined(), words: en)])
        let contextual = await SmartCleanup.process(text: draft, localeIDs: ["pt_BR", "en_US"], plan: nil,
                                                    style: .contextual, evidence: evidence)
        if SmartCleanup.unavailableReason(localeIDs: ["pt_BR", "en_US"]) != nil {
            precondition(contextual == draft, "Unavailable model must preserve Contextual input")
        } else {
            precondition(contextual.hasPrefix("Eu preciso fazer"), "Contextual must keep confident words")
        }
        print("Native Contextual cleanup check passed: \(contextual)")
    }
}
