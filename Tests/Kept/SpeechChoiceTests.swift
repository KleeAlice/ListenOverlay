import Foundation
import CoreMedia

@main
enum SpeechChoiceTests {
    static func main() {
        func candidate(_ text: String, _ locale: String, _ confidence: Double, _ start: Double = 0, _ duration: Double = 2) -> SpeechCandidate {
            SpeechCandidate(text: text, isFinal: true, locale: locale, confidence: confidence,
                            range: CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 48000),
                                               duration: CMTime(seconds: duration, preferredTimescale: 48000)))
        }
        let english = candidate("Please open the window.", "en-US", 0.91)
        let chinese = candidate("请打开窗户。", "zh-CN", 0.65)
        precondition(SpeechChoice.best([english, chinese], preferred: "zh-CN")?.locale == "en-US",
                     "A prior language must not overrule substantially better new speech.")
        precondition(SpeechChoice.sameUtterance(english.range, candidate("hello", "en-US", 0.9, 0.2, 2.1).range))
        precondition(!SpeechChoice.sameUtterance(english.range, candidate("long hallucination", "en-US", 0.2, 0, 12).range),
                     "A long result must not swallow several separate utterances.")
        precondition(!SpeechChoice.sameUtterance(english.range, candidate("next", "en-US", 0.9, 2, 1).range))
        precondition(SpeechChoice.best([candidate(", , ,", "en-US", 0.96), chinese], preferred: nil)?.locale == "zh-CN",
                     "Punctuation alone is not speech, even when its confidence is high.")
        precondition(SpeechChoice.best([candidate("Thanks", "en-US", -1)], preferred: nil) != nil,
                     "Missing confidence must not discard otherwise valid speech.")
        let committed = [english.range, candidate("second", "en-US", 0.9, 2.5, 2).range,
                         candidate("third", "en-US", 0.9, 5, 2).range]
        precondition(SpeechChoice.overlapsCommitted(candidate("all three sentences", "zh-CN", 0.6, 0, 8).range,
                                                    committed: committed),
                     "A late result spanning several displayed sentences must not repeat the entire paragraph.")
        precondition(!SpeechChoice.overlapsCommitted(candidate("new sentence", "zh-CN", 0.9, 7.5, 2).range,
                                                     committed: committed))
        print("Speech choice: 7 regression checks passed")
    }
}
