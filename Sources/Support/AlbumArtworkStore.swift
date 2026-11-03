import AppKit
import Combine

@MainActor final class AlbumArtworkStore: ObservableObject {
    typealias Loader = @Sendable (AlbumArtworkReference) async throws -> AlbumArtwork?
    @Published private(set) var image: NSImage?
    @Published private(set) var dominantHex: String?
    @Published private(set) var status = "确认歌曲后，从专辑封面提取配色。"
    @Published private(set) var loading = false
    private var enabled = false
    private var reference: AlbumArtworkReference?
    private var request = UUID()
    private var task: Task<Void, Never>?
    private let loader: Loader

    init(client: AlbumArtworkClient = AlbumArtworkClient()) {
        loader = { reference in try await client.load(reference) }
    }
    init(loader: @escaping Loader) { self.loader = loader }
    deinit { task?.cancel() }

    func update(enabled: Bool, reference: AlbumArtworkReference?, force: Bool = false) {
        guard force || self.enabled != enabled || self.reference != reference else { return }
        self.enabled = enabled; self.reference = reference
        task?.cancel(); task = nil; request = UUID()
        image = nil; dominantHex = nil; loading = false
        guard enabled else { status = "确认歌曲后，从专辑封面提取配色。"; return }
        guard let reference else { status = "暂无可靠封面，使用下方自定义配色。"; return }
        let token = request, load = loader
        status = "正在读取当前专辑封面…"; loading = true
        task = Task { [weak self] in
            do {
                let artwork = try await load(reference)
                guard let self, !Task.isCancelled, self.request == token else { return }
                if let artwork, let image = NSImage(data: artwork.imageData) {
                    self.image = image; self.dominantHex = artwork.dominantHex
                    self.status = "已跟随当前专辑封面配色。"
                } else { self.status = "暂无可靠封面，使用下方自定义配色。" }
                self.loading = false; self.task = nil
            } catch {
                guard let self, !Task.isCancelled, self.request == token else { return }
                self.status = "封面暂时无法读取，使用下方自定义配色。"
                self.loading = false; self.task = nil
            }
        }
    }
    func retry() { update(enabled: enabled, reference: reference, force: true) }
}
