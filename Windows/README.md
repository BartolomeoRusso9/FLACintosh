# MusicPlayerWin

Windows counterpart of FLACintosh, implemented with .NET 8 + WinUI 3.

The repository keeps reusable library/playback logic in `MusicPlayerWin.Core` and Windows-specific UI, WinRT, SMTC, tray and integration code in `MusicPlayerWin.App`.

## What is ported

### Library and playback

- Recursive local music scanning with TagLib# metadata and artwork.
- Local and server albums, artists and songs in one library projection.
- Queue, shuffle, repeat and AutoPlay.
- Previous/next, seek, volume and global keyboard shortcuts.
- Dual-deck prepared-next playback with crossfade and near-gapless handoff.
- ReplayGain Track / Album mode with peak protection and preamp.
- 10-band equalizer, presets and automatic headroom.
- Windows System Media Transport Controls with timeline, media keys and artwork.
- Embedded lyrics, `.lrc` sidecars, LRCLIB fetching and Enhanced-LRC syllable timing.
- Dynamic artwork palette and local Canvas/video playback when a matching `.mp4`, `.m4v` or `.mov` is present.

### Sources, storage and playlists

- Jellyfin.
- Navidrome / Subsonic.
- Remote cache for server playback.
- Offline downloads.
- Local playlists with rename, remove, reorder and Save Queue as Playlist.
- Read-only server playlists.
- Listening history and Recap.
- Local metadata/tag editor.

### Desktop integrations

- Discord Rich Presence over the local Discord IPC pipe.
- Last.fm scrobbling and Now Playing; session/shared-secret material is kept in Windows Credential Manager.
- ListenBrainz scrobbling and Now Playing.
- SpotiFLAC web-server search/download integration and local CLI TUI bridge.
- Google Cast V2 sender with mDNS discovery and temporary HTTP serving for local files.
- System tray controls.
- Per-user audio file associations.

## Known platform differences

The Windows audio pipeline uses the public Windows AudioGraph/MediaSource APIs. The handoff is intentionally described as **near-gapless**, not sample-accurate, because the public API does not provide the same sample-level deck scheduling semantics as the macOS audio stack.

AirPlay is not implemented as a direct Windows counterpart. Google Cast is supported instead.

Discord artwork uses a public iTunes Search lookup, matching the macOS strategy of supplying Discord with a public image URL rather than trying to upload private artwork.

## Build

See `BUILD-WINDOWS.md` and the scripts in `scripts/`.

```powershell
./scripts/build.ps1
./scripts/test.ps1
./scripts/publish-win-x64.ps1
./scripts/package-installer.ps1
```

A real WinUI build requires the Windows SDK/toolchain, so repository-side static validation has been performed here but the final compile/test must be run on Windows.

### Desktop UX
Source visibility, drag & drop playback, system tray, startup launch, SMTC media keys, keyboard seek shortcuts, per-user file associations and an Inno Setup packaging path are included.

AirPlay is intentionally excluded from the Windows target; Google Cast is the supported network playback integration.
