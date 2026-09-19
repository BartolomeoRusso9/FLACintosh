# MusicPlayerWin feature matrix

This is the final first-pass Windows parity map for the FLACintosh port.

| Area | Windows status | Notes |
|---|---|---|
| Local library | ✅ | Recursive scan, TagLib metadata, embedded/folder artwork |
| Server library | ✅ | Jellyfin + Navidrome/Subsonic |
| Queue | ✅ | Next/previous, shuffle, repeat, autoplay, clear, remove |
| Playback | ✅ | AudioGraph local playback |
| Dual deck | ✅ | Active/standby decks |
| Crossfade | ✅ | Configurable |
| Gapless | 🟡 | Near-gapless public-Windows handoff; sample-accurate boundary scheduling is not exposed by the current Windows API path |
| ReplayGain | ✅ | Track/Album, preamp, peak guard |
| EQ | ✅ | 10-band, presets, automatic headroom |
| Lyrics | ✅ | LRC, Enhanced LRC, embedded lyrics, LRCLIB |
| Syllable timing | ✅ | Enhanced-LRC syllable flow panel |
| Search | ✅ | Tracks, albums, artists |
| Album/artist details | ✅ | Dedicated pages |
| Playlists | ✅ | Local create/edit/reorder + queue save |
| Server playlists | ✅ | Read-only remote playlists |
| Offline | ✅ | Remote album downloads + manifest |
| Listening history | ✅ | Persistent history + recap view |
| Metadata editor | ✅ | Local file tag editing |
| SMTC | ✅ | Media keys + timeline + seek |
| System tray | ✅ | Basic transport menu |
| Canvas | ✅ | Adjacent MP4/M4V/MOV playback |
| Palette | ✅ | Artwork-derived background palette |
| Discord | ✅ | Local IPC Rich Presence |
| Last.fm | ✅ | Now Playing + scrobble queue |
| ListenBrainz | ✅ | Now Playing + scrobble queue |
| SpotiFLAC | ✅ | Web API integration + local CLI bridge |
| Google Cast | ✅ | mDNS discovery + V2 sender + local HTTP serving |
| AirPlay | ⛔ | No direct Windows protocol counterpart included |
| File associations | ✅ | Per-user registration |
| Drag & drop | ✅ | Audio files can be dropped onto the main window |
| Source visibility | ✅ | Per-source hide/show persisted across launches |
| Installer | ✅ | Inno Setup definition + publish script |
| First-run onboarding | ✅ | Local library setup wizard on first launch |
| Diagnostics | ✅ | Integration and local health checks |
| Settings migration | ✅ | Versioned settings migration with legacy crossfade promotion |
