import Foundation
import Observation

/// Every song listened to, kept on this Mac, for the Recap.
///
/// A play counts the way Last.fm counts a scrobble — at least half the song,
/// or four minutes of a long one, and never a track under thirty seconds —
/// so skipping through a queue does not make a favourite. Time is what was
/// actually heard: paused, buffering or scrubbed-over seconds are not added.
///
/// One JSON object per line in Application Support, appended as plays end:
/// nothing is rewritten, and a crash loses at most the song that was on.
@MainActor
@Observable
final class ListeningHistory {
    struct Play: Codable, Hashable, Sendable {
        /// When the song started.
        var date: Date
        /// Seconds actually heard.
        var seconds: Double
        var title: String
        var artist: String
        var albumArtist: String
        var album: String
        var duration: Double?
        /// The file or stream, to play it again from the Recap.
        var url: String
    }

    /// Everything on disk plus what was added this session, oldest first.
    private(set) var plays: [Play] = []

    @ObservationIgnored private weak var model: PlaybackModel?
    /// Told about every play as it is recorded — the scrobbler listens here,
    /// so a scrobble follows exactly the same rule as the Recap.
    @ObservationIgnored var onPlay: [(Play) -> Void] = []
    @ObservationIgnored private var clock: Task<Void, Never>?
    @ObservationIgnored private var loaded = false

    // The listen in progress.
    @ObservationIgnored private var currentURL: URL?
    @ObservationIgnored private var started = Date()
    @ObservationIgnored private var heard: Double = 0
    @ObservationIgnored private var lastSample: Date?
    @ObservationIgnored private var lastPosition: Double = 0
    @ObservationIgnored private var snapshot: (title: String, artist: String, albumArtist: String, album: String, duration: Double?)?

    static var fileURL: URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let folder = support.appendingPathComponent("FLACintosh", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("listening-history.jsonl")
    }

    func attach(to model: PlaybackModel) {
        guard self.model == nil else { return }
        self.model = model
        load()
        // Once a second is plenty to measure listening, and costs nothing:
        // it reads the player, it does not publish anything.
        clock = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.sample()
            }
        }
        NotificationCenter.default.addObserver(forName: .appWillTerminate, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish() }
        }
    }

    func load() {
        guard !loaded, let url = Self.fileURL else { return }
        loaded = true
        guard let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        plays = data.split(separator: UInt8(ascii: "\n")).compactMap { try? decoder.decode(Play.self, from: Data($0)) }
    }

    /// Forgets everything, file included.
    func clear() {
        plays = []
        if let url = Self.fileURL { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: - Measuring

    private func sample() {
        guard let model else { return }
        let now = Date()
        let url = model.currentURL

        if url != currentURL {
            finish()
            begin(url)
        }
        guard url != nil else { return }

        let position = model.currentTime
        // The same song from the top again — repeat one, or previous at the
        // very start — is a new play.
        if lastPosition > 20, position < 3, heard > 0 {
            finish()
            begin(url)
        }

        if model.isPlaying, !model.isBuffering, let last = lastSample {
            // Capped: a sleeping Mac or a stalled main thread is not listening.
            heard += min(now.timeIntervalSince(last), 2)
        }
        if let track = model.track, !track.title.isEmpty {
            let listed = model.currentTrack
            snapshot = (
                title: listed?.title ?? track.title,
                artist: listed?.artist ?? track.artist,
                albumArtist: listed?.albumArtist ?? track.artist,
                album: listed?.album ?? track.album,
                duration: track.duration ?? listed?.duration
            )
        }
        lastSample = now
        lastPosition = position
    }

    private func begin(_ url: URL?) {
        currentURL = url
        started = Date()
        heard = 0
        lastSample = nil
        lastPosition = 0
        snapshot = nil
    }

    private func finish() {
        defer { heard = 0 }
        guard let url = currentURL, let snapshot else { return }
        let duration = snapshot.duration ?? 0
        if duration > 0, duration < 30 { return }
        let needed = duration > 0 ? min(duration / 2, 240) : 30
        guard heard >= needed else { return }

        let play = Play(
            date: started,
            seconds: heard.rounded(),
            title: snapshot.title,
            artist: snapshot.artist,
            albumArtist: snapshot.albumArtist,
            album: snapshot.album,
            duration: snapshot.duration,
            url: LibraryTrack.storable(url)
        )
        plays.append(play)
        append(play)
        onPlay.forEach { $0(play) }
    }

    private func append(_ play: Play) {
        guard let url = Self.fileURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard var line = try? encoder.encode(play) else { return }
        line.append(UInt8(ascii: "\n"))
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: url, options: .atomic)
        }
    }
}

// MARK: - The numbers

/// What the Recap shows, worked out once for a period.
struct ListeningRecap {
    enum Period: String, CaseIterable, Identifiable {
        case month, year, all

        var id: String { rawValue }

        var title: String {
            switch self {
            case .month: "Last 30 Days"
            case .year: "This Year"
            case .all: "All Time"
            }
        }

        func contains(_ date: Date, now: Date = .now) -> Bool {
            switch self {
            case .month: date > now.addingTimeInterval(-30 * 86400)
            case .year: Calendar.current.isDate(date, equalTo: now, toGranularity: .year)
            case .all: true
            }
        }
    }

    struct Ranked: Identifiable, Hashable {
        var id: String { key }
        var key: String
        var title: String
        var subtitle: String
        var plays: Int
        var seconds: Double
        /// A play of it, for its URL and names.
        var sample: ListeningHistory.Play
    }

    var plays: [ListeningHistory.Play]
    var minutes: Int
    var topSongs: [Ranked]
    var topArtists: [Ranked]
    var topAlbums: [Ranked]
    var artistCount: Int
    var songCount: Int
    /// Plays in each hour of the day, 0…23.
    var hours: [Int]
    var busiestDay: (date: Date, minutes: Int)?
    var longestStreak: Int

    init(plays all: [ListeningHistory.Play], period: Period, now: Date = .now) {
        let plays = all.filter { period.contains($0.date, now: now) }
        self.plays = plays
        minutes = Int((plays.reduce(0) { $0 + $1.seconds } / 60).rounded())

        func rank(_ key: (ListeningHistory.Play) -> String, title: (ListeningHistory.Play) -> String, subtitle: (ListeningHistory.Play) -> String) -> [Ranked] {
            var table: [String: Ranked] = [:]
            for play in plays {
                let id = key(play)
                guard !id.isEmpty else { continue }
                table[id, default: Ranked(key: id, title: title(play), subtitle: subtitle(play), plays: 0, seconds: 0, sample: play)].plays += 1
                table[id]?.seconds += play.seconds
            }
            return table.values.sorted { ($0.plays, $0.seconds) > ($1.plays, $1.seconds) }
        }

        let normal = { (text: String) in text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
        let songs = rank({ normal("\($0.title)|\($0.artist)") }, title: \.title, subtitle: \.artist)
        let artists = rank({ normal($0.albumArtist.isEmpty ? $0.artist : $0.albumArtist) },
                           title: { $0.albumArtist.isEmpty ? $0.artist : $0.albumArtist }, subtitle: { _ in "" })
        let albums = rank({ $0.album.isEmpty ? "" : normal("\($0.album)|\($0.albumArtist)") }, title: \.album, subtitle: \.albumArtist)
        topSongs = Array(songs.prefix(5))
        topArtists = Array(artists.prefix(5))
        topAlbums = Array(albums.prefix(5))
        songCount = songs.count
        artistCount = artists.count

        let calendar = Calendar.current
        var hours = Array(repeating: 0, count: 24)
        var days: [Date: Double] = [:]
        for play in plays {
            hours[calendar.component(.hour, from: play.date)] += 1
            days[calendar.startOfDay(for: play.date), default: 0] += play.seconds
        }
        self.hours = hours
        busiestDay = days.max { $0.value < $1.value }.map { ($0.key, Int(($0.value / 60).rounded())) }

        var longest = 0
        var run = 0
        var previous: Date?
        for day in days.keys.sorted() {
            if let previous, calendar.dateComponents([.day], from: previous, to: day).day == 1 {
                run += 1
            } else {
                run = 1
            }
            longest = max(longest, run)
            previous = day
        }
        longestStreak = longest
    }

    /// "Night owl" and friends, from when most of the listening happens.
    var listenerKind: (title: String, detail: String, symbol: String)? {
        guard let peak = hours.indices.max(by: { hours[$0] < hours[$1] }), hours[peak] > 0 else { return nil }
        let range = "\(peak):00–\((peak + 1) % 24):00"
        switch peak {
        case 5 ..< 11: return ("Early Riser", "Most of your listening starts around \(range).", "sunrise.fill")
        case 11 ..< 17: return ("Daytime Listener", "Your music peaks around \(range).", "sun.max.fill")
        case 17 ..< 22: return ("Evening Listener", "Your music peaks around \(range).", "sunset.fill")
        default: return ("Night Owl", "Your music peaks around \(range).", "moon.stars.fill")
        }
    }
}
