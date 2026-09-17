# FLACintosh

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

**Feature complete.** Reads a folder — or a Navidrome or Jellyfin server —
into a library, shows it the way a music app should, plays it with lyrics one
syllable at a time, goes and finds those lyrics when a file has none, and
plays on Cast devices, shows up on Discord and sums up what you listened to.

- [x] Playback, metadata, real sample rate / bit depth
- [x] Enhanced-LRC parser with per-syllable timing
- [x] Word-by-word lyrics view
- [x] Now Playing look: brand palette, cover art, colours drawn from the sleeve
- [x] Library: folder scan, sidebar, album grid, songs, artists, search
- [x] Queue: shuffle, repeat, next/previous, advance at end of track
- [x] Lyrics from Apple and LRCLIB when a file has none, per track or per album
- [x] Optional SpotiFLAC bridge for downloading
- [x] Search Spotify and download through a SpotiFLAC server
- [x] Navidrome / Subsonic and Jellyfin servers
- [x] Metadata editor
- [x] Discord Rich Presence
- [x] `MPNowPlayingInfoCenter` + media keys: Control Center, menu bar, keyboard
- [x] Google Cast: Chromecast, Google TV, Nest speakers and groups — unsupported formats and hi-res converted on the fly
- [x] Wrapped-style listening summary: the Recap
- [x] Animation polish

## Running it

**Xcode is not required** — the Command Line Tools are enough. macOS 15 or
newer.

```bash
swift run FLACintosh                                  # the library
swift run FLACintosh "/path/to/track.flac"            # play that track straight away
```

The library is a folder — `~/Music` unless you pick another with ⇧⌘O. It is
re-read on launch and with ⌘R; there is no database to go stale.

The first build takes several minutes: SFBAudioEngine compiles a pile of C++
decoders. After that it is seconds.

Lyrics are looked for in two places, in order:

1. a `.lrc` sidecar next to the audio file, same name
2. the file's own embedded lyrics tag

Both are what SpotiFLAC writes, so a track downloaded with `--save-lrc` works
with no further setup. The sidecar wins because it is the one a person can
fix by hand.

## Packaging

```bash
scripts/package.sh                       # dist/FLACintosh.app and dist/FLACintosh-0.1.0.dmg
VERSION=0.2.0 BUILD_NUMBER=2 scripts/package.sh
ARCHS=arm64 scripts/package.sh           # Apple Silicon only, one build instead of two
```

Still no Xcode. The script builds a release for Apple Silicon and Intel,
puts the app bundle together — Info.plist, icon, and the decoder frameworks
SFBAudioEngine links, which must travel inside the app — signs it ad hoc and
wraps it in a disk image.

The icon is `Assets/AppIcon.png`, 1024×1024. If it is missing the script
draws a placeholder with `scripts/make-icon.swift`; replace the file to
change it.

The first launch of the app picks up the servers, folder and view choices
saved by `swift run`, which keeps its settings under a different name.

Ad hoc is not a Developer ID, so on any Mac but this one the first launch is
blocked: **System Settings → Privacy & Security → Open Anyway**. Removing that
step takes an Apple Developer account, `codesign` with its certificate and
`xcrun notarytool`.

## Finding lyrics for a file that has none

The whole point of the app is words that are timed to the syllable, so
looking for them is built in rather than left to the user and a browser.
**Find Lyrics** on the Now Playing screen does one track; an album page does
the rest of the record; right-clicking a song does just that song.

Two providers, asked in this order:

1. **Apple**, through a public relay — the only source that times
   *syllables*, which is what makes the word-by-word display possible
2. **LRCLIB** — free, fast, and line-level

The order matters and is not a preference. Every provider is asked at once
but they are *read* in order: LRCLIB answers in about a tenth of a second
against Apple's one, so taking whoever finishes first turns the list into a
set and reliably yields plain line-level lyrics — the word-by-word ones the
order asked for would never get used.

What comes back is written as an `.lrc` next to the audio file, which is
where the app looks first anyway: the result survives a restart, can be
fixed by hand, and is read by anything else that understands sidecars. A
folder that cannot be written to falls back to a cache in Application
Support.

This is a Swift port of SpotiFLAC's `core/lyrics.py`, ported rather than
shelled out to because it is the feature the app exists for and cannot
depend on a `pip install`.

```bash
swift run LyricsCheck --fetch "Title" "Artist" [album] [duration]
```

## Recap

**Recap**, in the sidebar, is a Wrapped-style summary of what you played in
FLACintosh — for the last 30 days, this year or all time: minutes listened,
top songs, artists and albums, when in the day you listen, your longest
streak of days and your biggest one.

A play counts the way Last.fm counts a scrobble: half the song, or four
minutes of a long one, and never a track under thirty seconds. Only time
actually heard is added. The history is one JSON line per play in
`~/Library/Application Support/FLACintosh/listening-history.jsonl`, never
sent anywhere, and can be cleared from the bottom of the Recap.

## Discord

Settings (⌘,) → **Discord** shows the song on your Discord profile as
"Listening to", with the artist, album, a progress bar and the cover.

Discord only shows Rich Presence for an application registered with it, and
the application's name is what appears. Create one at
[discord.com/developers/applications](https://discord.com/developers/applications),
call it FLACintosh, and paste its **Application ID** in Settings. The Discord
desktop app has to be running: presence goes over its local socket, not the
internet. Covers are looked up on Apple Music by artist and album — Discord
can only show a picture with a public address — and only one whose artist
matches is used.

## Google Cast

The Cast button next to AirPlay plays on any Google Cast receiver on the
network: Chromecast, TVs with Google TV, Nest speakers, speaker groups.
Server tracks the receiver can decode go to it straight from the server, so
they keep playing with the Mac asleep. Local files are served from the Mac,
and what a receiver cannot play — ALAC, AIFF, APE, WavPack, DSD, anything over
96 kHz / 24 bit — is converted to FLAC first. The first time, macOS asks
whether FLACintosh may accept incoming connections: that is the receiver
fetching the music.

## Servers

Navidrome (or anything speaking Subsonic) and Jellyfin, added from the
sidebar. Passwords go in the keychain.

Tracks are fetched whole to a cache before they play, because SFBAudioEngine
reads files and not streams — its input source asserts `url.isFileURL`. That
turns out to be worth something rather than merely necessary: the cached file
carries its own tags and artwork, so covers, metadata and the lyrics search
all work exactly as they do for a local library.

The cache is capped at **2 GB** by default — enough for an evening of
lossless listening, since a FLAC album is 250-400 MB — and the limit is
yours to change in Settings (⌘,), or to remove. When it is exceeded the
least recently played tracks go first, ordered by modification date rather
than access date: a volume mounted `noatime` makes every file look equally
old, and eviction becomes random. A local folder library uses none of this.

## SpotiFLAC

Optional, and genuinely so: nothing is bundled, nothing here is required,
and the app carries on without it. The Download shelf offers two ways in.

### A SpotiFLAC server

SpotiFLAC started with `--web` — in Docker, say, next to Jellyfin — is
reached over its own web API. Give the Download shelf its address and the
token set with `--web-token` / `SPOTIFLAC_WEB_TOKEN` (kept in the Keychain),
and the window's search field searches Spotify on that shelf:

- albums, songs and playlists, each marked **In Library** when the library
  already has it — same title and artist, edition notes such as
  "(Remastered)" ignored;
- **Download** resolves the link on the server, then queues every track with
  the download settings saved there, so the result is exactly what the
  server's own page would have produced;
- progress comes over the server's WebSocket; when a batch ends, each
  Jellyfin is asked to scan and the servers are read again shortly after.

In token mode the server keeps one working track list, shared with anyone
on its web page at the same moment, so downloads from here run one after
another.

### SpotiFLAC on this Mac

```bash
pip install spotiflac
```

Installed, it is found through a login shell (an app launched from Finder
inherits almost no `PATH`, and SpotiFLAC lives wherever the user's Python
does), and the Download shelf opens its terminal UI (`--tui`) in Terminal, in
the library folder — so what it downloads, `--save-lrc` sidecars included, is
already where ⌘R will find it.

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
| `FLACintosh` | The SwiftUI app. |
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

The Now Playing screen, and Apple Music's palette: **pink `#FF4E6B`**, **red
`#FF0436`**, **white `#FFFFFF`**. Those three are the only colours the app is
allowed to invent. Everything else on screen comes off the record itself.

The ground is the cover's own colours: four dominant tints pulled out of a
48-pixel thumbnail, pinned to a brightness white text can be read over, and
drifting behind the words as soft radial blobs. No blur filter is involved —
a blur is re-rasterised whenever what is under it moves, while a gradient
that only slides and scales is a transform the render server animates by
itself. That is what lets the background move behind lyrics that are already
redrawing every frame.

A washed-out sleeve gets its saturation lifted; a vivid one is left exactly
as it was (clamping everything to one value turned two different browns into
the same brown); a genuinely grey one stays grey, because the hue a grey
reports is rounding error and borrowing it would tint the window a colour
that is nowhere on the cover. A file with no cover falls back to pink and
red.

The stage is dark in both system appearances, and that is a decision rather
than an oversight: white lyrics over an album's own colours only work on a
dark ground, and flipping to a light one would mean giving up either the
artwork tint or the white text. Apple Music makes the same call.

### The effect

Not "colour the current word". Each syllable fills white across its own
duration behind a soft gradient edge, so the light travels *through* a long
word; the lines around the current one dim, blur and shrink slightly rather
than vanishing. That continuous motion is what the eye reads as following a
voice.

The brand is used as light rather than as paint: a pink-to-red band rides the
front of the sweep and is gone the moment the syllable ends. Colouring whole
words instead would be unreadable at thirty points, and would say nothing
about where in the word the voice is.

`SyllableFlow` exists because an `HStack` never wraps and a single `Text`
cannot animate its pieces independently — a line of lyrics needs both.

## Licence

MIT — see [LICENSE](LICENSE). [SFBAudioEngine](https://github.com/sbooth/SFBAudioEngine), the one dependency, is MIT too.
