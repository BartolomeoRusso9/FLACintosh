import Foundation
import SyncedLyrics

/// Ask the providers for a track's lyrics, from the command line:
///
///     swift run LyricsCheck --fetch "Title" "Artist" [album] [duration]
///
/// The same code path the app uses, minus the app — which is the quickest
/// way to tell "the providers have nothing" from "the app is not showing
/// what they gave it".
enum Fetch {
    static func run(_ arguments: [String]) async -> Int32 {
        guard arguments.count >= 2 else {
            print("usage: LyricsCheck --fetch \"Title\" \"Artist\" [album] [duration seconds]")
            return 2
        }

        let query = LyricsQuery(
            title: arguments[0],
            artist: arguments[1],
            album: arguments.count > 2 ? arguments[2] : "",
            duration: arguments.count > 3 ? Double(arguments[3]) ?? 0 : 0
        )

        print("looking for: \(query.cleanTitle) — \(query.cleanArtist)")
        if !query.album.isEmpty { print("album:       \(query.album)") }
        if query.duration > 0 { print("duration:    \(Int(query.duration))s") }
        print("")

        guard let found = await LyricsFetcher.fetch(query) else {
            print("no provider had it")
            return 1
        }

        let parsed = EnhancedLRC.parse(found.lrc)
        print("provider:    \(found.provider)")
        print("word-by-word:\(found.isWordByWord ? " yes" : " no")")
        print("lines:       \(parsed.lines.count)")
        print("syllables:   \(parsed.lines.reduce(0) { $0 + $1.syllables.count })")
        print("")

        for line in parsed.lines.prefix(4) {
            let stamp = LyricsText.timestamp(Int(line.start * 1000))
            print("\(stamp) \(line.text)")
            if line.hasWordTiming {
                let sample = line.syllables.prefix(6).map {
                    "\(LyricsText.timestamp(Int($0.start * 1000), opening: "<"))\($0.text)"
                }
                print("        \(sample.joined())…")
            }
        }
        return parsed.isEmpty ? 1 : 0
    }
}
