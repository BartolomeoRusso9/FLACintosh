import Foundation

/// One timed fragment of a line.
///
/// A syllable, not a word: Apple times "expressions" as `ex|pres|sions`, and
/// that is what makes the highlight travel *through* a long word instead of
/// jumping over it.
///
/// `text` keeps whatever trailing space it had, so concatenating every
/// syllable of a line reproduces the line exactly. That is deliberate — the
/// alternative is a `isWordContinuation` flag that every renderer then has to
/// remember to honour, and forgetting it is how "make expressions" comes out
/// as "makeexpressions".
public struct Syllable: Equatable, Sendable {
    public let start: TimeInterval
    /// Exclusive end: the next syllable's start, or the line's end.
    public let end: TimeInterval
    public let text: String

    public init(start: TimeInterval, end: TimeInterval, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }

    /// How far through this syllable `time` is, clamped to 0...1.
    public func progress(at time: TimeInterval) -> Double {
        guard end > start else { return time >= start ? 1 : 0 }
        return min(max((time - start) / (end - start), 0), 1)
    }
}

/// One line of lyrics, with per-syllable timing where the source had it.
public struct LyricLine: Equatable, Sendable, Identifiable {
    public let id: Int
    public let start: TimeInterval
    public let end: TimeInterval
    public let syllables: [Syllable]

    public init(id: Int, start: TimeInterval, end: TimeInterval, syllables: [Syllable]) {
        self.id = id
        self.start = start
        self.end = end
        self.syllables = syllables
    }

    /// The whole line as plain text.
    public var text: String {
        syllables.map(\.text).joined()
    }

    /// Whether this line carries real per-syllable timing.
    ///
    /// A line parsed from plain LRC becomes a single syllable spanning the
    /// whole line, so a renderer can treat both kinds the same way and only
    /// consult this to decide whether a word-by-word sweep means anything.
    public var hasWordTiming: Bool {
        syllables.count > 1
    }

    public func contains(_ time: TimeInterval) -> Bool {
        time >= start && time < end
    }
}

/// A parsed lyrics file: the id tags, and the lines in time order.
public struct TimedLyrics: Equatable, Sendable {
    public let title: String?
    public let artist: String?
    public let album: String?
    public let lines: [LyricLine]

    public init(
        title: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        lines: [LyricLine] = []
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.lines = lines
    }

    public var isEmpty: Bool { lines.isEmpty }

    /// True when at least one line has syllable timing — i.e. when a
    /// word-by-word display is worth showing at all.
    public var hasWordTiming: Bool {
        lines.contains(where: \.hasWordTiming)
    }

    /// The index of the line playing at `time`, or the last one before it.
    ///
    /// Binary search rather than a scan: this is called on every frame.
    /// Returns nil before the first line starts.
    public func lineIndex(at time: TimeInterval) -> Int? {
        guard let first = lines.first, time >= first.start else { return nil }
        var low = 0
        var high = lines.count - 1
        var found = 0
        while low <= high {
            let mid = (low + high) / 2
            if lines[mid].start <= time {
                found = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return found
    }
}
