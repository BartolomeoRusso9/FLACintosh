import Foundation
import SyncedLyrics

/// Run the parser over a real file instead of the built-in fixtures:
///
///     swift run LyricsCheck "/path/to/track.lrc"
///
/// Prints what the renderer would see, second by second, which is the
/// quickest way to tell a parsing problem from a rendering one.
enum RealFile {
    static func dump(_ path: String) -> Int32 {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            print("could not read \(path)")
            return 1
        }

        let lyrics = EnhancedLRC.parse(text)
        print("title:  \(lyrics.title ?? "—")")
        print("artist: \(lyrics.artist ?? "—")")
        print("lines:  \(lyrics.lines.count)")
        print("word-by-word: \(lyrics.hasWordTiming)")
        print("")

        for line in lyrics.lines.prefix(4) {
            let stamp = String(format: "%6.2f→%6.2f", line.start, line.end)
            print("[\(stamp)] \(line.text)")
            for syllable in line.syllables.prefix(8) {
                print(String(format: "            %6.2f  %@", syllable.start, syllable.text))
            }
            if line.syllables.count > 8 {
                print("            … \(line.syllables.count - 8) more")
            }
        }
        return lyrics.isEmpty ? 1 : 0
    }
}
