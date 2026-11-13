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
    }
}
