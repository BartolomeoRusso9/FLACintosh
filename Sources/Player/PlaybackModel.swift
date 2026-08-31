import Foundation
import Observation
import SFBAudioEngine
import SyncedLyrics

/// What the bar under the artwork shows.
///
/// Sample rate and bit depth are read straight off the decoder rather than
/// guessed from the extension: a `.m4a` is ALAC or AAC depending on what is
/// inside it, and the whole point of a player like this is to say which.
struct TrackInfo {
    var title: String
    var artist: String
    var album: String
    var sampleRate: Double?
    var bitDepth: Int?
    var channelCount: UInt32?
    var duration: TimeInterval?

    /// "24 bit · 96 kHz · Stereo", with the parts it actually knows.
    var formatSummary: String {
        var parts: [String] = []
        if let bitDepth { parts.append("\(bitDepth) bit") }
        if let sampleRate {
            let kHz = sampleRate / 1000
            parts.append(
                kHz == kHz.rounded()
                    ? String(format: "%.0f kHz", kHz)
                    : String(format: "%.1f kHz", kHz)
            )
        }
        switch channelCount {
        case 1: parts.append("Mono")
        case 2: parts.append("Stereo")
        case let count?: parts.append("\(count) ch")
        default: break
        }
        return parts.joined(separator: " · ")
    }
}

@MainActor
@Observable
final class PlaybackModel {
    private(set) var track: TrackInfo?
    private(set) var lyrics: TimedLyrics?
    private(set) var lyricsSource: String?
    private(set) var lastError: String?

    @ObservationIgnored private let player = AudioPlayer()

    /// Read live rather than published: the lyrics view already redraws every
    /// frame inside a `TimelineView`, so a stream of change notifications
    /// would buy nothing and cost a lot.
    var currentTime: TimeInterval { player.currentTime ?? 0 }
    var isPlaying: Bool { player.playbackState == .playing }

    func open(_ url: URL) {
        do {
            let file = try AudioFile(readingPropertiesAndMetadataFrom: url)
            let properties = file.properties
            let metadata = file.metadata

            track = TrackInfo(
                title: metadata.title ?? url.deletingPathExtension().lastPathComponent,
                artist: metadata.artist ?? "",
                album: metadata.albumTitle ?? "",
                sampleRate: properties.sampleRate,
                bitDepth: properties.bitDepth,
                channelCount: properties.channelCount,
                duration: properties.duration
            )

            let (parsed, source) = Self.loadLyrics(for: url, embedded: metadata.lyrics)
            lyrics = parsed
            lyricsSource = source

            try player.play(url)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            track = nil
            lyrics = nil
        }
    }

    func togglePlayPause() {
        try? player.togglePlayPause()
    }

    func seek(to time: TimeInterval) {
        _ = player.seek(time: time)
    }

    // MARK: - Lyrics

    /// The sidecar wins over the tag.
    ///
    /// Both usually exist and hold the same text — SpotiFLAC's `--save-lrc`
    /// writes the file out of the tag it just embedded — but the file is the
    /// one a person can fix by hand, so it takes precedence.
    static func loadLyrics(
        for url: URL,
        embedded: String?
    ) -> (TimedLyrics?, String?) {
        let sidecar = url.deletingPathExtension().appendingPathExtension("lrc")
        if let text = try? String(contentsOf: sidecar, encoding: .utf8) {
            let parsed = EnhancedLRC.parse(text)
            if !parsed.isEmpty { return (parsed, sidecar.lastPathComponent) }
        }
        if let embedded {
            let parsed = EnhancedLRC.parse(embedded)
            if !parsed.isEmpty { return (parsed, "embedded tag") }
        }
        return (nil, nil)
    }
}
