# Final port pass

- Added Discord Rich Presence using Windows named-pipe IPC.
- Added Last.fm and ListenBrainz Now Playing/scrobbling adapters with persistent retry queue.
- Added SpotiFLAC web-server search/download integration and local CLI TUI bridge.
- Added Google Cast V2 sender, mDNS discovery and temporary authenticated local HTTP media serving.
- Added dynamic artwork palette and Canvas/video playback.
- Added playlist detail editing, reorder controls and Save Queue as Playlist.
- Added system tray controls and user-level audio file associations.
- Added Windows publish/test/build scripts.
- Updated porting documentation with remaining platform-specific limitations.


## 0.8.0 final release candidate
- Added persisted per-source visibility matching the macOS Home/library behavior.
- Added drag & drop playback, transport time labels, daily listening recap and active offline download progress.
- Added server edit flow, theme dictionaries and dynamic ThemeResource usage.
- Added Windows CI, release preflight and corrected installer versioning.
- AirPlay is intentionally not included.
