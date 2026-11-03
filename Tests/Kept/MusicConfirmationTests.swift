import Foundation

@main
struct MusicConfirmationTests {
    static var failures = 0
    static var checks = 0

    static func expect(_ value: Bool, _ message: String) {
        checks += 1
        if !value { failures += 1; print("FAIL: \(message)") }
    }

    static func match(_ id: String = "dandelion", at time: Double, position: Double? = nil) -> MusicMatch {
        var result = MusicMatch(title: id == "dandelion" ? "蒲公英的约定" : "Poprocks",
                                artist: id == "dandelion" ? "周杰伦" : "Other Artist",
                                duration: nil, position: position,
                                matchedAt: Date(timeIntervalSince1970: 1_000 + time))
        result.catalogKey = id
        return result
    }

    static func main() {
        var state = MusicConfirmation()
        expect(!state.observe(match(at: 0, position: 30)), "the first fingerprint is only a candidate")
        expect(state.observe(match(at: 6, position: 36)), "two independent consistent samples confirm the song")
        expect(state.observe(match(at: 12, position: 42)), "an accepted song advances without requiring another pair")

        expect(!state.observe(match("poprocks", at: 18, position: 80)), "a single Poprocks false positive cannot replace the accepted Chinese song")
        expect(state.observe(match(at: 24, position: 54)), "the previously accepted song recovers after one unrelated false positive")
        expect(!state.observe(match("poprocks", at: 30, position: 92)), "an intervening accepted-song result interrupts the new-song candidate")
        expect(state.observe(match("poprocks", at: 36, position: 98)), "two consecutive coherent samples can confirm a real song change")

        state.reset()
        for step in 0..<6 {
            let id = step.isMultiple(of: 2) ? "dandelion" : "poprocks"
            expect(!state.observe(match(id, at: Double(step * 6), position: Double(step * 6 + 20))), "alternating IDs never confirm, step \(step)")
        }

        state.reset()
        expect(!state.observe(match(at: 0, position: 30)), "overlap test starts with a candidate")
        expect(!state.observe(match(at: 0, position: 30)), "repeating the exact sample does not add a vote")
        expect(!state.observe(match(at: 5.999, position: 35.999)), "overlapping samples less than six seconds apart cannot confirm")
        expect(state.observe(match(at: 6, position: 36)), "overlapping observations do not move the original pending anchor")
        expect(!state.observe(match(at: 8, position: 38)), "an accepted song still rejects overlapping confirmation samples")
        expect(state.observe(match(at: 12, position: 42)), "overlapping observations do not move the accepted anchor")

        state.reset()
        for step in 0..<4 {
            expect(!state.observe(match("poprocks", at: Double(step * 6), position: 80)), "repeated wrong IDs with static offsets never confirm, step \(step)")
        }

        state.reset()
        expect(!state.observe(match(at: 0, position: 30)), "offset discontinuity test starts with a candidate")
        expect(state.observe(match(at: 6, position: 36)), "offset discontinuity test confirms its initial song")
        expect(!state.observe(match(at: 12, position: 10)), "a seek or inconsistent offset withdraws confirmation")
        expect(state.observe(match(at: 18, position: 16)), "two coherent post-seek samples reconfirm the song")
        expect(!state.observe(match(at: 20, position: 90)), "even an overlapping sample cannot silently introduce a large offset jump")
        expect(state.observe(match(at: 26, position: 96)), "an overlapping discontinuity requires a new independent confirmation")

        state.reset()
        expect(!state.observe(match(at: 0, position: 30)), "time reversal test starts with a candidate")
        expect(state.observe(match(at: 6, position: 36)), "time reversal test confirms its initial song")
        expect(!state.observe(match(at: 4, position: 34)), "a backward capture timestamp withdraws confirmation")
        expect(state.observe(match(at: 10, position: 40)), "a backward timestamp requires two new coherent samples")
        expect(!state.observe(match("poprocks", at: 16, position: 50)), "a different candidate records the most recent capture time")
        expect(!state.observe(match(at: 15, position: 45)), "an out-of-order return to the accepted ID also withdraws confirmation")
        expect(state.observe(match(at: 21, position: 51)), "out-of-order observations require reconfirmation from a new anchor")

        state.reset()
        expect(!state.observe(match(at: 0, position: 30)), "expiry test starts with a candidate")
        expect(!state.observe(match(at: 46, position: 76)), "a pending anchor older than 45 seconds cannot confirm")
        expect(state.observe(match(at: 52, position: 82)), "a fresh second sample confirms after pending expiry")
        expect(!state.observe(match(at: 98, position: 128)), "an accepted anchor older than 45 seconds must be reconfirmed")
        expect(state.observe(match(at: 104, position: 134)), "two fresh samples restore an expired accepted song")

        state.reset()
        expect(!state.observe(match(at: 0, position: 30)), "boundary test starts with a candidate")
        expect(state.observe(match(at: 45, position: 77.5)), "45-second interval and 2.5-second offset tolerance are inclusive")
        expect(!state.observe(match(at: 51, position: 86.0001)), "offset error above 2.5 seconds withdraws confirmation")

        state.reset()
        expect(!state.observe(match(at: 0, position: 30)), "missing-position test starts with a candidate")
        expect(!state.observe(match(at: 6)), "a match without a playhead cannot confirm")
        expect(!state.observe(match(at: 12, position: 42)), "a missing playhead interrupts pending confirmation")
        expect(state.observe(match(at: 18, position: 48)), "two valid consecutive positions confirm after missing data")
        for invalid in [Double.nan, Double.infinity, -1] {
            state.reset()
            expect(!state.observe(match(at: 0, position: invalid)), "invalid playhead \(invalid) cannot seed confirmation")
            expect(!state.observe(match(at: 6, position: 36)), "a valid sample after invalid input is only the first vote")
            expect(state.observe(match(at: 12, position: 42)), "valid independent samples confirm after invalid input")
        }

        state.reset()
        expect(!state.observe(match(at: 0, position: 30)), "reset test starts with a candidate")
        expect(state.observe(match(at: 6, position: 36)), "reset test confirms its initial song")
        state.reset()
        expect(!state.observe(match(at: 12, position: 42)), "reset clears accepted identity and its confirmation history")
        expect(state.observe(match(at: 18, position: 48)), "confirmation can restart after reset")

        if failures > 0 { print("\(failures) of \(checks) music confirmation checks failed"); exit(1) }
        print("All \(checks) music confirmation checks passed")
    }
}
