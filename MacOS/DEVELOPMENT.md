# FLACintosh — development

Notes for building, packaging and working on FLACintosh. What the app does and
how to use it is in the [README](../README.md).

## Running from source

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

## Servers

Navidrome (or anything speaking Subsonic) and Jellyfin. Passwords go in the
keychain.

Server tracks stream: AVPlayer reads them over HTTP with byte ranges, so a
track starts almost at once and seeking does not need the rest of the file.
What is cached is the front of each file — its tags, embedded lyrics and
cover, usually a megabyte or two — so Now Playing shows what it would for a
local file. Formats AVFoundation cannot stream (Opus, Vorbis, …) are fetched
whole and handed to SFBAudioEngine, which reads files, not URLs.

The cache is capped at **2 GB** by default, changeable in Settings (⌘,). When
it is exceeded the least recently played files go first, ordered by
modification date rather than access date: a volume mounted `noatime` makes
every file look equally old, and eviction becomes random.

## Google Cast

There is no Cast SDK for macOS, so the protocol is spoken directly
(`Sources/FLACintosh/Cast`): Bonjour `_googlecast._tcp` discovery, a TLS
socket to port 8009 carrying length-prefixed protobuf `CastMessage`s (the one
message is encoded by hand), and Google's Default Media Receiver
(`CC1AD845`).

A server track the receiver can decode is handed to it by URL, with the
host resolved to an IP address first — Chromecasts often use Google's DNS,
which knows nothing about `.lan` names. Everything else is served by a small
HTTP server in the app (`CastMediaServer`, random paths, range requests), and
anything over 96 kHz / 24 bit, more than two channels, or in a codec the
receiver lacks is converted to FLAC with SFBAudioEngine first and cached in
`~/Library/Caches/macos-music-player/cast` (1 GB cap). If a receiver refuses
a direct URL, the same track is retried through the Mac.

## Sound

`Audio/AudioEffects.swift` holds the settings and both implementations. Local
files play through SFBAudioEngine, whose graph gets an `AVAudioUnitEQ`
between the source node and the main mixer (`DeckEffects`, which is also the
player's delegate: it reconnects the EQ on format changes and reports when an
enqueued file starts, which is how gapless advances the queue). Server
streams play through AVPlayer, so the same curve — RBJ peaking biquads, one
octave wide — runs in an `MTAudioProcessingTap` (`StreamEffects`). ReplayGain
and the equalizer's headroom are the EQ's global gain on one path and a
multiply on the other.

Gapless enqueues the next playable file (local, or a downloaded copy of a
server track) on the live deck with `AudioPlayer.enqueue`.

## Playlists, downloads and scrobbling

Track identity across launches is `LibraryTrack.key`: a file's path, or a
server URL's fingerprint without credentials (Subsonic builds a new salt for
every URL, Jellyfin a new token per login). Anything written to disk uses
`LibraryTrack.storable(_:)`, which drops the credentials.

- `PlaylistStore` — `~/Library/Application Support/FLACintosh/playlists.json`;
  server playlists come from `MusicServerClient.playlists()`.
- `OfflineStore` — `…/FLACintosh/Offline/`, a manifest plus one file per
  track; `PlaybackModel.localCopy` prefers it over the stream.
- `Scrobbler` — fed by `ListeningHistory.onPlay`; unsent scrobbles in
  `…/FLACintosh/scrobble-queue.json`, secrets in the Keychain.

## Discord and the Recap

Discord Rich Presence goes over Discord's local IPC socket
(`$TMPDIR/discord-ipc-0`): a handshake with the application ID, then
`SET_ACTIVITY` frames — little-endian opcode and length, then JSON.

The Recap reads `~/Library/Application Support/FLACintosh/listening-history.jsonl`,
one play per line, written by `ListeningHistory` once a play qualifies.

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
