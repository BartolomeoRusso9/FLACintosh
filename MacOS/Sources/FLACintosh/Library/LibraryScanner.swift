import Foundation
import SFBAudioEngine

/// Walks a folder and reads what is in it, off the main thread.
enum LibraryScanner {
    /// Extensions worth opening. Asking the decoder would be more correct
    /// and much slower: `AudioFile` opens and parses, and a library folder
    /// is full of `.jpg` and `.lrc` that would each pay for it.
    static let audioExtensions: Set<String> = [
        "flac", "m4a", "mp3", "aiff", "aif", "wav", "alac", "ogg", "opus",
        "wv", "ape", "mpc", "dsf", "dff", "aac", "m4b", "shn", "tta",
    ]

    struct Batch: Sendable {
        var tracks: [LibraryTrack]
        /// Thumbnails, keyed by album id — one per record, not one per file.
        var covers: [String: Data]
    }

    /// The album an id belongs to: artist and title, folded so that "The
    /// Weeknd" and "the weeknd" are one artist and not two.
    static func albumID(artist: String, album: String) -> String {
        "\(artist.lowercased())\u{1F}\(album.lowercased())"
    }

    // MARK: - Walking

    static func audioFiles(under root: URL) async -> [URL] {
        await Task.detached(priority: .utility) { walk(root) }.value
    }

    /// Synchronous by necessity: `FileManager`'s enumerator is an old-style
    /// iterator and Swift 6 will not let one be driven from an async context.
    private static func walk(_ root: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        guard
            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )
        else { return [] }

        var found: [URL] = []
        for case let url as URL in enumerator {
            guard audioExtensions.contains(url.pathExtension.lowercased()) else { continue }
            found.append(url)
        }
        return found
    }

    // MARK: - Reading

    /// Reads tags in parallel and hands back batches as they finish.
    ///
    /// Batched rather than one-by-one because every batch redraws the grid,
    /// and a redraw per file on a fast disk is the same mistake that froze
    /// the lyrics view — just spread over a scan instead of a frame.
    static func read(_ files: [URL], batchSize: Int = 24) -> AsyncStream<Batch> {
        AsyncStream { continuation in
            let work = Task.detached(priority: .utility) {
                var seenCovers: Set<String> = []
                var batch = Batch(tracks: [], covers: [:])

                for chunk in files.chunked(into: batchSize) {
                    if Task.isCancelled { break }

                    let scanned = await withTaskGroup(of: Scanned?.self) { group in
                        for url in chunk {
                            group.addTask { Self.scan(url) }
                        }
                        var results: [Scanned] = []
                        for await result in group {
                            if let result { results.append(result) }
                        }
                        return results
                    }

                    // Serial on purpose: deciding which file supplies a
                    // record's cover, and encoding that one thumbnail, is
                    // cheap — doing it concurrently would mean four workers
                    // racing to be the sleeve of the same album.
                    for item in scanned.sorted(by: { $0.track.id.path < $1.track.id.path }) {
                        batch.tracks.append(item.track)
                        let id = albumID(artist: item.track.albumArtist, album: item.track.album)
                        if !seenCovers.contains(id), let cover = item.cover,
                           let thumbnail = Artwork.thumbnailData(from: cover) {
                            seenCovers.insert(id)
                            batch.covers[id] = thumbnail
                        }
                    }

                    continuation.yield(batch)
                    batch = Batch(tracks: [], covers: [:])
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    private struct Scanned: Sendable {
        var track: LibraryTrack
        /// The full-size picture, thrown away as soon as a thumbnail is made.
        var cover: Data?
    }

    private static func scan(_ url: URL) -> Scanned? {
        guard let file = try? AudioFile(readingPropertiesAndMetadataFrom: url) else { return nil }
        let metadata = file.metadata
        let name = url.deletingPathExtension().lastPathComponent

        let artist = metadata.artist ?? ""
        let albumArtist = metadata.albumArtist ?? artist
        let sidecar = url.deletingPathExtension().appendingPathExtension("lrc")

        let track = LibraryTrack(
            id: url,
            title: metadata.title ?? name,
            artist: artist.isEmpty ? "Unknown Artist" : artist,
            albumArtist: albumArtist.isEmpty ? "Unknown Artist" : albumArtist,
            // A file with no album tag is still a record: the folder it sits
            // in is the closest thing to one, and it beats a shelf of
            // identical "Unknown Album" tiles.
            album: metadata.albumTitle ?? url.deletingLastPathComponent().lastPathComponent,
            trackNumber: metadata.trackNumber,
            discNumber: metadata.discNumber,
            duration: file.properties.duration,
            hasLyrics: FileManager.default.fileExists(atPath: sidecar.path)
                || !(metadata.lyrics ?? "").isEmpty
        )

        let pictures = metadata.attachedPictures
        let cover = (pictures.first { $0.type == .frontCover } ?? pictures.first)?.imageData

        return Scanned(track: track, cover: cover)
    }

    // MARK: - Grouping

    static func group(_ tracks: [LibraryTrack], covers: [String: Data]) -> [LibraryAlbum] {
        let modified = Dictionary(
            uniqueKeysWithValues: tracks.map {
                ($0.id, (try? $0.id.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast)
            }
        )

        return Dictionary(grouping: tracks) { albumID(artist: $0.albumArtist, album: $0.album) }
            .map { id, tracks in
                LibraryAlbum(
                    id: id,
                    title: tracks[0].album,
                    artist: tracks[0].albumArtist,
                    tracks: tracks.sorted {
                        ($0.discNumber ?? 1, $0.trackNumber ?? 0, $0.title)
                            < ($1.discNumber ?? 1, $1.trackNumber ?? 0, $1.title)
                    },
                    cover: covers[id],
                    addedAt: tracks.map { modified[$0.id] ?? .distantPast }.max() ?? .distantPast
                )
            }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}
