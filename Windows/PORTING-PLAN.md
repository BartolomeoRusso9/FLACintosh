# FLACintosh → Windows port status

The Windows port is now a feature-complete first-pass implementation rather than only a UI skeleton.

| FLACintosh area | Windows implementation | Status |
|---|---|---|
| Library models | `Core/Library` | ✅ |
| Local scanner / metadata | `LibraryScanner` + TagLib# | ✅ |
| Library projection / search | `LibraryStore` | ✅ |
| Lyrics parsing / Enhanced LRC | `Core/Lyrics` | ✅ |
| Lyrics sidecars / fetching | `LyricsSidecar` / `LyricsFetcher` | ✅ |
| Queue / shuffle / repeat / AutoPlay | `Core/Playback` | ✅ |
| Local audio | `WindowsAudioGraphEngine` | ✅ |
| Dual deck / crossfade | `WindowsDualDeckAudioEngine` | ✅ |
| Gapless | prepared-next near-gapless handoff | 🟡 platform limitation |
| ReplayGain | Track / Album + peak guard | ✅ |
| Equalizer | 10-band Windows AudioGraph EQ | ✅ |
| SMTC | WinRT SystemMediaTransportControls | ✅ |
| Jellyfin | `JellyfinClient` | ✅ |
| Navidrome / Subsonic | `SubsonicClient` | ✅ |
| Remote cache | `RemoteCache` | ✅ |
| Offline | `OfflineStore` | ✅ |
| Local playlists | `PlaylistStore` + detail UI | ✅ |
| Server playlists | read-only merged list | ✅ |
| Listening history | `ListeningHistoryStore` | ✅ |
| Recap | `HistoryPage` | ✅ |
| Metadata editor | `AudioMetadataEditor` | ✅ |
| Global search | `SearchPage` | ✅ |
| Album / artist details | dedicated pages | ✅ |
| Syllable lyric UI | `SyllableFlowPanel` | ✅ |
| Artwork palette | `ArtworkPaletteService` | ✅ |
| Canvas | `MediaPlayerElement` + `CanvasLocator` | ✅ |
| Discord | `DiscordRichPresenceService` | ✅ |
| Last.fm | `ScrobblingService` | ✅ |
| ListenBrainz | `ScrobblingService` | ✅ |
| SpotiFLAC server | `SpotiFlacServerClient` + UI | ✅ |
| SpotiFLAC local CLI | `SpotiFlacCliBridge` | ✅ |
| Google Cast | `CastDiscoveryService` + `CastV2Client` + `LocalMediaServer` | ✅ first-pass |
| Tray | `TrayService` | ✅ |
| File associations | `FileAssociationService` | ✅ |
| Packaging scripts | `scripts/publish-*.ps1` | ✅ |
| AirPlay | — | ⛔ not ported directly |
| Sample-accurate gapless | — | ⛔ not exposed by current public Windows path |

## Final verification

The current environment does not contain the Windows/.NET toolchain, so no claim of a successful WinUI compilation is made here. Static validation has covered project structure, XAML parsing, handler references, and obvious C# integration errors.

The authoritative build/test commands are in `BUILD-WINDOWS.md`.


## 0.8.0 release hardening
- Source visibility, drag & drop, daily recap, server editing, theme dictionaries, tray/startup polish and Windows CI were added.
- AirPlay remains intentionally excluded from the Windows parity target.
- Sample-accurate gapless remains a documented platform/audio-backend limitation; the released implementation is near-gapless with dual deck + crossfade.
