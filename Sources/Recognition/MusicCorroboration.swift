import Foundation

/// Work identity only. Recording version and playback progression require their own checks.
enum MusicCorroboration {
    /// `reference` is an independent Shazam result. Its aliases must come only
    /// from exact-ID enrichment, as enforced by MusicMatcher and SongMetadataClient.
    /// True means the named work agrees; it says nothing about studio/live identity.
    static func agrees(candidate: MusicMatch, reference: MusicMatch?) -> Bool {
        guard let reference,
              let candidateTitle = titleKey(candidate.title),
              let candidateArtists = artistKeys(candidate.artist),
              titleKey(reference.title) != nil,
              let referenceArtists = artistKeys(reference.artist),
              candidateArtists.count == referenceArtists.count else { return false }

        // Never use aliases to repair the candidate's top1 identity. Reference
        // aliases are alternatives for the complete credit, not extra solo artists.
        let aliasesAllowed = validCatalogID(reference.appleMusicID) || validCatalogID(reference.catalogKey)
        let titles = [reference.title] + (aliasesAllowed ? reference.titleAliases : [])
        let artists = [reference.artist] + (aliasesAllowed ? reference.artistAliases : [])
        guard titles.contains(where: { titleKey($0) == candidateTitle }) else { return false }
        return artists.contains { credit in
            guard let keys = artistKeys(credit), keys.count == referenceArtists.count else { return false }
            return keys == candidateArtists
        }
    }

    private static func validCatalogID(_ value: String?) -> Bool {
        guard let value, !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }),
              let number = UInt64(value), number > 0 else { return false }
        return true
    }

    private static func folded(_ value: String) -> String? {
        guard !value.isEmpty, value.utf8.count <= 4_096,
              let simplified = value.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) else { return nil }
        return simplified.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func compact(_ value: String) -> String? {
        let ignored = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        let scalars = value.unicodeScalars.filter { !ignored.contains($0) }
        guard scalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) else { return nil }
        return String(String.UnicodeScalarView(scalars))
    }

    private static func titleKey(_ title: String) -> String? {
        guard var value = folded(title) else { return nil }
        // Only a complete, known live label is removable. Ordinary subtitles,
        // remixes, cover credits, venue descriptions and unbracketed words stay.
        let brackets = #"\(([^()]*)\)|\[([^\[\]]*)\]|【([^【】]*)】"#
        guard let expression = try? NSRegularExpression(pattern: brackets) else { return nil }
        let matches = expression.matches(in: value, range: NSRange(value.startIndex..., in: value))
        for match in matches.reversed() {
            let contentRange = (1..<match.numberOfRanges).map { match.range(at: $0) }.first { $0.location != NSNotFound }
            guard let contentRange, let inner = Range(contentRange, in: value),
                  let key = compact(String(value[inner])),
                  ["live", "liveversion", "现场", "现场版"].contains(key),
                  let whole = Range(match.range, in: value) else { continue }
            value.removeSubrange(whole)
        }
        return compact(value)
    }

    private static func artistKeys(_ artists: String) -> Set<String>? {
        guard var value = folded(artists) else { return nil }
        // Keep every member of an explicit credit list. No substring matching or
        // transliteration is used, and a malformed/duplicate member fails closed.
        value = value.replacingOccurrences(of: #"\s+(?:feat\.?|ft\.?|featuring|and|with)\s+"#,
                                           with: "/", options: .regularExpression)
        let members = value.components(separatedBy: CharacterSet(charactersIn: "/&、,，;；+"))
        let keys = members.compactMap(compact)
        guard keys.count == members.count, !keys.isEmpty, Set(keys).count == keys.count else { return nil }
        return Set(keys)
    }
}
