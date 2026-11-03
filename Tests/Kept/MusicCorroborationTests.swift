import Foundation

@main
struct MusicCorroborationTests {
    static var checks = 0
    static var failures = 0

    static func expect(_ value: Bool, _ message: String) {
        checks += 1
        if !value { failures += 1; print("FAIL: \(message)") }
    }

    static func match(_ title: String, _ artist: String, titleAliases: [String] = [], artistAliases: [String] = []) -> MusicMatch {
        var value = MusicMatch(title: title, artist: artist, duration: 238, position: 51,
                               matchedAt: Date(timeIntervalSince1970: 1_700_000_000))
        value.catalogKey = "123456"
        value.titleAliases = titleAliases
        value.artistAliases = artistAliases
        return value
    }

    static func main() {
        let original = match("最长的电影", "周杰伦")
        expect(MusicCorroboration.agrees(candidate: original, reference: match("最長的電影", "周杰倫")), "traditional and simplified native names agree")
        expect(MusicCorroboration.agrees(candidate: original, reference: match("  最 長 的 電 影！", " 周杰倫 ")), "spacing and punctuation do not change work identity")
        expect(MusicCorroboration.agrees(candidate: match("Don't Stop!", "TEST ARTIST"), reference: match("dont stop", "test artist")), "case and punctuation normalize without a translation guess")
        expect(MusicCorroboration.agrees(candidate: match("Ａ Song", "Ａ Artist"), reference: match("a song", "a artist")), "full-width Latin forms normalize")
        let localized = match("The Longest Movie (Live)", "Jay Chou", titleAliases: ["最長的電影 (Live)"], artistAliases: ["周杰倫"])
        expect(MusicCorroboration.agrees(candidate: original, reference: localized), "same recognized catalog ID may supply native work aliases")
        for suffix in [" (Live)", "（LIVE）", " [Live Version]", "【現場版】", " (现场)"] {
            expect(MusicCorroboration.agrees(candidate: original, reference: match("最長的電影" + suffix, "周杰倫")), "an explicit bracketed live label is ignored for work comparison only: \(suffix)")
        }
        expect(!MusicCorroboration.agrees(candidate: match("约", "Dreamer"), reference: match("蒲公英的約定 (Live)", "周杰倫")), "observed Dreamer false positive is rejected")
        expect(!MusicCorroboration.agrees(candidate: match("蒲公英的约定", "Dreamer"), reference: match("蒲公英的約定", "周杰倫")), "same title does not excuse a different artist")
        expect(!MusicCorroboration.agrees(candidate: match("【AIHANNI 范玉欣cover】搁浅 Step Aside", "cwjfyn"), reference: match("擱淺", "周杰倫")), "observed AI cover is rejected")
        expect(!MusicCorroboration.agrees(candidate: match("搁浅", "cwjfyn"), reference: match("擱淺", "周杰倫")), "cover artist remains different even if its title is cleaned upstream")
        expect(!MusicCorroboration.agrees(candidate: original, reference: match("The Longest Movie", "Jay Chou")), "romanization or translation without explicit aliases is unknown")
        expect(!MusicCorroboration.agrees(candidate: original, reference: nil), "missing independent result fails closed")
        expect(!MusicCorroboration.agrees(candidate: match("Forever", "Example Artist"), reference: match("Live Forever", "Example Artist")), "Live inside the actual work title is never discarded")
        expect(!MusicCorroboration.agrees(candidate: match("and Let Die", "Example Artist"), reference: match("Live and Let Die", "Example Artist")), "unbracketed Live is not a removable version label")
        expect(!MusicCorroboration.agrees(candidate: match("Song", "Example Artist"), reference: match("Song (A New Beginning)", "Example Artist")), "an ordinary bracketed subtitle is significant")
        expect(!MusicCorroboration.agrees(candidate: match("Resume", "Artist"), reference: match("Résumé", "Artist")), "diacritics are not guessed away")
        for title in ["", "   ", "---", "最长的电影 2", "最长的电影 (Remix)", "最长的电影 (Live Acoustic)", "最长的电影 (Live at Unknown Venue)", "最长的电影 Live", "最长的电影 (伴奏)", "最长的电影 (Cover)"] {
            expect(!MusicCorroboration.agrees(candidate: original, reference: match(title, "周杰伦")), "unknown or extra title content is not discarded: \(title)")
        }
        for artist in ["", "--", "周杰伦翻唱", "周杰伦 / 費玉清", "周杰伦 &", "周杰伦 / 周杰伦"] {
            expect(!MusicCorroboration.agrees(candidate: original, reference: match(original.title, artist)), "unknown, extra, malformed or duplicate artist credits fail closed: \(artist)")
        }
        let duet = match("千里之外", "周杰伦 / 费玉清")
        expect(MusicCorroboration.agrees(candidate: duet, reference: match("千里之外 (Live)", "費玉清 & 周杰倫")), "the entire collaborative artist set must agree, independent of order")
        expect(MusicCorroboration.agrees(candidate: duet, reference: match("千里之外", "周杰倫 feat. 費玉清")), "explicit featuring still retains both credited artists")
        expect(!MusicCorroboration.agrees(candidate: duet, reference: match("千里之外", "周杰倫")), "one artist from a duet cannot corroborate the duet")
        expect(!MusicCorroboration.agrees(candidate: duet, reference: match("千里之外", "周杰倫 / 另一位")), "one shared artist cannot corroborate a different duet")
        expect(!MusicCorroboration.agrees(candidate: match("千里之外", "周杰伦"), reference: match("千里之外", "Jay Chou & Fei Yu-Ching", artistAliases: ["周杰倫"])), "an incomplete alias cannot drop the primary reference's collaborator")
        expect(MusicCorroboration.agrees(candidate: duet, reference: match("Far Away", "Jay Chou & Fei Yu-Ching", titleAliases: ["千里之外"], artistAliases: ["周杰倫 / 費玉清"])), "same-ID complete duet aliases may corroborate")
        var noID = localized
        noID.catalogKey = nil
        expect(!MusicCorroboration.agrees(candidate: original, reference: noID), "aliases without a recognized catalog identity are not trusted")
        noID.appleMusicID = "536029726"
        expect(MusicCorroboration.agrees(candidate: original, reference: noID), "an exact Apple song ID can establish the alias provenance contract")
        for invalidID in ["", "0", "-1", "unknown", "netease:123456"] {
            noID.appleMusicID = invalidID
            expect(!MusicCorroboration.agrees(candidate: original, reference: noID), "unknown alias provenance fails closed: \(invalidID)")
        }
        var spoofed = match("约", "Dreamer", titleAliases: [original.title], artistAliases: [original.artist])
        spoofed.catalogKey = "netease:2049141298"
        expect(!MusicCorroboration.agrees(candidate: spoofed, reference: localized), "candidate aliases cannot replace its top1 title and artist")
        let differentClock = MusicMatch(title: "最长的电影 (Live)", artist: "周杰伦", duration: nil,
                                       position: 199, matchedAt: Date(timeIntervalSince1970: 123))
        expect(MusicCorroboration.agrees(candidate: original, reference: differentClock), "work corroboration does not infer a recording duration")
        expect(original.title == "最长的电影" && original.artist == "周杰伦" && original.position == 51 && original.duration == 238,
               "comparison leaves the candidate title, artist, duration and timeline unchanged")
        if failures > 0 { print("\(failures) of \(checks) music corroboration checks failed"); exit(1) }
        print("All \(checks) music corroboration checks passed")
    }
}
