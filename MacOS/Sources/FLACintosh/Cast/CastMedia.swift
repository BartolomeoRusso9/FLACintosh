import AVFoundation
import CryptoKit
import Foundation
import Network
import SFBAudioEngine

/// Turns whatever the player is holding into something a Cast receiver can
/// fetch and decode.
///
/// Google's Default Media Receiver plays FLAC, MP3, AAC, Vorbis, Opus and
/// WAV, up to 96 kHz and 24 bits. A library holds more than that — ALAC,
/// AIFF, APE, WavPack, DSD, 192 kHz masters — so:
///
/// - a server track the receiver can play goes to it straight from the
///   server, and keeps playing with this Mac asleep;
/// - anything else is made into a FLAC it can play (downsampled if it has
///   to be) and served from this Mac.
enum CastMedia {
    struct Prepared: Sendable {
        var url: URL
        var contentType: String
        var title: String
        var artist: String
        var albumArtist: String
        var album: String
        var trackNumber: Int?
        var duration: TimeInterval?
        var artworkURL: URL?
        /// Served from this Mac rather than straight from a server.
        var viaMac: Bool
    }

    enum Failure: LocalizedError {
        case unreadable
        case conversion(String)

        var errorDescription: String? {
            switch self {
            case .unreadable: "This file cannot be read for casting"
            case .conversion(let detail): "Could not convert this track for casting: \(detail)"
            }
        }
    }

    /// - parameter host: this Mac's address as the Cast device sees it.
    /// - parameter viaMac: fetch a server track here first even if the
    ///   receiver could have played it — the fallback after it refused to.
    static func prepare(
        _ source: URL,
        listed: LibraryTrack?,
        host: String,
        viaMac: Bool
    ) async throws -> Prepared {
        let server = CastMediaServer.shared
        let port = try await server.start()
        let base = "http://\(host):\(port)"

        var prepared = Prepared(
            url: source,
            contentType: "audio/flac",
            title: listed?.title ?? source.deletingPathExtension().lastPathComponent,
            artist: listed?.artist ?? "",
            albumArtist: listed?.albumArtist ?? listed?.artist ?? "",
            album: listed?.album ?? "",
            trackNumber: listed?.trackNumber,
            duration: listed?.duration,
            artworkURL: nil,
            viaMac: false
        )

        if !source.isFileURL {
            // The tags live at the front of the file; the player has usually
            // fetched them already for Now Playing.
            let inspected = (try? await RemoteCache.header(for: source)).flatMap { inspect($0) }
            let artwork = await reachable(listed?.artworkURL)
            prepared.artworkURL = artwork ?? inspected?.cover.map { URL(string: base + server.publish(data: $0, contentType: "image/jpeg"))! }

            if !viaMac, source.scheme == "http", let direct = await reachable(source) {
                let contentType = await remoteContentType(direct) ?? inspected?.contentType
                if let contentType, inspected?.castable ?? castableType(contentType) {
                    prepared.url = direct
                    prepared.contentType = contentType
                    return prepared
                }
            }
            // HTTPS with a certificate the receiver does not trust, a format
            // it cannot decode, or a server name it cannot resolve: fetch it
            // here and serve it like a local file.
            let local = try await RemoteCache.file(for: source)
            return try await serveLocal(local, prepared: prepared, base: base, keepTags: true)
        }

        return try await serveLocal(source, prepared: prepared, base: base, keepTags: false)
    }

    // MARK: - Local files

    private static func serveLocal(_ file: URL, prepared: Prepared, base: String, keepTags: Bool) async throws -> Prepared {
        guard let inspected = inspect(file) else { throw Failure.unreadable }
        var prepared = prepared
        prepared.viaMac = true
        if !keepTags {
            prepared.title = inspected.title ?? prepared.title
            prepared.artist = inspected.artist ?? prepared.artist
            prepared.albumArtist = inspected.albumArtist ?? inspected.artist ?? prepared.albumArtist
            prepared.album = inspected.album ?? prepared.album
            prepared.trackNumber = inspected.trackNumber ?? prepared.trackNumber
        }
        prepared.duration = prepared.duration ?? inspected.duration
        if prepared.artworkURL == nil, let cover = inspected.cover {
            prepared.artworkURL = URL(string: base + CastMediaServer.shared.publish(data: cover, contentType: "image/jpeg"))
        }

        let playable: URL
        if inspected.castable, let type = inspected.contentType {
            playable = file
            prepared.contentType = type
        } else {
            playable = try await transcode(file, inspected: inspected)
            prepared.contentType = "audio/flac"
        }
        prepared.url = URL(string: base + CastMediaServer.shared.publish(file: playable, contentType: prepared.contentType))!
        return prepared
    }

    struct Inspection {
        var title: String?
        var artist: String?
        var albumArtist: String?
        var album: String?
        var trackNumber: Int?
        var duration: TimeInterval?
        var cover: Data?
        var contentType: String?
        var sampleRate: Double
        var bitDepth: Int
        var channels: Int
        /// Whether the receiver can decode it as it is.
        var castable: Bool
    }

    static func inspect(_ file: URL) -> Inspection? {
        guard let audio = try? AudioFile(readingPropertiesAndMetadataFrom: file) else { return nil }
        let properties = audio.properties
        let metadata = audio.metadata
        let format = (properties.formatName ?? "").lowercased()
        let ext = file.pathExtension.lowercased()

        let contentType: String? = {
            if format.contains("flac") || ext == "flac" { return format.contains("ogg") ? "audio/ogg" : "audio/flac" }
            if format.contains("mp3") || format.contains("mpeg") && (format.contains("layer 3") || format.contains("layer iii")) || ext == "mp3" { return "audio/mpeg" }
            if format.contains("aac") { return ext == "aac" ? "audio/aac" : "audio/mp4" }
            if format.contains("vorbis") { return "audio/ogg" }
            if format.contains("opus") { return "audio/ogg" }
            if (format.contains("wave") || format.contains("wav")) && ext == "wav" { return "audio/wav" }
            return nil
        }()

        let sampleRate = properties.sampleRate ?? 44100
        let bitDepth = properties.bitDepth ?? 16
        let channels = Int(properties.channelCount ?? 2)
        let picture = metadata.attachedPictures.first { $0.type == .frontCover } ?? metadata.attachedPictures.first

        return Inspection(
            title: metadata.title,
            artist: metadata.artist,
            albumArtist: metadata.albumArtist,
            album: metadata.albumTitle,
            trackNumber: metadata.trackNumber,
            duration: properties.duration,
            cover: picture?.imageData,
            contentType: contentType,
            sampleRate: sampleRate,
            bitDepth: bitDepth,
            channels: channels,
            castable: contentType != nil && sampleRate <= 96000 && bitDepth <= 24 && channels <= 2
        )
    }

    // MARK: - Conversion

    /// A FLAC the receiver can play: at most 96 kHz, 24 bits, two channels.
    /// Kept in the cache by the source's path, size and date, so the second
    /// time costs nothing.
    private static func transcode(_ file: URL, inspected: Inspection) async throws -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let folder = caches.appendingPathComponent("macos-music-player/cast", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
        let stamp = "\(file.path)|\((attributes?[.size] as? NSNumber)?.int64Value ?? 0)|\((attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
        let name = SHA256.hash(data: Data(stamp.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        let destination = folder.appendingPathComponent("\(name).flac")
        if FileManager.default.fileExists(atPath: destination.path) { return destination }

        let partial = folder.appendingPathComponent("\(name).partial.flac")
        try await Task.detached(priority: .userInitiated) {
            try? FileManager.default.removeItem(at: partial)
            do {
                try convert(file, to: partial, inspected: inspected)
            } catch {
                try? FileManager.default.removeItem(at: partial)
                throw Failure.conversion(error.localizedDescription)
            }
        }.value
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: partial, to: destination)
        trim(folder)
        return destination
    }

    private static func convert(_ source: URL, to destination: URL, inspected: Inspection) throws {
        let ext = source.pathExtension.lowercased()
        let decoder: PCMDecoding = (ext == "dsf" || ext == "dff")
            ? try DSDPCMDecoder(url: source)
            : try AudioDecoder(url: source)
        try decoder.open()
        defer { try? decoder.close() }

        let input = decoder.processingFormat
        var rate = input.sampleRate
        while rate > 96000 { rate /= 2 }
        let channels = AVAudioChannelCount(min(Int(input.channelCount), 2))
        let bits: UInt32 = inspected.bitDepth <= 16 && !(ext == "dsf" || ext == "dff") ? 16 : 24

        var description = AudioStreamBasicDescription(
            mSampleRate: rate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: (bits / 8) * channels,
            mFramesPerPacket: 1,
            mBytesPerFrame: (bits / 8) * channels,
            mChannelsPerFrame: channels,
            mBitsPerChannel: bits,
            mReserved: 0
        )
        guard let wanted = AVAudioFormat(streamDescription: &description) else { throw Failure.unreadable }

        let encoder = try AudioEncoder(url: destination)
        try encoder.setSourceFormat(wanted)
        try encoder.openReturningError()
        defer { try? encoder.close() }

        guard let converter = AVAudioConverter(from: input, to: encoder.processingFormat) else { throw Failure.unreadable }
        if input.channelCount > 2 { converter.downmix = true }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue

        let frames: AVAudioFrameCount = 4096
        guard let decoded = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: frames),
              let output = AVAudioPCMBuffer(pcmFormat: encoder.processingFormat, frameCapacity: frames)
        else { throw Failure.unreadable }

        var decodeError: Error?
        while true {
            output.frameLength = 0
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { count, inputStatus in
                do {
                    try decoder.decode(into: decoded, length: min(count, frames))
                } catch {
                    decodeError = error
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                if decoded.frameLength == 0 {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return decoded
            }
            if let decodeError { throw decodeError }
            if let conversionError { throw conversionError }
            if output.frameLength > 0 { try encoder.encode(from: output, length: output.frameLength) }
            if status == .endOfStream || status == .error || (status == .inputRanDry && output.frameLength == 0) { break }
        }
        try encoder.finish()
    }

    /// The conversions are a cache, not a copy of the library: past a
    /// gigabyte the ones cast longest ago go.
    private static func trim(_ folder: URL) {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentAccessDateKey]
        guard var files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys) else { return }
        files.sort {
            let a = (try? $0.resourceValues(forKeys: [.contentAccessDateKey]).contentAccessDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentAccessDateKey]).contentAccessDate) ?? .distantPast
            return a > b
        }
        var total: Int64 = 0
        for file in files {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            if total > 1024 * 1024 * 1024 { try? FileManager.default.removeItem(at: file) }
        }
    }

    // MARK: - Server URLs

    /// The URL with its host swapped for an IP address. Chromecasts often
    /// ask Google's DNS rather than the router's, and a name like
    /// `jellyfin.lan` means nothing there.
    private static func reachable(_ url: URL?) async -> URL? {
        guard let url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host
        else { return nil }
        if IPv4Address(host) != nil { return url }
        guard let address = await Task.detached(operation: { resolve(host) }).value else { return nil }
        components.host = address
        return components.url
    }

    private static func resolve(_ host: String) -> String? {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_STREAM, ai_protocol: 0,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return nil }
        defer { freeaddrinfo(result) }
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard let address = first.pointee.ai_addr else { return nil }
        let ipv4 = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
        var copy = ipv4
        guard inet_ntop(AF_INET, &copy, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
        return String(cString: buffer)
    }

    private static func remoteContentType(_ url: URL) async -> String? {
        var request = URLRequest(url: url)
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 8
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode)
        else { return nil }
        return http.value(forHTTPHeaderField: "Content-Type")?.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
    }

    private static func castableType(_ type: String) -> Bool {
        ["audio/flac", "audio/x-flac", "audio/mpeg", "audio/mp3", "audio/aac", "audio/ogg", "audio/opus", "audio/wav", "audio/x-wav", "audio/webm"].contains(type)
    }
}
