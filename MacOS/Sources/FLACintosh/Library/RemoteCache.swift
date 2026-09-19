import Foundation

/// Remote tracks, on disk — as little of them as will do.
///
/// Server tracks stream (see `PlaybackModel`), so the audio itself is not
/// kept. Two things are:
///
/// - `headers/`: the part of each file that holds its tags, lyrics and
///   sleeve, usually a megabyte or two, so Now Playing can show what a
///   local file would.
/// - `stream/`: whole files, only for formats AVFoundation cannot stream —
///   those fall back to SFBAudioEngine, which reads files, not URLs.
///
/// Both count against one limit and are emptied together.
enum RemoteCache {
    /// How much of the disk the cache may take, in bytes.
    ///
    /// Two gigabytes by default: enough for a long evening of lossless
    /// listening — a FLAC album is 250-400 MB — without quietly filling a
    /// laptop that has a server's whole library available to it.
    static let defaultLimit: Int64 = 2 * 1024 * 1024 * 1024
    private static let limitKey = "remoteCacheLimitBytes"

    static var limit: Int64 {
        get {
            let stored = UserDefaults.standard.object(forKey: limitKey) as? NSNumber
            return stored.map { Int64(truncating: $0) } ?? defaultLimit
        }
        set {
            UserDefaults.standard.set(NSNumber(value: max(0, newValue)), forKey: limitKey)
        }
    }

    /// Whole tracks.
    static func directory() -> URL? { folder("stream") }

    /// Tag headers.
    static func headersDirectory() -> URL? { folder("headers") }

    /// Everything the limit, the size and "Empty Cache" cover.
    private static var folders: [URL] {
        [directory(), headersDirectory()].compactMap { $0 }
    }

    private static func folder(_ name: String) -> URL? {
        guard
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        else { return nil }
        let folder = caches.appendingPathComponent("macos-music-player/\(name)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Fetches `url` if it is not already here, and returns the local file.
    static func file(for url: URL, session: URLSession = .shared) async throws -> URL {
        guard !url.isFileURL else { return url }
        guard let folder = directory() else { throw MusicServerError.notReachable }

        let name = fingerprint(url)
        // Already here from a previous play: the same track keeps the same
        // name, so a repeat costs nothing.
        if let existing = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil
        ).first(where: { $0.deletingPathExtension().lastPathComponent == name }) {
            touch(existing)
            return existing
        }

        let (temporary, response) = try await session.download(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw MusicServerError.badResponse("The server refused to send that track")
        }

        let destination = folder.appendingPathComponent(
            "\(name).\(fileExtension(for: http, url: url))"
        )
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
        enforceLimit()
        return destination
    }

    /// Just the start of a remote track — the part with its tags — as a
    /// local file the tag reader can open.
    ///
    /// A stream plays without the file, but title, format, lyrics and sleeve
    /// all live in the file. They are at the front, though, so this reads
    /// until the metadata ends and hangs up: for a FLAC that is its metadata
    /// blocks, mostly the embedded cover — a megabyte or two of a forty
    /// megabyte track. A truncated FLAC reads exactly like the whole one,
    /// STREAMINFO included, so the format summary is still off the decoder's
    /// own header rather than a guess.
    static func header(for url: URL, session: URLSession = .shared) async throws -> URL {
        guard !url.isFileURL else { return url }
        guard let folder = headersDirectory() else { throw MusicServerError.notReachable }

        let name = fingerprint(url)
        if let existing = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil
        ).first(where: { $0.deletingPathExtension().lastPathComponent == name }) {
            touch(existing)
            return existing
        }

        // One request, read only as far as it has to be. No Range header: a
        // server that ignores it would send the whole file anyway, and
        // stopping the read is what actually saves the bytes.
        let (bytes, response) = try await session.bytes(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw MusicServerError.badResponse("The server refused to send that track")
        }

        var data = Data()
        data.reserveCapacity(256 * 1024)
        var extent: Extent?
        for try await byte in bytes {
            data.append(byte)
            // Re-measured every 16 KB rather than every byte.
            if extent == nil, data.count % 16_384 == 0 { extent = headerExtent(of: data) }
            if case .prefix(let length) = extent, data.count >= length { break }
            if case .tail = extent { break }
            if data.count >= maxHeader { break }
        }
        bytes.task.cancel()

        let destination = folder.appendingPathComponent(
            "\(name).\(fileExtension(for: http, url: url))"
        )

        guard case .tail(let audioStart, let audioEnd) = extent else {
            try data.write(to: destination, options: .atomic)
            enforceLimit()
            return destination
        }

        // An MP4 with its `moov` after the audio — how iTunes and most ALAC
        // encoders write them. The tags are at the far end, so only that end
        // is asked for.
        var request = URLRequest(url: url)
        request.setValue("bytes=\(audioEnd)-", forHTTPHeaderField: "Range")
        let (tailBytes, tailResponse) = try await session.bytes(for: request)
        guard (tailResponse as? HTTPURLResponse)?.statusCode == 206 else {
            tailBytes.task.cancel()
            throw MusicServerError.badResponse("The server would not send part of the track")
        }
        var tail = Data()
        for try await byte in tailBytes {
            tail.append(byte)
            if tail.count >= maxHeader { break }
        }
        tailBytes.task.cancel()

        // Kept as the atoms before the audio followed straight by `moov`,
        // with no `mdat` at all. The tag reader needs neither the audio nor
        // its position — its chunk offsets go unread — and a file with a
        // hole where the audio was still took the audio's size on disk:
        // twelve megabytes to hold one megabyte of tags.
        var compact = Data(data.prefix(audioStart))
        compact.append(tail)
        try compact.write(to: destination, options: .atomic)
        enforceLimit()
        return destination
    }

    /// No cover is worth more than this; past it the tags are given up on.
    private static let maxHeader = 16 * 1024 * 1024

    /// Where a file's metadata is, as far as its first bytes can tell.
    private enum Extent {
        /// All of it within this many bytes from the start.
        case prefix(Int)
        /// After the audio, which runs from `audioStart` to `audioEnd`; the
        /// metadata is from `audioEnd` to the end of the file.
        case tail(audioStart: Int, audioEnd: Int)
    }

    /// Where the metadata is, or nil if `data` is not yet long enough to say.
    private static func headerExtent(of data: Data) -> Extent? {
        guard let length = headerLength(of: data) else {
            return mp4Extent(of: data)
        }
        return .prefix(length)
    }

    /// MP4: top-level atoms, walked by their sizes. `moov` holds the tags,
    /// the sleeve and the codec; `mdat` is the audio. Whichever comes first
    /// decides whether the tags are at the front or the back.
    private static func mp4Extent(of data: Data) -> Extent? {
        var offset = 0
        while offset + 16 <= data.count {
            let start = data.startIndex + offset
            var size = (0 ..< 4).reduce(0) { $0 << 8 | Int(data[start + $1]) }
            let type = String(decoding: data[(start + 4) ..< (start + 8)], as: UTF8.self)
            // 1 means a 64-bit size follows; 0 means "to the end of the file".
            if size == 1 { size = (8 ..< 16).reduce(0) { $0 << 8 | Int(data[start + $1]) } }
            if size == 0 { return .prefix(maxHeader) }
            guard size >= 8 else { return .prefix(2 * 1024 * 1024) }

            if type == "moov" { return .prefix(offset + size) }
            if type == "mdat" { return .tail(audioStart: offset, audioEnd: offset + size) }
            offset += size
        }
        return nil
    }

    /// How many bytes from the start hold the metadata, for the formats that
    /// keep it there; nil for MP4, which `mp4Extent` measures instead, and
    /// for data too short to say.
    private static func headerLength(of data: Data) -> Int? {
        let bytes = [UInt8](data.prefix(32))
        guard bytes.count >= 10 else { return nil }

        // ID3v2, in front of an MP3 (and sometimes a FLAC). The MPEG frames
        // after it are needed too: the sample rate and length come from the
        // first of them, not from the tag.
        if bytes[0] == 0x49, bytes[1] == 0x44, bytes[2] == 0x33 {
            let size = Int(bytes[6]) << 21 | Int(bytes[7]) << 14 | Int(bytes[8]) << 7 | Int(bytes[9])
            let footer = bytes[5] & 0x10 != 0 ? 10 : 0
            return 10 + size + footer + 128 * 1024
        }

        // FLAC: walk the metadata blocks to the one flagged last.
        if bytes[0] == 0x66, bytes[1] == 0x4C, bytes[2] == 0x61, bytes[3] == 0x43 {
            var offset = 4
            while offset + 4 <= data.count {
                let start = data.startIndex + offset
                let flags = data[start]
                let length = Int(data[start + 1]) << 16 | Int(data[start + 2]) << 8 | Int(data[start + 3])
                offset += 4 + length
                if flags & 0x80 != 0 { return offset }
            }
            return nil
        }

        if bytes[4] == 0x66, bytes[5] == 0x74, bytes[6] == 0x79, bytes[7] == 0x70 {
            return nil
        }

        // Ogg and the rest keep their tags less predictably; the first two
        // megabytes cover a Vorbis comment and most embedded pictures.
        return 2 * 1024 * 1024
    }

    /// Drops the least recently played tracks until the cache is under the
    /// limit.
    ///
    /// Ordered by modification date, which `touch` refreshes on every play:
    /// access dates cannot be relied on — a volume may be mounted `noatime`,
    /// and then everything looks equally old and eviction becomes random.
    static func enforceLimit() {
        let limit = limit
        guard limit > 0 else { return }

        // Headers and whole tracks in one queue: a header is as disposable
        // as a track — it is fetched again the next time that track plays.
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let files = folders.flatMap {
            (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: keys)) ?? []
        }

        var entries = files.compactMap { url -> (url: URL, size: Int64, date: Date)? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return (
                url,
                Int64(values.fileSize ?? 0),
                values.contentModificationDate ?? .distantPast
            )
        }
        var total = entries.reduce(Int64(0)) { $0 + $1.size }
        guard total > limit else { return }

        // Oldest first.
        entries.sort { $0.date < $1.date }
        for entry in entries {
            guard total > limit else { break }
            guard (try? FileManager.default.removeItem(at: entry.url)) != nil else { continue }
            total -= entry.size
        }
    }

    /// Marks a cached file as just used, so it is the last to be evicted.
    private static func touch(_ url: URL) {
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: url.path
        )
    }

    /// The extension matters: the decoder is chosen from it, and a FLAC
    /// saved as `.mp3` will not open.
    static func fileExtension(for response: HTTPURLResponse, url: URL) -> String {
        let type = (response.value(forHTTPHeaderField: "Content-Type") ?? "")
            .split(separator: ";").first.map(String.init)?
            .trimmingCharacters(in: .whitespaces)
            .lowercased() ?? ""

        switch type {
        case "audio/flac", "audio/x-flac": return "flac"
        case "audio/mpeg", "audio/mp3": return "mp3"
        case "audio/mp4", "audio/m4a", "audio/x-m4a": return "m4a"
        case "audio/ogg", "application/ogg": return "ogg"
        case "audio/opus": return "opus"
        case "audio/wav", "audio/x-wav": return "wav"
        case "audio/aiff", "audio/x-aiff": return "aiff"
        default: break
        }
        // Some servers send `application/octet-stream` and put the real name
        // in the disposition; the URL's own extension is the last resort.
        if let disposition = response.value(forHTTPHeaderField: "Content-Disposition"),
           let range = disposition.range(of: #"filename="?[^";]+"#, options: .regularExpression) {
            let name = String(disposition[range])
            let ext = (name as NSString).pathExtension
            if !ext.isEmpty { return ext.lowercased() }
        }
        return url.pathExtension.isEmpty ? "mp3" : url.pathExtension.lowercased()
    }

    /// FNV-1a of what identifies the track: stable across launches, unlike
    /// `hashValue`.
    ///
    /// Not of the whole URL. Stream URLs carry credentials — Jellyfin's
    /// `api_key`, a new token each login; Subsonic's `t` and `s`, a fresh
    /// salt every time a URL is built — so hashing them named the same track
    /// differently on every launch, and nothing in the cache was ever found
    /// again. Server, path and the `id` parameter are what stay put.
    static func fingerprint(_ url: URL) -> String {
        var identity = url.absoluteString
        if var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.queryItems = components.queryItems?.filter { $0.name == "id" }
            if components.queryItems?.isEmpty == true { components.queryItems = nil }
            identity = components.string ?? identity
        }

        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in identity.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }

    static func empty() {
        for folder in folders {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    static func size() -> Int64 {
        folders.reduce(0) { total, folder in
            let files = (try? FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.fileSizeKey]
            )) ?? []
            return total + files.reduce(0) {
                $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            }
        }
    }
}
