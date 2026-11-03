import Foundation

@main
enum SpeechCancellationTests {
    @MainActor
    static func main() async throws {
        let engine = SpeechEngine()
        for _ in 0..<3 {
            let start = Task {
                try await engine.start(language: "en-US", onCaption: { _ in
                    preconditionFailure("No audio was fed; canceled startup must never emit a caption.")
                }, onStatus: { _ in })
            }
            try await Task.sleep(nanoseconds: 1_000_000)
            start.cancel()
            await engine.stop()
            do {
                try await start.value
                // Preparation can finish before cancellation on a warm system;
                // stop must still leave the next session usable.
            } catch is CancellationError { }
        }
        try await engine.start(language: "en-US", onCaption: { _ in }, onStatus: { _ in })
        await engine.stop()
        await engine.stop()
        print("Speech cancellation: three interrupted starts, restart and repeated stop passed")
    }
}
