import Foundation
import SyncedLyrics

// A test target would be the idiomatic home for this, but both XCTest and
// swift-testing ship inside Xcode.app: with only the Command Line Tools
// installed, `swift test` cannot build at all. So the checks live in an
// executable instead — `swift run LyricsCheck` — which needs nothing beyond
// the toolchain and works the same in CI.
//
// Once Xcode is installed this converts to a real test target almost
// mechanically: the assertions below are already one-per-behaviour.

private var failures = 0
private var checks = 0

private func expect(
    _ condition: Bool,
    _ what: String,
    file: StaticString = #file,
    line: UInt = #line
) {
    checks += 1
    if !condition {
        failures += 1
        print("  ✗ \(what)   (\(URL(fileURLWithPath: "\(file)").lastPathComponent):\(line))")
    }
}

private func expectEqual<T: Equatable>(
    _ actual: T,
    _ expected: T,
    _ what: String,
    file: StaticString = #file,
    line: UInt = #line
) {
    checks += 1
    if actual != expected {
        failures += 1
        print("  ✗ \(what)")
        print("      expected: \(expected)")
        print("      actual:   \(actual)")
        print("      (\(URL(fileURLWithPath: "\(file)").lastPathComponent):\(line))")
    }
}

private func suite(_ name: String, _ body: () -> Void) {
    print("\(name)")
    body()
}

// Given a path, dump that file instead of running the fixtures — the quickest
// way to tell a parsing problem from a rendering one.
if CommandLine.arguments.count > 1 {
    exit(RealFile.dump(CommandLine.arguments[1]))
}

// The fixture is real output: what SpotiFLAC's `--save-lrc` wrote for Capo
// Plaza's "RATATA", straight from Apple's timed lyrics. It is the file this
// whole project exists to render, because Apple Music will not.
let ratata = """
[ti:RATATA]
[ar:Capo Plaza]
[by:SpotiFLAC]

[00:08.75]<00:08.75>Sento <00:09.05>un<00:09.22>ra-<00:09.41>ta- <00:09.90>ta
[00:10.94]<00:10.94>Sento <00:11.39>un<00:11.56>ra-<00:11.77>ta-<00:12.00>ta- <00:12.91>ta
"""

suite("enhanced LRC — the format SpotiFLAC writes") {
    let lyrics = EnhancedLRC.parse(ratata)

    expectEqual(lyrics.title, "RATATA", "id tags become metadata")
    expectEqual(lyrics.artist, "Capo Plaza", "artist id tag")
    expectEqual(lyrics.lines.count, 2, "id tags are not lines")

    let line = lyrics.lines[0]
    expectEqual(line.start, 8.75, "line start")
    expectEqual(line.syllables.count, 5, "one entry per syllable")
    // The spaces live inside the syllables, so joining them is lossless —
    // "un" and "ra-" belong to one word and must not gain a space.
    expectEqual(line.text, "Sento unra-ta- ta", "the line reads back whole")
    expect(line.hasWordTiming, "a syllable-timed line says so")

    expectEqual(line.syllables[0].end, 9.05, "a syllable ends where the next starts")
    expectEqual(line.syllables.last?.end, 10.94, "the last syllable runs to the line's end")
    expectEqual(
        lyrics.lines[1].end,
        lyrics.lines[1].start + EnhancedLRC.trailingLineDuration,
        "the last line gets an end with nothing after it"
    )
}

suite("plain LRC — the other dialect") {
    let lyrics = EnhancedLRC.parse("[00:12.00]Just a line\n[00:15.00]And another")
    expectEqual(lyrics.lines.count, 2, "two lines")
    expectEqual(lyrics.lines[0].text, "Just a line", "text survives")
    expect(!lyrics.lines[0].hasWordTiming, "no syllable timing is reported as such")
    expect(!lyrics.hasWordTiming, "and the file agrees")

    let chorus = EnhancedLRC.parse("[00:10.00][01:20.00]Chorus")
    expectEqual(chorus.lines.count, 2, "one body under two timestamps becomes two lines")
    expectEqual(chorus.lines.map(\.start), [10, 80], "both timestamps kept")

    let shifted = EnhancedLRC.parse("[offset:+500]\n[00:10.00]Late")
    expectEqual(shifted.lines[0].start, 10.5, "offset shifts every timestamp")
}

suite("lookup") {
    let lyrics = EnhancedLRC.parse(ratata)
    expect(lyrics.lineIndex(at: 0) == nil, "nothing is playing before the first line")
    expectEqual(lyrics.lineIndex(at: 9.0), 0, "inside the first line")
    expectEqual(lyrics.lineIndex(at: 10.94), 1, "exactly on a line's start")
    expectEqual(lyrics.lineIndex(at: 600), 1, "past the end, the last line stays")

    let syllable = Syllable(start: 10, end: 12, text: "ta")
    expectEqual(syllable.progress(at: 9), 0, "before")
    expectEqual(syllable.progress(at: 11), 0.5, "halfway")
    expectEqual(syllable.progress(at: 99), 1, "after")

    // A zero-length syllable is on or off, never a division by zero.
    let instant = Syllable(start: 10, end: 10, text: "ta")
    expectEqual(instant.progress(at: 9.9), 0, "zero-length syllable, before")
    expectEqual(instant.progress(at: 10), 1, "zero-length syllable, on")
}

suite("what real files do wrong") {
    expectEqual(EnhancedLRC.timestamp("01:23.45"), 83.45, "mm:ss.xx")
    expectEqual(EnhancedLRC.timestamp("01:23"), 83, "mm:ss")
    expectEqual(EnhancedLRC.timestamp("01:23.456"), 83.456, "mm:ss.xxx")
    expectEqual(EnhancedLRC.timestamp("01:23:45"), 83.45, "colon for the fraction")
    expect(EnhancedLRC.timestamp("nonsense") == nil, "not a timestamp")
    expect(EnhancedLRC.timestamp("[00:01.00]") == nil, "brackets are not part of it")

    expectEqual(EnhancedLRC.idTag(in: "[ti:RATATA]")?.0, "ti", "an id tag")
    expect(EnhancedLRC.idTag(in: "[00:08.75]Sento") == nil, "a timestamp is not an id tag")
    // The one id tag with a numeric value — the key has to decide.
    expectEqual(EnhancedLRC.idTag(in: "[offset:+500]")?.1, "+500", "offset is an id tag")

    let messy = EnhancedLRC.parse("\n\nnot a lyric line\n[00:01.00]Real\n   \n")
    expectEqual(messy.lines.count, 1, "junk between lines is skipped")

    expect(EnhancedLRC.parse("").isEmpty, "an empty file is empty, not a crash")
    expect(EnhancedLRC.parse("[ti:Only metadata]").isEmpty, "metadata alone is no lyrics")

    let unordered = EnhancedLRC.parse("[00:30.00]Third\n[00:10.00]First\n[00:20.00]Second")
    expectEqual(unordered.lines.map(\.text), ["First", "Second", "Third"], "lines are sorted")

    let stray = EnhancedLRC.parse("[00:01.00]<00:01.00>2 < 3 <00:02.00>always")
    expectEqual(stray.lines[0].text, "2 < 3 always", "a stray angle bracket stays text")
}

print("")
if failures == 0 {
    print("\(checks) checks passed")
    exit(0)
} else {
    print("\(failures) of \(checks) checks FAILED")
    exit(1)
}
