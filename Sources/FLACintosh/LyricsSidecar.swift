import Foundation
import SyncedLyrics

/// Where fetched lyrics are put, and how they get there.
///
/// Always as an `.lrc` next to the audio file: that is where the app looks
/// first anyway, so the result survives a restart, can be corrected by hand,
/// and is read by anything else that understands sidecars. Only a folder
/// that cannot be written to falls back to a cache.
enum LyricsSidecar {
    /// Fetch and store, returning what to show as the source.
    static func fetch(
        title: String,
        artist: String,
        album: String,
        duration: TimeInterval,
        for url: URL
    ) async -> Result<String, Failure> {
        let query = LyricsQuery(title: title, artist: artist, album: album, duration: duration)
        guard let found = await LyricsFetcher.fetch(query) else {
            return .failure(.notFound)
        }
        guard !EnhancedLRC.parse(found.lrc).isEmpty else {
            return .failure(.unusable(found.provider))
        }
        guard let source = write(found.lrc, for: url) else {
            return .failure(.notWritable)
        }
        return .success(source)
    }

    enum Failure: Error, Equatable {
        case notFound
        case unusable(String)
        case notWritable

        var message: String {
            switch self {
            case .notFound: "No provider had lyrics for this track"
            case .unusable(let provider): "\(provider) returned lyrics with no timings"
            case .notWritable: "Could not write the lyrics anywhere"
            }
        }
    }

    static func write(_ lrc: String, for url: URL) -> String? {
        // A track on a server has no folder to sit next to.
        if url.isFileURL {
            let sidecar = url.deletingPathExtension().appendingPathExtension("lrc")
            if (try? lrc.write(to: sidecar, atomically: true, encoding: .utf8)) != nil {
                return sidecar.lastPathComponent
            }
        }
        guard let cached = cacheURL(for: url) else { return nil }
        try? FileManager.default.createDirectory(
            at: cached.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard (try? lrc.write(to: cached, atomically: true, encoding: .utf8)) != nil else {
            return nil
        }
        return "fetched (cached)"
    }

    /// Where fetched lyrics go when the music folder cannot be written to —
    /// a NAS mount, a read-only volume, someone else's library.
    static func cacheURL(for url: URL) -> URL? {
        guard
            let support = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first
        else { return nil }

        // The path identifies a local file or a Jellyfin stream, but not a
        // Subsonic one: every Navidrome track streams from `/rest/stream`,
        // told apart only by its `id` parameter. Keyed on the path alone,
        // one fetched `.lrc` became the lyrics of every Navidrome song. The
        // other parameters are credentials that change with each request.
        var identity = url.path
        if !url.isFileURL,
           let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?
               .queryItems?.first(where: { $0.name == "id" })?.value {
            identity += "?id=\(id)"
        }

        // FNV-1a rather than `hashValue`: Swift seeds its hashing per
        // process, so a cached file would be unfindable on the next launch.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in identity.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100_0000_01b3
        }
        return support
            .appendingPathComponent("macos-music-player/lyrics", isDirectory: true)
            .appendingPathComponent(String(format: "%016llx.lrc", hash))
    }

    /// Whether this file already has words to show.
    static func exists(for url: URL) -> Bool {
        if url.isFileURL {
            let sidecar = url.deletingPathExtension().appendingPathExtension("lrc")
            if FileManager.default.fileExists(atPath: sidecar.path) { return true }
        }
        guard let cached = cacheURL(for: url) else { return false }
        return FileManager.default.fileExists(atPath: cached.path)
    }
}
