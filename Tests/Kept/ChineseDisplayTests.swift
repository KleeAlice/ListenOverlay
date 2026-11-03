import Foundation

@main struct ChineseDisplayTests {
    static func main() {
        var failures = 0
        func expect(_ actual: String, _ expected: String, _ message: String) {
            if actual != expected {
                failures += 1
                print("FAIL: \(message): expected \(expected.debugDescription), got \(actual.debugDescription)")
            }
        }

        let lyrics = "聽見你的聲音\n讓愛繼續，夢還在遠方。"
        expect(ChineseDisplay.text(lyrics), "听见你的声音\n让爱继续，梦还在远方。", "lyrics default to simplified Chinese")
        expect(ChineseDisplay.text("江南 · 林俊傑 · 第二天堂"), "江南 · 林俊杰 · 第二天堂", "song identity is simplified")
        expect(ChineseDisplay.text("  聽見 Hello 2026! 🎵\n第 2 行\tOK  "), "  听见 Hello 2026! 🎵\n第 2 行\tOK  ", "English, digits, whitespace, and emoji are preserved")
        expect(ChineseDisplay.text(lyrics, simplified: false), lyrics, "turning conversion off keeps the original text")
        expect(ChineseDisplay.text("听见你的声音\nHello 2026!"), "听见你的声音\nHello 2026!", "already simplified content is unchanged")
        expect(ChineseDisplay.text(""), "", "empty text is unchanged")

        if failures > 0 { exit(1) }
        print("All Chinese display tests passed")
    }
}
