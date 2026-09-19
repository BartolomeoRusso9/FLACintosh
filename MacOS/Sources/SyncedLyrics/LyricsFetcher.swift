import Foundation

/// What is known about a track when going looking for its words.
public struct LyricsQuery: Sendable, Equatable {
    public var title: String
    public var artist: String
    public var album: String
    public var duration: TimeInterval

    public init(title: String, artist: String, album: String = "", duration: TimeInterval = 0) {
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
    }

    /// "Song (feat. Someone) - 2011 Remaster" is not what a lyrics catalogue
    /// filed the song under.
    public var cleanTitle: String { LyricsText.simplifyTrackName(title) }
    /// Catalogues index the lead artist; "A, B & C" matches nothing.
    public var cleanArtist: String { LyricsText.primaryArtist(artist) }
}

public struct FetchedLyrics: Sendable, Equatable {
    /// LRC text, ready to be written next to the file or parsed.
    public var lrc: String
    /// Which provider answered.
    public var provider: String
    /// Whether the timings go down to the syllable — the difference between
    /// this app and every other player, so it is worth saying out loud.
    public var isWordByWord: Bool

    public init(lrc: String, provider: String, isWordByWord: Bool) {
        self.lrc = lrc
        self.provider = provider
        self.isWordByWord = isWordByWord
    }
}

/// Finds lyrics for a track that has none.
///
/// A Swift port of SpotiFLAC's `core/lyrics.py`, kept to the two providers
/// that need no account: Apple's catalogue through a public relay, which is
/// the only source that times *syllables*, and LRCLIB, which is fast, free
/// and line-level. Ported rather than shelled out to because this is the
/// feature the app exists for — it cannot depend on a `pip install`.
public enum LyricsFetcher {
    public enum Provider: String, Sendable, CaseIterable {
        case apple, lrclib
    }

    /// Every provider is asked at once, but they are *read* in the order
    /// given.
    ///
    /// This is the one subtlety worth keeping from the original: LRCLIB
    /// answers in about a tenth of a second and Apple takes a second (a
    /// search, then a fetch), so taking whoever finishes first turns the
    /// provider list into a set and reliably yields plain line-level lyrics
    /// — the word-by-word ones the order asked for never get used. Reading
    /// in order costs nothing: by the time the first choice fails, the
    /// others have long since finished.
    public static func fetch(
        _ query: LyricsQuery,
        providers: [Provider] = [.apple, .lrclib],
        session: URLSession = .shared
    ) async -> FetchedLyrics? {
        await withTaskGroup(of: (Provider, FetchedLyrics?).self) { group in
            for provider in providers {
                group.addTask { (provider, await run(provider, query, session)) }
            }

            var answers: [Provider: FetchedLyrics] = [:]
            for await (provider, result) in group {
                if let result { answers[provider] = result }
            }
            for provider in providers {
                if let answer = answers[provider] { return answer }
            }
            return nil
        }
    }

    private static func run(
        _ provider: Provider,
        _ query: LyricsQuery,
        _ session: URLSession
    ) async -> FetchedLyrics? {
        let found: FetchedLyrics?
        switch provider {
        case .apple: found = await AppleLyrics.fetch(query, session: session)
        case .lrclib: found = await LRCLib.fetch(query, session: session)
        }
        guard var found, !found.lrc.isEmpty else { return nil }
        found.lrc = LyricsText.addMetadata(found.lrc, title: query.title, artist: query.artist)
        return found
    }
}

// MARK: - Apple

/// Apple's catalogue: an iTunes search for the track id, then the lyrics.
///
/// Apple times every syllable rather than every word, which is what makes a
/// word-by-word display possible at all. The direct path needs a
/// subscriber's Media-User-Token; this takes the public relay, which carries
/// the same per-syllable timings.
enum AppleLyrics {
    private static let search = "https://itunes.apple.com/search"
    private static let relay = "https://lyrics.paxsenix.org/apple-music/lyrics"

    static func fetch(_ query: LyricsQuery, session: URLSession) async -> FetchedLyrics? {
        guard let id = await songID(for: query, session: session) else { return nil }
        guard
            var components = URLComponents(string: relay)
        else { return nil }
        components.queryItems = [URLQueryItem(name: "id", value: String(id))]
        guard
            let url = components.url,
            let (data, response) = try? await session.data(for: request(url)),
            (response as? HTTPURLResponse)?.statusCode == 200,
            let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else { return nil }

        let lrc = payload.asLRC()
        guard !lrc.isEmpty else { return nil }
        return FetchedLyrics(lrc: lrc, provider: "apple", isWordByWord: payload.hasSyllables)
    }

    private static func songID(for query: LyricsQuery, session: URLSession) async -> Int? {
        guard var components = URLComponents(string: search) else { return nil }
        components.queryItems = [
            URLQueryItem(name: "term", value: "\(query.cleanTitle) \(query.cleanArtist)"),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "5"),
            URLQueryItem(name: "country", value: "US"),
        ]
        guard
            let url = components.url,
            let (data, _) = try? await session.data(for: request(url)),
            let results = try? JSONDecoder().decode(SearchResults.self, from: data)
        else { return nil }

        let scored = results.results.map { ($0, score($0, query)) }
        guard let best = scored.max(by: { $0.1 < $1.1 }), best.1 >= 50 else { return nil }
        return best.0.trackId
    }

    /// Title and artist carry the match; the duration only confirms it.
    /// Below 50 nothing matched but a word, and the wrong song's lyrics are
    /// worse than none.
    private static func score(_ result: SearchResult, _ query: LyricsQuery) -> Int {
        var score = 0
        let track = LyricsText.normalizeLoose(result.trackName ?? "")
        let artist = LyricsText.normalizeLoose(result.artistName ?? "")
        let wantedTrack = LyricsText.normalizeLoose(query.title)
        let wantedArtist = LyricsText.normalizeLoose(query.artist)

        if track == wantedTrack {
            score += 50
        } else if track.contains(wantedTrack) || wantedTrack.contains(track) {
            score += 25
        }
        if artist == wantedArtist {
            score += 60
        } else if artist.contains(wantedArtist) || wantedArtist.contains(artist) {
            score += 30
        }
        if query.duration > 0, let millis = result.trackTimeMillis, millis > 0,
           abs(Double(millis) / 1000 - query.duration) <= 5 {
            score += 20
        }
        return score
    }

    private static func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private struct SearchResults: Decodable {
        var results: [SearchResult]
    }

    private struct SearchResult: Decodable {
        var trackId: Int?
        var trackName: String?
        var artistName: String?
        var trackTimeMillis: Int?
    }

    /// The relay's shape: lines with a timestamp, each holding timed parts.
    struct Payload: Decodable {
        var content: [Line]

        struct Line: Decodable {
            var timestamp: Int?
            var text: [Part]?
        }

        struct Part: Decodable {
            var timestamp: Int?
            var text: String?
            /// True when this part continues the syllable before it —
            /// "ex|pres|sions" — and so must not be preceded by a space.
            var part: Bool?
        }

        var hasSyllables: Bool {
            content.contains { ($0.text?.count ?? 0) > 1 }
        }

        func asLRC() -> String {
            var lines: [String] = []
            for line in content {
                let start = line.timestamp ?? 0
                var pieces: [String] = []
                for part in line.text ?? [] {
                    guard let text = part.text, !text.isEmpty else { continue }
                    let separator = (part.part ?? false) ? "" : " "
                    let stamp = LyricsText.timestamp(part.timestamp ?? start, opening: "<")
                    pieces.append("\(separator)\(stamp)\(text)")
                }
                let text = pieces.joined().trimmingCharacters(in: .whitespaces)
                if !text.isEmpty {
                    lines.append("\(LyricsText.timestamp(start))\(text)")
                }
            }
            return lines.joined(separator: "\n")
        }
    }
}

// MARK: - LRCLIB

/// Free, no account, and usually right — but line-level. The fallback when
/// Apple has never heard of the track.
enum LRCLib {
    private static let base = "https://lrclib.net/api"

    static func fetch(_ query: LyricsQuery, session: URLSession) async -> FetchedLyrics? {
        // With the album first, then without: an album tag that disagrees
        // with the catalogue's own spelling turns an exact hit into a miss.
        for withAlbum in [true, false] where withAlbum || !query.album.isEmpty {
            if let found = await exact(query, withAlbum: withAlbum, session: session) {
                return found
            }
        }
        return await search(query, session: session)
    }

    private static func exact(
        _ query: LyricsQuery,
        withAlbum: Bool,
        session: URLSession
    ) async -> FetchedLyrics? {
        guard var components = URLComponents(string: "\(base)/get") else { return nil }
        var items = [
            URLQueryItem(name: "artist_name", value: query.cleanArtist),
            URLQueryItem(name: "track_name", value: query.cleanTitle),
        ]
        if withAlbum, !query.album.isEmpty {
            items.append(URLQueryItem(name: "album_name", value: query.album))
        }
        if query.duration > 0 {
            items.append(URLQueryItem(name: "duration", value: String(Int(query.duration))))
        }
        components.queryItems = items

        guard
            let url = components.url,
            let (data, response) = try? await session.data(for: request(url)),
            (response as? HTTPURLResponse)?.statusCode == 200,
            let record = try? JSONDecoder().decode(Record.self, from: data)
        else { return nil }
        return record.asLyrics()
    }

    private static func search(_ query: LyricsQuery, session: URLSession) async -> FetchedLyrics? {
        guard var components = URLComponents(string: "\(base)/search") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "artist_name", value: query.cleanArtist),
            URLQueryItem(name: "track_name", value: query.cleanTitle),
        ]
        guard
            let url = components.url,
            let (data, response) = try? await session.data(for: request(url)),
            (response as? HTTPURLResponse)?.statusCode == 200,
            let records = try? JSONDecoder().decode([Record].self, from: data)
        else { return nil }

        // Ten seconds of slack: a search result that is a minute out is a
        // different edit of the song, and its timings would drift apart.
        let plausible = records.filter {
            query.duration == 0 || abs(($0.duration ?? 0) - query.duration) <= 10
        }
        if let synced = plausible.first(where: { !($0.syncedLyrics ?? "").isEmpty }) {
            return synced.asLyrics()
        }
        return plausible.first { !($0.plainLyrics ?? "").isEmpty }?.asLyrics()
    }

    private static func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        // LRCLIB asks clients to identify themselves.
        request.setValue(
            "macos-music-player (https://github.com/BartolomeoRusso9/macos-music-player)",
            forHTTPHeaderField: "User-Agent"
        )
        return request
    }

    private struct Record: Decodable {
        var syncedLyrics: String?
        var plainLyrics: String?
        var duration: Double?

        func asLyrics() -> FetchedLyrics? {
            if let synced = syncedLyrics, !synced.isEmpty {
                return FetchedLyrics(lrc: synced, provider: "lrclib", isWordByWord: false)
            }
            if let plain = plainLyrics, !plain.isEmpty {
                return FetchedLyrics(lrc: plain, provider: "lrclib (unsynced)", isWordByWord: false)
            }
            return nil
        }
    }
}

// MARK: - Text

/// The string handling the catalogues need, ported from SpotiFLAC.
public enum LyricsText {
    static let noise = [
        #"\s*\(feat\..*?\)"#,
        #"\s*\(ft\..*?\)"#,
        #"\s*\(featuring.*?\)"#,
        #"\s*\(with.*?\)"#,
        #"\s*-\s*Remaster(ed)?.*$"#,
        #"\s*-\s*\d{4}\s*Remaster.*$"#,
        #"\s*\(Remaster(ed)?.*?\)"#,
        #"\s*\(Deluxe.*?\)"#,
        #"\s*\(Bonus.*?\)"#,
        #"\s*\(Live.*?\)"#,
        #"\s*\(Acoustic.*?\)"#,
        #"\s*\(Radio Edit\)"#,
        #"\s*\(Single Version\)"#,
    ]

    public static func simplifyTrackName(_ name: String) -> String {
        var result = name
        for pattern in noise {
            result = result.replacingOccurrences(
                of: pattern,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        let trimmed = result.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? name : trimmed
    }

    public static func primaryArtist(_ name: String) -> String {
        let separators = [", ", "; ", " & ", " feat. ", " ft. ", " featuring ", " with "]
        var result = name
        for separator in separators {
            if let range = result.range(of: separator, options: .caseInsensitive),
               range.lowerBound != result.startIndex {
                result = String(result[result.startIndex ..< range.lowerBound])
                break
            }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// Case, accents and punctuation folded away, so "Beyoncé" and "beyonce"
    /// are the same artist and "R&B/Soul" and "r b soul" are the same word.
    public static func normalizeLoose(_ text: String) -> String {
        var folded = text.lowercased()
            .replacingOccurrences(of: "ß", with: "ss")
            .replacingOccurrences(of: "đ", with: "dj")
            .replacingOccurrences(of: "æ", with: "ae")
            .replacingOccurrences(of: "œ", with: "oe")
        folded = folded.folding(options: [.diacriticInsensitive], locale: nil)
        folded = folded.replacingOccurrences(
            of: #"[/\\_\-|.&+]"#,
            with: " ",
            options: .regularExpression
        )
        return folded.split(separator: " ").joined(separator: " ")
    }

    /// `[mm:ss.cc]` for a line, `<mm:ss.cc>` for a syllable.
    public static func timestamp(_ milliseconds: Int, opening: String = "[") -> String {
        let total = max(0, milliseconds)
        let minutes = total / 60_000
        let seconds = (total % 60_000) / 1000
        let centiseconds = (total % 1000) / 10
        let closing = opening == "<" ? ">" : "]"
        return String(format: "%@%02d:%02d.%02d%@", opening, minutes, seconds, centiseconds, closing)
    }

    public static func addMetadata(_ lrc: String, title: String, artist: String) -> String {
        guard !lrc.isEmpty, !lrc.contains("[ti:") else { return lrc }
        return "[ti:\(title)]\n[ar:\(artist)]\n\n" + lrc
    }
}
