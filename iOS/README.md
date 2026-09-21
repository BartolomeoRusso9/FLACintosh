# FLACintosh for iPhone and iPad

The iOS app is the macOS app compiled a second time. There is no copy of the
code: the Xcode project in this folder builds the sources in
[`../MacOS/Sources/FLACintosh`](../MacOS/Sources/FLACintosh), and whatever only
makes sense on a Mac is fenced with `#if os(macOS)` (see
[`Platform.swift`](../MacOS/Sources/FLACintosh/Platform.swift) for the one place
that knows about AppKit and UIKit). The entry point is
[`IOSApp.swift`](../MacOS/Sources/FLACintosh/IOSApp.swift).

## What is different from the Mac

| | Mac | iPhone |
| --- | --- | --- |
| Navigation | Sidebar | Tab bar: Home, Library, Download, Recap, Settings (an iPad keeps the sidebar) |
| Now Playing | Two columns | One column with three pages: record, lyrics, queue |
| Mini player | Full transport, volume, AirPlay, Cast | Sleeve, title, play/pause, next — the rest is on Now Playing |
| Equalizer | Window | Sheet |
| Settings | ⌘, window | Tab |
| Library folder | Any folder | The app's Documents folder (visible in Files), or a folder picked with **Choose Folder…** |
| Not on iOS | | Menu bar player, Discord, the local SpotiFLAC terminal bridge |

Servers (Navidrome, Jellyfin, Subsonic), synchronised lyrics, offline
downloads, the equalizer, ReplayGain, Cast, scrobbling and the Recap work the
same way. Downloads still go through your SpotiFLAC server over HTTP.

## Build

You need a full Xcode (the iOS SDK) and [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
brew install xcodegen
cd iOS
xcodegen generate            # writes FLACintosh.xcodeproj (not committed)
open FLACintosh.xcodeproj
```

From the command line, for the simulator:

```sh
xcodebuild -project FLACintosh.xcodeproj -scheme FLACintosh-iOS \
  -destination 'generic/platform=iOS Simulator' build
```

The scheme is called `FLACintosh-iOS`, not `FLACintosh`: the Mac package has a
product of that name, and two schemes called the same make `xcodebuild` build
either one — the Mac executable instead of the app.

## Run on a device

1. In Xcode, select the **FLACintosh-iOS** target → **Signing & Capabilities**.
2. Choose your Apple ID as the **Team** (a free account works; the install
   expires after seven days). If Xcode complains about the bundle identifier,
   change it to one of yours.
3. Pick the iPhone as the run destination and press **Run**. Trust the
   developer on the phone under **Settings → General → VPN & Device
   Management** if it asks.

## Putting music on it

- **From a server:** Library → **Add Server…**, or Home → Sources.
- **From files:** open the **Files** app → On My iPhone → FLACintosh, and drop
  audio files there; they show up after a reload (the arrow at the top of Home
  and Library).
- **From another folder:** Library → **Choose Folder…**. The folder is
  remembered across launches with a security-scoped bookmark.

## Development aids

Debug builds (not release) read a few launch arguments, useful because the
simulator cannot tap on its own:

```sh
# play a file at launch (a path the app can read), on the Recap tab
xcrun simctl launch booted io.github.bartolomeorusso9.flacintosh \
  /path/to/track.flac -phoneTab recap

# open Now Playing on its lyrics page
xcrun simctl launch booted io.github.bartolomeorusso9.flacintosh \
  /path/to/track.flac -showNowPlaying YES -phonePage lyrics
```

`-phoneTab` takes `home`, `library`, `download`, `recap` or `settings`;
`-phonePage` takes `player`, `lyrics` or `queue`.

## Known limits

- Tested on the simulator only. Playback, decoding of FLAC and the layouts are
  checked there; lock-screen controls, Cast, the Files folder picker and
  background playback still need a real device.
- The listening history is written when the app is closed normally. On iOS an
  app is usually suspended and then killed without being told, so a listen in
  progress at that moment can be lost.
- The App Store needs a paid Apple Developer account, a distribution
  certificate and screenshots; none of that is set up here.
