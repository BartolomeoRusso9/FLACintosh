# macos-music-player

> **The name is a placeholder.** Working title until we pick a real one.

A macOS music player for local files, built around the one thing no other
player on the platform does: **word-by-word synchronised lyrics.**

## Why

Apple Music will not render timed lyrics for a local file. It strips the
timing out of the tag and shows flat text — so a file carrying this:

```
[00:08.75]<00:08.75>Sento <00:09.05>un<00:09.22>ra-<00:09.41>ta- <00:09.90>ta
```

displays as `[00:08.75]Sento unra-ta- ta`, brackets and all. The scrolling
lyrics Apple Music shows for streamed tracks come from Apple's servers,
matched by catalogue ID; a local file has no ID and never gets them.

Spotify is worse: its lyrics come from Musixmatch keyed on a Spotify track
ID, so local files get nothing at all, not even line-level.

The data exists — [SpotiFLAC](https://github.com/BartolomeoRusso9/SpotiFLAC-Module-Version)
writes it with `--save-lrc`. What is missing is something to draw it.

## Status

**Step 1 of 5.** Plays a file, reads its metadata and true format, and
renders its lyrics one syllable at a time. That is the risky part and it
works; the rest is ordinary app-building.

- [x] Playback, metadata, real sample rate / bit depth
- [x] Enhanced-LRC parser with per-syllable timing
- [x] Word-by-word lyrics view
- [ ] Library: folder scan, sidebar, album grid
- [ ] Discord Rich Presence
- [ ] `MPNowPlayingInfoCenter` + media keys
- [ ] Animation polish

## Running it

**Xcode is not required** — the Command Line Tools are enough.

```bash
swift run Player                                  # then ⌘O, or drop a file in
swift run Player "/path/to/track.flac"            # or open one straight away
```

The first build takes several minutes: SFBAudioEngine compiles a pile of C++
decoders. After that it is seconds.

Lyrics are looked for in two places, in order:

1. a `.lrc` sidecar next to the audio file, same name
2. the file's own embedded lyrics tag

Both are what SpotiFLAC writes, so a track downloaded with `--save-lrc` works
with no further setup. The sidecar wins because it is the one a person can
fix by hand.

## Checking the parser

```bash
swift run LyricsCheck                    # the built-in fixtures
swift run LyricsCheck path/to/file.lrc   # dump a real file, syllable by syllable
```

Not a `swift test` target, and deliberately so: both XCTest and
swift-testing ship inside `Xcode.app`, so a test target cannot build with
only the Command Line Tools installed. The checks are an executable instead,
which runs anywhere the toolchain does. Once Xcode is present this converts
to a test target almost mechanically — the assertions are already
one-per-behaviour.

## How it is put together

| Target | What it is |
| --- | --- |
| `SyncedLyrics` | The parser and its model. No UI, no dependencies — the part worth testing. |
| `Player` | The SwiftUI app. |
| `LyricsCheck` | The parser's checks, and a dump mode for real files. |

Audio comes from [SFBAudioEngine](https://github.com/sbooth/SFBAudioEngine):
FLAC, ALAC, everything else, plus the metadata and the decoder's own view of
sample rate and bit depth. That last point matters — a `.m4a` is ALAC or AAC
depending on what is inside it, and a player like this should say which
rather than guess from the extension.

### The lyric model

`Syllable.text` keeps its own trailing space, so concatenating a line's
syllables reproduces the line exactly. The alternative — a
`isWordContinuation` flag — is a rule every renderer has to remember, and
forgetting it is how "make expressions" comes out as "makeexpressions".

Plain LRC parses too, as a line holding a single syllable, so nothing
downstream has to ask which dialect a file is in.

### The look

The palette is not copied. It is the system's: `NSVisualEffectView`
materials and semantic colours (`.primary`, `.secondary`, `.tertiary`,
`.background`, `.quaternary`), which follow light and dark, the user's accent
colour, reduced transparency and increased contrast on their own. Hard-coded
greys are what make a clone look like a clone in one mode and wrong in the
other.

### The effect

Not "colour the current word". Each syllable fills across its own duration
behind a soft gradient edge, so the light travels *through* a long word; the
lines around the current one dim, blur and shrink slightly rather than
vanishing. That continuous motion is what the eye reads as following a voice.

`SyllableFlow` exists because an `HStack` never wraps and a single `Text`
cannot animate its pieces independently — a line of lyrics needs both.

## Licence

Not chosen yet.
