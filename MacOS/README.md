<div align="center">

<img src="Assets/AppIcon.png" alt="FLACintosh icon" width="128" height="128" />

# FLACintosh

**A music player for your own lossless library, with lyrics that light up word by word.**

[![Latest release](https://img.shields.io/github/v/release/BartolomeoRusso9/FLACintosh?style=flat-square&color=FF0436&label=release)](https://github.com/BartolomeoRusso9/FLACintosh/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/BartolomeoRusso9/FLACintosh/total?style=flat-square&color=FF4E6B)](https://github.com/BartolomeoRusso9/FLACintosh/releases)
[![macOS 15+](https://img.shields.io/badge/macOS-15%2B-000000?style=flat-square&logo=apple&logoColor=white)](#requirements)
[![Swift 6](https://img.shields.io/badge/Swift-6-F05138?style=flat-square&logo=swift&logoColor=white)](DEVELOPMENT.md)
[![License: MIT](https://img.shields.io/badge/license-MIT-brightgreen?style=flat-square)](LICENSE)

[**Download**](https://github.com/BartolomeoRusso9/FLACintosh/releases/latest) ·
[Features](#features) ·
[Installation](#installation) ·
[Getting started](#getting-started) ·
[Troubleshooting](#troubleshooting)

</div>

---

FLACintosh plays the music you own — FLAC, ALAC and every other format —
from a folder on your Mac or from your own Jellyfin or Navidrome server. It
looks and feels like Apple Music, and it does the one thing Apple Music and
Spotify will not do for your files: show **synchronised lyrics that follow
the singer syllable by syllable**.

A native Mac app written in SwiftUI — no Electron, no web view, no account.

## Why FLACintosh?

|  | FLACintosh | Apple Music | Spotify |
| --- | :---: | :---: | :---: |
| Word-by-word lyrics for your own files | ✅ | ❌ | ❌ |
| Line-by-line lyrics for your own files | ✅ | ❌ | ❌ |
| Finds missing lyrics and saves them | ✅ | ❌ | ❌ |
| Plays from Jellyfin and Navidrome | ✅ | ❌ | ❌ |
| Real bit depth and sample rate shown | ✅ | Partly | ❌ |
| Plays FLAC, APE, WavPack, DSD | ✅ | ❌ | ❌ |
| Google Cast | ✅ | ❌ | ✅ |
| Offline downloads from your own server | ✅ | ❌ | ❌ |
| Equalizer | ✅ | ✅ | ✅ |
| Last.fm / ListenBrainz scrobbling | ✅ | ❌ | Last.fm |
| Listening recap | ✅ | ✅ | ✅ |
| Local files without an account | ✅ | ✅ | ❌ |

## Features

- **Word-by-word lyrics.** Each syllable fills in as it is sung. Lyrics come
  from a `.lrc` file next to the song or from the file itself, and when a
  song has none, **Find Lyrics** looks them up for you.
- **Your whole library in one place.** A music folder and any number of
  Jellyfin or Navidrome servers, shown together as albums, artists and songs,
  with search.
- **Real audio quality.** Now Playing shows the actual bit depth and sample
  rate of what is playing — 24 bit · 96 kHz, not a guess.
- **A beautiful Now Playing screen.** Big cover art, colours taken from the
  album, the queue, shuffle, repeat, AutoPlay and Crossfade. Spotify Canvas
  videos play in place of the cover when you have them.
- **Play anywhere.** AirPlay, and **Google Cast** — Chromecast, TVs with
  Google TV, Nest speakers and speaker groups. Formats a Cast device cannot
  play are converted automatically.
- **Playlists.** Make your own from any mix of folder and server songs,
  and play the playlists already on your Jellyfin or Navidrome server.
- **Offline listening.** Download server albums and play them without the
  server.
- **Sound.** A 10-band equalizer with presets, ReplayGain, and gapless
  playback for live albums and mixes.
- **Recap.** Your own Wrapped: minutes listened, top songs, artists and
  albums, when you listen and your longest streak.
- **Scrobbling** to Last.fm and ListenBrainz.
- **Menu bar player** with the current lyric line.
- **Discord.** Show what you are listening to on your Discord profile.
- **Works with your Mac.** Control Center, the menu bar, your keyboard's
  media keys and AirPods controls all work.
- **Download music (optional).** Search Spotify and download in lossless
  quality through [SpotiFLAC](https://github.com/BartolomeoRusso9/SpotiFLAC-Module-Version).
- **Edit tags** — title, artist, album and more — with **Get Info…**.

## Supported sources and formats

**Sources**

- A folder on your Mac (subfolders included) — `~/Music` by default
- [Jellyfin](https://jellyfin.org)
- [Navidrome](https://navidrome.org), and other servers with a Subsonic API
  such as Gonic or Airsonic-Advanced *(Navidrome is the one tested)*

**Audio formats**

| Lossless | Lossy | DSD |
| --- | --- | --- |
| FLAC, ALAC, WAV, AIFF, Monkey's Audio (APE), WavPack, TTA, Shorten | MP3, AAC (M4A, M4B), Ogg Vorbis, Opus, Musepack | DSF, DFF |

High-resolution files play at their full sample rate and bit depth.

**Lyrics**: Enhanced LRC (word timing), LRC (line timing), embedded or as a
`.lrc` file.

## Requirements

- macOS 15 Sequoia or later
- Apple Silicon or Intel Mac

## Installation

1. Download the latest **FLACintosh-x.y.z.dmg** from the
   [Releases](../../releases) page.
2. Open it and drag **FLACintosh** into **Applications**.
3. Open FLACintosh. The first time, macOS will say it cannot verify the
   developer: open **System Settings → Privacy & Security**, scroll down and
   click **Open Anyway**. You only need to do this once.

## Getting started

**Play music from your Mac.** FLACintosh reads your **Music** folder. To use
another one, click **Choose Folder…** at the bottom of the sidebar (or press
⇧⌘O). Subfolders are included.

**Play music from a server.** Click **Add Server…** in the sidebar, choose
**Jellyfin** or **Navidrome / Subsonic**, and enter the server address with
your username and password. The password is stored in your Mac's Keychain;
when macOS asks for your Mac's password to let FLACintosh read it, choose
**Always Allow**.

Each source appears under **Sources** in the sidebar, where you can hide it,
reload it or remove it. When files change, click the **reload** button in the
toolbar (or press ⌘R).

**Play a single file** by dragging it onto the window or with **File → Open
File…** (⌘O).

## Lyrics

FLACintosh shows lyrics from, in this order:

1. a `.lrc` file with the same name as the song, in the same folder;
2. lyrics embedded in the song file.

Lyrics with per-word timing (Enhanced LRC) light up word by word; ordinary
LRC lyrics highlight line by line.

**No lyrics?** On the Now Playing screen click **Find Lyrics**. To do a
whole album at once, click **Find lyrics for … tracks** on the album page; for a single song,
right-click it and choose **Find Lyrics**. FLACintosh asks Apple Music first
(word-by-word timing) and LRCLIB second, and saves what it finds as a `.lrc`
file next to the song, so it is there next time.

While lyrics are playing you can scroll freely — click **Back to Current
Line** to jump back — or click any line to skip to that part of the song.

## Now Playing

Click the player bar at the bottom of the window to open Now Playing; press
**Esc** to close it.

- Click the **artist** or **album** name to open its page in the library.
- The buttons in the bottom-right corner switch between **lyrics** and the
  **queue**. The queue is also where **AutoPlay** (keep playing when the queue
  ends) and **Crossfade** are.
- If a song has a Canvas video (an `.mp4` with the same name next to it), it
  plays silently in place of the cover.

## Playlists

Click **New Playlist** under **Playlists** in the sidebar, or right-click any
song — or use the **•••** button on an album page — and choose **Add to
Playlist**. A playlist can mix songs from your Mac and from your servers.

On a playlist's page, drag songs to reorder them, right-click a song to
remove it, and use **•••** to rename or delete the playlist. In Now Playing,
**Save as Playlist** turns the queue into a playlist.

Playlists from your Jellyfin or Navidrome server appear in the same list,
marked with the server's icon. They are shown as the server has them; edit
them on the server.

## Offline listening

On the page of an album from a server, click **Download for offline
listening** (or **•••** → **Download**). Downloaded albums:

- play from your Mac even when the server is off or you are away from home;
- are listed under **Downloaded** in the sidebar;
- can be removed from the album page, or all at once in **Settings →
  Storage**.

## Sound: equalizer, ReplayGain and gapless

Open the **Equalizer** with the slider button next to the volume in Now
Playing, from **Controls → Equalizer…** (⌥⌘E) or from the menu bar player.
Pick a preset or drag the ten bands; double-click a band to reset it.
FLACintosh lowers the overall level by as much as the highest boost, so the
equalizer never makes a song clip.

**ReplayGain** (Settings → Playback, or the Equalizer window) evens out the
loudness between songs using the ReplayGain tags in your files. **Track**
makes every song equally loud; **Album** keeps the differences between songs
of the same album.

**Gapless playback** joins songs without a gap — essential for live albums,
classical works and DJ mixes. It is on by default and works for songs on
your Mac and downloaded songs. When **Crossfade** is on, it takes its place.

## Playing on other speakers and TVs

**AirPlay** — click the AirPlay button next to the volume slider and pick a
speaker or Apple TV.

**Google Cast** — click the Cast button next to it. Every Cast device on your
network is listed; choose one and the music moves there, from the same point
in the song. Choose **This Mac** to bring it back.

- Songs from a Jellyfin or Navidrome server play straight from the server,
  so they keep playing even if your Mac goes to sleep.
- Songs from your Mac are sent from the Mac, which needs to stay awake. The
  first time, macOS asks whether FLACintosh may **accept incoming network
  connections**: choose **Allow** — that is the Cast device fetching the music.
- Hi-res files (above 96 kHz / 24 bit) and formats Cast devices cannot play,
  such as ALAC, AIFF, APE, WavPack or DSD, are converted automatically.

## Recap

Open **Recap** in the sidebar to see your listening for the **last 30 days**,
**this year** or **all time**: minutes listened, your top songs, artists and
albums, what time of day you listen most, and your longest streak.

A song counts once you have listened to half of it (or four minutes of a long
one); skipped songs do not count. Double-click a top song to play it. Your
history stays on your Mac, and **Clear Listening History…** at the bottom of
the Recap deletes it.

## Scrobbling

FLACintosh can send what you listen to to **Last.fm** and **ListenBrainz** —
in **Settings → Services**. A song is scrobbled once you have listened to half
of it (or four minutes); while it plays it shows as "now playing". Scrobbles
that cannot be sent, for example when you are offline, are kept and sent later.

**ListenBrainz:** copy your user token from
[listenbrainz.org/settings](https://listenbrainz.org/settings/), turn on
**Submit listens to ListenBrainz** and paste it.

**Last.fm:** create an API account at
[last.fm/api/account/create](https://www.last.fm/api/account/create) (any
name and description will do), turn on **Scrobble to Last.fm**, paste the
**API key** and **shared secret**, and click **Connect…**. Last.fm opens in
your browser: click **Yes, allow access**, and FLACintosh connects on its own.

## Menu bar player

The note icon in the menu bar opens a small player: cover, song, the lyric
line being sung, progress, controls, volume and the equalizer. Turn it off in
**Settings → Playback**.

## Discord

FLACintosh can show **Listening to** on your Discord profile, with the song,
artist, album, cover and a progress bar.

1. Go to the [Discord Developer Portal](https://discord.com/developers/applications)
   and click **New Application**. Name it **FLACintosh** — Discord shows this
   name on your profile.
2. Copy the **Application ID** from the application's page.
3. In FLACintosh open **Settings** (⌘,), turn on **Show what you're listening
   to** in the **Discord** section and paste the Application ID.

The Discord desktop app must be running. If nothing shows up, check that
**Share your detected activities with others** is on in Discord's **Activity
Privacy** settings.

## Downloading music with SpotiFLAC

This is optional — FLACintosh works fine without it. Open **Download** in the
sidebar.

**With a SpotiFLAC server** (for example running next to Jellyfin): enter the
server address and its access token. Then type in the search field to search
Spotify. Click an album, playlist or artist to see its tracks, and click
**Download** — or select just the tracks you want. Anything already in your
library is marked **In Library**. When downloads finish, your Jellyfin
library is refreshed automatically.

**With SpotiFLAC on this Mac:** install it with `pip install spotiflac`, then
click **Open TUI** to use it in Terminal. It downloads into your library
folder.

## Settings

Open **FLACintosh → Settings** (⌘,).

- **Playback** — gapless playback, ReplayGain, the equalizer and the menu
  bar player.
- **Services** — [Last.fm, ListenBrainz](#scrobbling) and
  [Discord](#discord).
- **Storage** — your offline downloads, and the server track cache: songs
  from a server stream, but FLACintosh keeps the part of each file with its
  cover, tags and lyrics. The cache is limited to 2 GB by default; you can
  change the limit or empty it here.

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| ⌘O | Open a file |
| ⇧⌘O | Choose the library folder |
| ⌘R | Reload the library |
| ⌘, | Settings |
| ⌘↩ | Play / pause |
| ⌘→ / ⌘← | Next / previous song |
| ⌘↑ / ⌘↓ | Volume up / down |
| ⌥⌘E | Equalizer |
| Esc | Close Now Playing |
| Media keys | Play/pause, next, previous |

## Privacy

FLACintosh has no account, no analytics and no tracking. Your library,
listening history and settings stay on your Mac; server passwords are kept
in the Keychain. The app only goes online to:

- talk to **your own servers** and Cast devices;
- look up **lyrics** when you click Find Lyrics (Apple Music, through a
  public relay, and LRCLIB — only the song's title, artist, album and length
  are sent);
- look up **album covers on Apple Music** for Discord, only if the Discord
  feature and **Show album art** are on;
- send your listens to **Last.fm** or **ListenBrainz**, only if you turn
  scrobbling on.

Tokens and secrets for Last.fm and ListenBrainz are kept in the Keychain.

## Troubleshooting

**"FLACintosh can't be opened because Apple cannot check it"** — see step 3
of [Installation](#installation).

**My Cast device is not listed** — make sure it is on the same network as
your Mac, and that FLACintosh is allowed in **System Settings → Privacy &
Security → Local Network**.

**A song from my Mac will not play on the Cast device** — FLACintosh needs
to accept incoming connections. Check **System Settings → Network →
Firewall → Options** and allow FLACintosh.

**An AirPlay device shows up but will not connect** — some devices shown in
the AirPlay list are bridges for older AirPlay 1 speakers (for example
AirConnect for Chromecasts), which macOS cannot use as a system output. Use
the Cast button for those instead.

**macOS keeps asking for my password** — when asked about the Keychain, choose
**Always Allow**. You may be asked again after installing a new version.

**Last.fm says "Waiting for approval" and nothing happens** — approve
FLACintosh on the Last.fm page that opened in your browser within two
minutes, then click **Connect…** again if needed.

**Gapless does not seem to work** — it applies to songs on your Mac and
downloaded songs, not to songs streaming from a server, and it is replaced by
Crossfade when that is on.

**Lyrics highlight whole lines, not words** — those lyrics only have
line-level timing. Try **Find Lyrics** again later: word-by-word lyrics
come from Apple Music and are not available for every song.

## Roadmap

Ideas for what comes next — suggestions are welcome in
[Issues](https://github.com/BartolomeoRusso9/FLACintosh/issues).

- [x] Playlists, and your server's playlists
- [x] Gapless playback and ReplayGain
- [x] Equalizer
- [x] Last.fm / ListenBrainz scrobbling
- [x] Offline downloads of server music
- [x] Menu bar mini player
- [ ] Desktop and Notification Center widget
- [ ] Localisation

## Feedback and contributing

Found a bug or have an idea? [Open an issue](https://github.com/BartolomeoRusso9/FLACintosh/issues/new)
— for a bug, include your macOS version, where the music comes from (folder,
Jellyfin, Navidrome) and the file format. Pull requests are welcome; see
[DEVELOPMENT.md](DEVELOPMENT.md) to get the project building.

## Acknowledgements

- [SFBAudioEngine](https://github.com/sbooth/SFBAudioEngine) — the audio
  engine behind every format FLACintosh plays
- [LRCLIB](https://lrclib.net) — free, open synchronised lyrics
- [SpotiFLAC](https://github.com/BartolomeoRusso9/SpotiFLAC-Module-Version) —
  downloads and the lyrics format FLACintosh was built to show
- [Jellyfin](https://jellyfin.org) and [Navidrome](https://navidrome.org) —
  your music, served
- [Feishin](https://github.com/jeffvli/feishin),
  [Supersonic](https://github.com/supersonic-app/supersonic) and
  [Finamp](https://github.com/jmshrv/finamp) — fellow players for self-hosted
  music, and inspiration

## Building from source

See [DEVELOPMENT.md](DEVELOPMENT.md).

## License

FLACintosh is released under the [MIT License](LICENSE). It uses
[SFBAudioEngine](https://github.com/sbooth/SFBAudioEngine), also MIT.
