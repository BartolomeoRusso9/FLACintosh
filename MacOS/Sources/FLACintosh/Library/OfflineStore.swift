import Foundation
import Observation

/// Server albums downloaded to this Mac, to play without the server — on a
/// train, or with the server switched off.
///
/// Each track is kept whole under Application Support, named by its stable
/// key; a manifest remembers which tracks are here and, for each album,
/// everything needed to show it with the server out of reach: names, track
/// list and cover. Playing a server track looks here first (see
/// `PlaybackModel.localCopy`), so a downloaded album plays from disk even
/// while the server is up — gapless, and through the equalizer graph.
@MainActor
@Observable
final class OfflineStore {
    struct SavedTrack: Codable, Hashable, Sendable {
        var url: String
        var title: String
        var artist: String
        var albumArtist: String
        var album: String
        var trackNumber: Int?
        var discNumber: Int?
        var duration: Double?
    }

    struct SavedAlbum: Codable, Hashable, Sendable {
        var id: String
        var title: String
        var artist: String
        var year: String?
        var sourceKey: String
        var downloadedAt: Date
        var cover: Data?
        var tracks: [SavedTrack]
    }

    private struct Manifest: Codable {
        /// Track key → file name in the folder.
        var files: [String: String] = [:]
        var albums: [String: SavedAlbum] = [:]
    }

    struct Progress: Equatable {
        var done: Int
        var total: Int
    }

    private var manifest = Manifest()
    /// Albums downloading, and how far along.
    private(set) var progress: [String: Progress] = [:]
    private(set) var lastError: String?
    /// Bytes on disk, refreshed as files come and go.
    private(set) var size: Int64 = 0

    @ObservationIgnored private var queue: [LibraryAlbum] = []
    @ObservationIgnored private var worker: Task<Void, Never>?

    static var folder: URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let folder = support.appendingPathComponent("FLACintosh/Offline", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static var manifestURL: URL? { folder?.appendingPathComponent("manifest.json") }

    init() {
        if let url = Self.manifestURL, let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode(Manifest.self, from: data) {
            manifest = saved
        }
        measure()
    }

    // MARK: - Reading

    /// The downloaded copy of a server track, if there is one on disk.
    func localFile(for url: URL) -> URL? {
        guard !url.isFileURL,
              let name = manifest.files[LibraryTrack.key(for: url)],
              let file = Self.folder?.appendingPathComponent(name),
              FileManager.default.fileExists(atPath: file.path)
        else { return nil }
        return file
    }

    func isDownloaded(_ album: LibraryAlbum) -> Bool {
        !album.tracks.isEmpty && album.tracks.allSatisfy { manifest.files[$0.key] != nil }
    }

    func isDownloading(_ album: LibraryAlbum) -> Bool {
        progress[album.id] != nil
    }

    var albumCount: Int { manifest.albums.count }

    /// Downloaded albums, rebuilt as library albums — what the Downloaded
    /// shelf shows, with or without the server.
    var albums: [LibraryAlbum] {
        manifest.albums.values.map { saved in
            let source = LibrarySource(key: saved.sourceKey) ?? .folder
            let tracks = saved.tracks.compactMap { track -> LibraryTrack? in
                guard let url = URL(string: track.url) else { return nil }
                return LibraryTrack(
                    id: url,
                    title: track.title,
                    artist: track.artist,
                    albumArtist: track.albumArtist,
                    album: track.album,
                    trackNumber: track.trackNumber,
                    discNumber: track.discNumber,
                    duration: track.duration,
                    hasLyrics: false,
                    source: source
                )
            }
            return LibraryAlbum(
                id: saved.id,
                title: saved.title,
                artist: saved.artist,
                tracks: tracks,
                cover: saved.cover,
                addedAt: saved.downloadedAt,
                year: saved.year,
                source: source
            )
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    // MARK: - Downloading

    func download(_ album: LibraryAlbum) {
        guard album.source != .folder, !isDownloading(album) else { return }
        lastError = nil
        progress[album.id] = Progress(done: 0, total: album.tracks.count)
        queue.append(album)
        startWorker()
    }

    func cancel(_ album: LibraryAlbum) {
        queue.removeAll { $0.id == album.id }
        progress[album.id] = nil
    }

    func remove(_ album: LibraryAlbum) {
        cancel(album)
        let otherKeys = Set(manifest.albums.values
            .filter { $0.id != album.id }
            .flatMap { $0.tracks.compactMap { URL(string: $0.url).map(LibraryTrack.key(for:)) } })
        for track in album.tracks {
            let key = track.key
            // A track also in another downloaded album stays.
            guard !otherKeys.contains(key), let name = manifest.files[key] else { continue }
            if let file = Self.folder?.appendingPathComponent(name) {
                try? FileManager.default.removeItem(at: file)
            }
            manifest.files[key] = nil
        }
        manifest.albums[album.id] = nil
        save()
        measure()
    }

    func removeAll() {
        queue.removeAll()
        worker?.cancel()
        worker = nil
        progress = [:]
        if let folder = Self.folder { try? FileManager.default.removeItem(at: folder) }
        manifest = Manifest()
        save()
        measure()
    }

    private func startWorker() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            while let self, !Task.isCancelled, !self.queue.isEmpty {
                let album = self.queue.removeFirst()
                await self.fetch(album)
            }
            self?.worker = nil
        }
    }

    /// One track at a time: a lossless album is a few hundred megabytes, and
    /// the server has other people to serve.
    private func fetch(_ album: LibraryAlbum) async {
        guard let folder = Self.folder else { return }
        var failed = 0

        for track in album.tracks {
            // Cancelled from the album page.
            guard progress[album.id] != nil, !Task.isCancelled else { return }
            let key = track.key
            if manifest.files[key] == nil {
                do {
                    let (temporary, response) = try await URLSession.shared.download(from: track.url)
                    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                        throw MusicServerError.badResponse("The server refused to send \(track.title)")
                    }
                    let name = "\(RemoteCache.fingerprint(track.url)).\(RemoteCache.fileExtension(for: http, url: track.url))"
                    let destination = folder.appendingPathComponent(name)
                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.moveItem(at: temporary, to: destination)
                    manifest.files[key] = name
                    save()
                } catch {
                    failed += 1
                    lastError = error.localizedDescription
                }
            }
            if var current = progress[album.id] {
                current.done = min(current.done + 1, current.total)
                progress[album.id] = current
            }
        }

        manifest.albums[album.id] = SavedAlbum(
            id: album.id,
            title: album.title,
            artist: album.artist,
            year: album.year,
            sourceKey: album.source.key,
            downloadedAt: .now,
            cover: album.cover,
            tracks: album.tracks.map {
                SavedTrack(url: LibraryTrack.storable($0.url), title: $0.title, artist: $0.artist, albumArtist: $0.albumArtist,
                           album: $0.album, trackNumber: $0.trackNumber, discNumber: $0.discNumber, duration: $0.duration)
            }
        )
        if failed > 0 { lastError = "\(failed) of \(album.tracks.count) tracks of \(album.title) could not be downloaded" }
        progress[album.id] = nil
        save()
        measure()
    }

    // MARK: - Disk

    private func save() {
        guard let url = Self.manifestURL, let data = try? JSONEncoder().encode(manifest) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func measure() {
        guard let folder = Self.folder,
              let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])
        else { size = 0; return }
        size = files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
}
