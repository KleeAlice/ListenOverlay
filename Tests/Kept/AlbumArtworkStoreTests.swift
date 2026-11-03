import AppKit

private actor ArtworkGate {
    private var waiting: [AlbumArtworkReference: CheckedContinuation<AlbumArtwork?, Never>] = [:]
    private(set) var count = 0
    func load(_ key: AlbumArtworkReference) async -> AlbumArtwork? {
        count += 1
        return await withCheckedContinuation { waiting[key] = $0 }
    }
    func has(_ key: AlbumArtworkReference) -> Bool { waiting[key] != nil }
    func finish(_ key: AlbumArtworkReference, _ artwork: AlbumArtwork?) { waiting.removeValue(forKey: key)?.resume(returning: artwork) }
}

@main struct AlbumArtworkStoreTests {
    @MainActor static func main() async {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
                                      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 8, bitsPerPixel: 32)!
        for offset in stride(from: 0, to: 16, by: 4) {
            bitmap.bitmapData![offset] = 0; bitmap.bitmapData![offset + 1] = 64
            bitmap.bitmapData![offset + 2] = 255; bitmap.bitmapData![offset + 3] = 255
        }
        let data = bitmap.representation(using: .png, properties: [:])!
        let gate = ArtworkGate()
        let store = AlbumArtworkStore(loader: { await gate.load($0) })
        var failures = 0
        func expect(_ value: Bool, _ message: String) {
            if !value { failures += 1; print("FAIL:", message) }
        }
        func settle(_ condition: @escaping () async -> Bool) async {
            let limit = Date().addingTimeInterval(3)
            while !(await condition()) && Date() < limit { await Task.yield() }
            expect(await condition(), "asynchronous state reached the expected checkpoint")
        }
        store.update(enabled: false, reference: .netEase(1))
        expect(await gate.count == 0, "non-album skins do not download artwork")
        store.update(enabled: true, reference: .netEase(1))
        await settle { await gate.has(.netEase(1)) }
        store.update(enabled: true, reference: .netEase(2))
        await settle { await gate.has(.netEase(2)) }
        expect(store.image == nil && store.dominantHex == nil && store.loading, "a new song immediately clears the previous cover")
        await gate.finish(.netEase(2), AlbumArtwork(imageData: data, dominantHex: "2060C0"))
        await settle { store.dominantHex == "2060C0" }
        await gate.finish(.netEase(1), AlbumArtwork(imageData: data, dominantHex: "C02020"))
        for _ in 0..<100 { await Task.yield() }
        expect(store.dominantHex == "2060C0", "a late prior song response cannot recolor the current song")
        store.update(enabled: true, reference: .netEase(2))
        expect(await gate.count == 2, "repeated progress updates do not download the same cover again")
        store.update(enabled: true, reference: nil)
        expect(store.image == nil && store.dominantHex == nil && !store.loading, "unconfirmed songs clear old artwork immediately")
        store.update(enabled: true, reference: .apple(3))
        await settle { await gate.has(.apple(3)) }
        await gate.finish(.apple(3), nil)
        await settle { !store.loading }
        expect(store.image == nil && store.status.contains("自定义"), "missing covers explain the fallback palette")
        store.update(enabled: true, reference: .apple(4))
        await settle { await gate.has(.apple(4)) }
        store.update(enabled: false, reference: .apple(4))
        await gate.finish(.apple(4), AlbumArtwork(imageData: data, dominantHex: "2060C0"))
        for _ in 0..<100 { await Task.yield() }
        expect(store.image == nil && store.dominantHex == nil && !store.loading, "leaving album mode cancels pending recoloring")
        if failures > 0 { exit(1) }
        print("All album artwork state, cancellation and stale-result tests passed")
    }
}
