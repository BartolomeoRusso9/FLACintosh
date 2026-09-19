import Foundation

/// Reads enhanced LRC — the format with a timestamp per *syllable*.
///
///     [ti:RATATA]
///     [ar:Capo Plaza]
///
///     [00:08.75]<00:08.75>Sento <00:09.05>un<00:09.22>ra-<00:09.41>ta- <00:09.90>ta
///
/// The `[mm:ss.xx]` opens the line; each `<mm:ss.xx>` opens a syllable. Plain
/// LRC — a line tag and nothing else — parses too, as a line holding one
/// syllable, so a caller never has to ask which dialect a file is in.
///
/// This is the format SpotiFLAC writes with `--save-lrc`, which is in turn
/// what Apple's own timed lyrics look like once flattened; it is also what
/// Apple Music refuses to render for a local file, which is the whole reason
/// this parser exists.
public enum EnhancedLRC {
    /// A line's end when nothing follows it — the last line of a file has no
    /// successor to borrow a start time from.
    public static let trailingLineDuration: TimeInterval = 4

    public static func parse(_ source: String) -> TimedLyrics {
        var idTags: [String: String] = [:]
        var pending: [(start: TimeInterval, syllables: [(TimeInterval, String)])] = []

        for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if let (key, value) = idTag(in: line) {
                idTags[key] = value
                continue
            }

            let (starts, body) = lineTimestamps(in: line)
            guard !starts.isEmpty else { continue }

            // Standard LRC lets one body carry several timestamps, for a
            // chorus repeated verbatim. Each becomes its own line.
            let syllables = self.syllables(in: body)
            for start in starts {
                pending.append((start, syllables.isEmpty ? [(start, body)] : syllables))
            }
        }

        pending.sort { $0.start < $1.start }

        let offset = idTags["offset"].flatMap(Double.init).map { $0 / 1000 } ?? 0
        var lines: [LyricLine] = []
        lines.reserveCapacity(pending.count)

        for (index, entry) in pending.enumerated() {
            let start = entry.start + offset
            let end = index + 1 < pending.count
                ? pending[index + 1].start + offset
                : start + trailingLineDuration

            var syllables: [Syllable] = []
            syllables.reserveCapacity(entry.syllables.count)
            for (position, syllable) in entry.syllables.enumerated() {
                let syllableStart = syllable.0 + offset
                let syllableEnd = position + 1 < entry.syllables.count
                    ? entry.syllables[position + 1].0 + offset
                    : end
                syllables.append(
                    Syllable(
                        start: syllableStart,
                        end: max(syllableEnd, syllableStart),
                        text: syllable.1
                    )
                )
            }

            // A line tag with no text at all marks an instrumental gap. It is
            // kept, not dropped: it is what stops the previous line from
            // staying lit through a thirty-second break.
            lines.append(
                LyricLine(id: lines.count, start: start, end: end, syllables: syllables)
            )
        }

        return TimedLyrics(
            title: idTags["ti"],
            artist: idTags["ar"],
            album: idTags["al"],
            lines: lines
        )
    }

    // MARK: - Pieces

    /// `[ti:RATATA]` → ("ti", "RATATA"). Nil for anything time-shaped.
    ///
    /// Public because telling an id tag from a line tag is the one decision
    /// in this format people get wrong, and it is worth being able to check
    /// it directly.
    public static func idTag(in line: String) -> (String, String)? {
        guard line.hasPrefix("["), line.hasSuffix("]"),
              let colon = line.firstIndex(of: ":")
        else { return nil }

        let key = String(line[line.index(after: line.startIndex)..<colon])
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        // A timestamp's "key" is its minutes. Digits mean this is a line, not
        // an id tag — and "offset" is the one id tag whose value is numeric,
        // which is why the *key* decides and not the value.
        guard !key.isEmpty, key.allSatisfy({ $0.isLetter }) else { return nil }

        let value = String(line[line.index(after: colon)..<line.index(before: line.endIndex)])
        return (key, value.trimmingCharacters(in: .whitespaces))
    }

    /// Peels the leading `[mm:ss.xx]` tags off a line, returning them and the
    /// body that follows.
    static func lineTimestamps(in line: String) -> ([TimeInterval], String) {
        var starts: [TimeInterval] = []
        var rest = Substring(line)

        while rest.hasPrefix("[") {
            guard let close = rest.firstIndex(of: "]") else { break }
            let inside = rest[rest.index(after: rest.startIndex)..<close]
            guard let seconds = timestamp(String(inside)) else { break }
            starts.append(seconds)
            rest = rest[rest.index(after: close)...]
        }

        return (starts, String(rest))
    }

    /// Splits a line body into its `<mm:ss.xx>text` fragments.
    ///
    /// Any text before the first `<` belongs to nothing — a well-formed
    /// enhanced line opens with a tag — so it is attached to the first
    /// syllable rather than silently dropped.
    static func syllables(in body: String) -> [(TimeInterval, String)] {
        guard body.contains("<") else { return [] }

        var result: [(TimeInterval, String)] = []
        var prefix = ""
        var rest = Substring(body)

        while let open = rest.firstIndex(of: "<") {
            let leading = rest[rest.startIndex..<open]
            guard let close = rest[open...].firstIndex(of: ">"),
                  let seconds = timestamp(String(rest[rest.index(after: open)..<close]))
            else {
                // A stray "<" that is not a timestamp: keep it as text.
                prefix += String(rest[rest.startIndex...open])
                rest = rest[rest.index(after: open)...]
                continue
            }

            if result.isEmpty {
                prefix += String(leading)
            } else {
                result[result.count - 1].1 += String(leading)
            }

            result.append((seconds, ""))
            rest = rest[rest.index(after: close)...]
        }

        if !rest.isEmpty {
            if result.isEmpty {
                prefix += String(rest)
            } else {
                result[result.count - 1].1 += String(rest)
            }
        }

        if !prefix.isEmpty, !result.isEmpty {
            result[0].1 = prefix + result[0].1
        }

        return result.filter { !$0.1.isEmpty }
    }

    /// `01:23.45` → 83.45. Accepts `mm:ss`, `mm:ss.xx` and `mm:ss.xxx`, and
    /// the `mm:ss:xx` some writers emit.
    public static func timestamp(_ raw: String) -> TimeInterval? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard let colon = text.firstIndex(of: ":") else { return nil }

        let minutesPart = text[text.startIndex..<colon]
        guard !minutesPart.isEmpty, minutesPart.allSatisfy(\.isNumber),
              let minutes = Double(minutesPart)
        else { return nil }

        var secondsPart = text[text.index(after: colon)...]
        var fraction: Double = 0
        if let separator = secondsPart.firstIndex(where: { $0 == "." || $0 == ":" }) {
            let digits = secondsPart[secondsPart.index(after: separator)...]
            guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
            fraction = (Double(digits) ?? 0) / pow(10, Double(digits.count))
            secondsPart = secondsPart[secondsPart.startIndex..<separator]
        }

        guard !secondsPart.isEmpty, secondsPart.allSatisfy(\.isNumber),
              let seconds = Double(secondsPart)
        else { return nil }

        return minutes * 60 + seconds + fraction
    }
}
