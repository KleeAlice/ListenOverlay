import Foundation

struct MusicConfirmation {
    private struct Anchor {
        let identity: String
        let position: Double
        let capturedAt: Date
    }

    private enum Progress { case independent, overlapping, inconsistent }
    private var accepted: Anchor?
    private var pending: Anchor?
    private var lastCapturedAt: Date?

    /// Returns true only for a confirmed identity with a consistent playback clock.
    /// Call reset when capture continuity is lost, such as pause, stop, or no match.
    mutating func observe(_ match: MusicMatch) -> Bool {
        guard match.matchedAt.timeIntervalSinceReferenceDate.isFinite else {
            reset()
            return false
        }
        let wentBackwards = lastCapturedAt.map { match.matchedAt < $0 } ?? false
        lastCapturedAt = match.matchedAt
        guard let position = match.position, position.isFinite, position >= 0 else {
            pending = nil
            if wentBackwards { accepted = nil }
            return false
        }
        let current = Anchor(identity: match.identity, position: position, capturedAt: match.matchedAt)
        if wentBackwards {
            accepted = nil
            pending = current
            return false
        }

        if let accepted, accepted.identity == current.identity {
            switch Self.progress(from: accepted, to: current) {
            case .independent:
                self.accepted = current
                pending = nil
                return true
            case .overlapping:
                pending = nil
                return false
            case .inconsistent:
                self.accepted = nil
                pending = current
                return false
            }
        }

        if let pending, pending.identity == current.identity {
            switch Self.progress(from: pending, to: current) {
            case .independent:
                accepted = current
                self.pending = nil
                return true
            case .overlapping:
                return false
            case .inconsistent:
                break
            }
        }
        pending = current
        return false
    }

    mutating func reset() {
        accepted = nil
        pending = nil
        lastCapturedAt = nil
    }

    private static func progress(from previous: Anchor, to current: Anchor) -> Progress {
        let elapsed = current.capturedAt.timeIntervalSince(previous.capturedAt)
        guard elapsed >= 0, elapsed <= 45,
              abs(current.position - previous.position - elapsed) <= 2.5 else { return .inconsistent }
        return elapsed >= 6 ? .independent : .overlapping
    }
}
