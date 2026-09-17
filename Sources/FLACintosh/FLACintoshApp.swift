import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct FLACintoshApp: App {
    /// First, before anything below reads a preference: properties are set
    /// up in the order they are written.
    private let importedSettings = SettingsMigration.importDevelopmentSettings()

    @State private var model = PlaybackModel()
    @State private var library = LibraryStore()
    @State private var spotiflac = SpotiFLACBridge()
    @State private var spotiflacServer = SpotiFLACServer()
    @State private var route = AppRoute()
    /// Control Center, the menu bar and the media keys.
    @State private var nowPlaying = SystemNowPlaying()

    init() {
        // Launched by `swift run` there is no bundle, so AppKit starts the
        // process as an accessory: no Dock icon, no window focus. Saying so
        // explicitly is what makes it behave like an app during development.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup(id: AppRoute.mainWindow) {
            RootView(model: model, library: library, spotiflac: spotiflac, spotiflacServer: spotiflacServer, route: route)
                .frame(minWidth: 940, minHeight: 620)
                .onAppear {
                    NSApp.activate(ignoringOtherApps: true)
                    library.rescanIfNeeded()
                    // AutoPlay has to come from somewhere, and the player has
                    // no idea what exists beyond the queue it was handed.
                    model.moreToPlay = { library.songs.shuffled() }
                    // A download finishing on the server is new music the
                    // library cannot see until it looks again.
                    spotiflacServer.onDownloadFinished = { library.refreshAfterDownload() }
                    nowPlaying.attach(to: model)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open File…") { openFile() }
                    .keyboardShortcut("o")
                Button("Choose Library Folder…") { chooseFolder() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Divider()
                Button("Rescan Library") { library.reload() }
                    .keyboardShortcut("r")
            }
        }

        // ⌘, — the standard home for a preference, and the cache is the one
        // setting that can quietly fill a disk.
        Settings {
            SettingsView()
        }
    }

    private func openFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio]
        if panel.runModal() == .OK, let url = panel.url {
            model.openStandalone(url)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = library.root
        panel.prompt = "Use as Library"
        if panel.runModal() == .OK, let url = panel.url {
            library.setRoot(url)
        }
    }
}

struct RootView: View {
    @Bindable var model: PlaybackModel
    @Bindable var library: LibraryStore
    @Bindable var spotiflac: SpotiFLACBridge
    @Bindable var spotiflacServer: SpotiFLACServer
    @Bindable var route: AppRoute

    @State private var section: LibrarySection = .home
    /// What is pushed over the section: an album, an artist, a download
    /// result. Explicit so the sidebar can clear it.
    @State private var path = NavigationPath()
    @State private var search = ""
    @State private var addingServer = false

    /// Held on the route rather than in `@State`: the transport bar lives in
    /// a `safeAreaInset` outside this view's body and raises it from there.
    private var showingNowPlaying: Bool { route.showingNowPlaying }

    var body: some View {
        // Siblings in a ZStack rather than an `.overlay` on the split view.
        // As an overlay the lyrics screen was laid out against the split
        // view's own geometry and ended up parked off the bottom edge:
        // invisible, but still applying its dark colour scheme to the window.
        ZStack {
            libraryScreen

            if showingNowPlaying {
                NowPlayingView(
                    model: model,
                    onClose: { showNowPlaying(false) },
                    onShowArtist: playingArtist.map { artist in { open(artist) } },
                    onShowAlbum: playingAlbum.map { album in { open(album) } }
                )
                    .transition(.move(edge: .bottom))
                    .zIndex(2)
            }
        }
        // For the source labels, which appear on tiles, rows and Now Playing
        // alike and would otherwise need the store threaded through each.
        .environment(library)
        .task {
            // `swift run FLACintosh /path/to/track.flac` — during development the
            // alternative is clicking through an open panel on every rebuild.
            //
            // It plays the file and stays on the library. It used to open the
            // lyrics screen too, and that turned out to be a way to lose the
            // window entirely: the lyrics screen hides the window toolbar,
            // and hiding a toolbar while AppKit is still building the window
            // leaves it created but never shown — the app runs, plays, and
            // displays nothing. Triggered by hand, a moment later, the same
            // code is fine.
            // Only a real file: an app opened from Finder can be handed
            // arguments of its own, and those are not tracks.
            guard let path = CommandLine.arguments.dropFirst().first,
                  FileManager.default.fileExists(atPath: path)
            else { return }

            // Not until the window is actually on screen. `AudioPlayer.play`
            // opens the decoder and starts the audio engine synchronously,
            // and doing that during the window's first layout leaves it
            // created but never shown.
            // A plain wait, and deliberately not a check for the window
            // being ready: reading `NSApp.windows` during the first
            // presentation is itself enough to stop the window ever being
            // shown. Two seconds is generous because this path only exists
            // for `swift run FLACintosh <file>` during development.
            try? await Task.sleep(for: .seconds(2))
            model.openStandalone(URL(fileURLWithPath: path))
        }
        .sheet(isPresented: $addingServer) {
            ServerSetup(library: library) { addingServer = false }
        }
        // Before macOS asks for the Mac's password, the app says what for.
        .sheet(item: Binding(
            get: { library.keychainRequest },
            set: { if $0 == nil { library.postponeKeychainAccess() } }
        )) { request in
            KeychainAccessSheet(library: library, request: request)
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            _ = providers.first?.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in model.openStandalone(url) }
            }
            return true
        }
    }

    private var libraryScreen: some View {
        NavigationSplitView {
            Sidebar(
                // Every click in the sidebar goes back to the top of its
                // section — the same one included. Without this an open
                // album stayed on screen, and the sidebar looked broken.
                selection: Binding(
                    get: { section },
                    set: { new in
                        section = new
                        path = NavigationPath()
                    }
                ),
                library: library,
                onChooseFolder: chooseFolder,
                onAddServer: { addingServer = true }
            )
        } detail: {
            NavigationStack(path: $path) {
                withTransport(content)
                    .navigationDestination(for: LibraryAlbum.self) { album in
                        withTransport(AlbumDetail(album: album, model: model, library: library))
                    }
                    .navigationDestination(for: LibraryArtist.self) { artist in
                        withTransport(ArtistDetail(artist: artist, model: model))
                    }
                    // A search result on the Download shelf: its track list.
                    .navigationDestination(for: SpotiFLACServer.Item.self) { item in
                        withTransport(RemoteTracklistView(item: item, server: spotiflacServer, library: library))
                    }
            }
        }
        // Apple Music's accent, applied once at the root: buttons, sliders,
        // links. Not the sidebar highlight — AppKit draws that from the
        // *system* accent and no tint reaches it, so `Sidebar` paints its own.
        .tint(Palette.red)
        // On the Download shelf the same field searches the catalogue.
        .searchable(text: $search, prompt: section == .download ? "Search Spotify" : "Find in \(section.title)")
        // The lyrics screen is the whole window, toolbar included. Left
        // visible, the search field floats over the words — it belongs to
        // the split view underneath and draws above anything stacked on it.
        .toolbar(showingNowPlaying ? .hidden : .visible, for: .windowToolbar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                // The same as ⌘R, for when files or a server have changed:
                // there is no watcher, so the library only knows what it read.
                Button {
                    library.reload()
                } label: {
                    if library.isScanning {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Reload Library", systemImage: "arrow.clockwise")
                    }
                }
                .help("Reload the library from the folder and every server (⌘R)")
                .disabled(library.isScanning)
            }
        }

    }

    /// One screen of the stack, with the transport bar floating over it.
    ///
    /// Floating the way Apple Music's does — the grid scrolls under it rather
    /// than stopping above it — and on the detail column only, so it leaves
    /// the sidebar's bottom rows alone. `contentMargins` keeps the last tile
    /// out from behind it: the scroll view keeps its full height and simply
    /// will not park content in the bottom 88 points.
    ///
    /// On every screen rather than once over the NavigationStack. Hung on the
    /// stack, the bar vanished as soon as an album or artist was opened:
    /// macOS hosts a pushed screen in a view of its own, drawn above the
    /// stack's overlays.
    private func withTransport(_ screen: some View) -> some View {
        screen
            .contentMargins(.bottom, 88, for: .scrollContent)
            .overlay(alignment: .bottom) {
                MiniPlayer(model: model) { showNowPlaying(true) }
            }
    }

    // MARK: - From Now Playing to the library

    /// The record playing, as the library knows it: same title and album
    /// artist, preferring the copy on the source it is playing from.
    private var playingAlbum: LibraryAlbum? {
        guard let track = model.currentTrack else { return nil }
        let candidates = library.albums.filter {
            $0.title == track.album && ($0.artist == track.albumArtist || $0.artist == track.artist)
        }
        return candidates.first { $0.source == track.source } ?? candidates.first
    }

    private var playingArtist: LibraryArtist? {
        guard let track = model.currentTrack else { return nil }
        return library.artists.first { $0.name == track.albumArtist }
            ?? library.artists.first { $0.name == track.artist }
    }

    /// Lowers Now Playing and opens a page on the shelf underneath.
    private func open(_ value: some Hashable) {
        showNowPlaying(false)
        path.append(value)
    }

    private func showNowPlaying(_ shown: Bool) {
        // Always inside an animation: a `.transition` flipped without one
        // leaves the view stranded wherever the transition starts.
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
            route.showingNowPlaying = shown
        }
    }

    @ViewBuilder
    private var content: some View {
        switch section {
        case .home:
            // Before the empty case: Home is where hidden sources are shown
            // again, so it has to stay reachable when nothing is visible.
            HomeView(library: library, model: model, section: $section, search: search)
        case .download:
            // Not a shelf: it is there whether or not the library is empty,
            // and it is the answer to an empty one.
            DownloadView(server: spotiflacServer, local: spotiflac, library: library, query: search)
        case _ where library.albums.isEmpty && !library.isScanning:
            empty
        // Each section sorts and lays itself out, remembering how it was left.
        case .recentlyAdded:
            AlbumsSection(
                albums: filtered(library.albums),
                model: model,
                library: library,
                key: "recentlyAdded",
                defaultSort: .added
            )
            .id(section)
            .navigationTitle(section.title)
        case .albums:
            AlbumsSection(
                albums: filtered(library.albums),
                model: model,
                library: library,
                key: "albums",
                defaultSort: .title
            )
            .id(section)
            .navigationTitle(section.title)
        case .artists:
            ArtistsSection(artists: filteredArtists, model: model)
                .navigationTitle(section.title)
        case .songs:
            SongsSection(songs: filteredSongs, model: model, library: library)
                .navigationTitle(section.title)
        }
    }

    private var empty: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note.list")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)
            Text(emptyTitle)
                .font(.system(size: 15, weight: .medium))
            Text(emptyDetail)
                .font(.system(size: 12))
                .foregroundStyle(sourceErrors.isEmpty ? .secondary : Color.red)
                .multilineTextAlignment(.center)
            HStack(spacing: 10) {
                Button("Choose Folder…", action: chooseFolder)
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.red)
                if !library.hidden.isEmpty {
                    Button("Show All Sources") {
                        for source in library.sources {
                            library.setHidden(source, false)
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// "Server: what went wrong", for each shown source that failed.
    private var sourceErrors: [String] {
        library.visibleSources.compactMap { source in
            library.state(of: source).error.map { "\(library.name(of: source)): \($0)" }
        }
    }

    private var emptyTitle: String {
        if library.visibleSources.isEmpty { return "Every source is hidden" }
        return sourceErrors.isEmpty ? "Nothing in your library" : "Could not read your sources"
    }

    private var emptyDetail: String {
        if library.visibleSources.isEmpty { return "Show a source again from Home or the sidebar." }
        return sourceErrors.isEmpty
            ? "Point the library at a folder of audio files, or add a server."
            : sourceErrors.joined(separator: "\n")
    }

    // MARK: - Search

    private func filtered(_ albums: [LibraryAlbum]) -> [LibraryAlbum] {
        guard !search.isEmpty else { return albums }
        return albums.filter {
            $0.title.localizedCaseInsensitiveContains(search)
                || $0.artist.localizedCaseInsensitiveContains(search)
        }
    }

    private var filteredArtists: [LibraryArtist] {
        guard !search.isEmpty else { return library.artists }
        return library.artists.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    private var filteredSongs: [LibraryTrack] {
        guard !search.isEmpty else { return library.songs }
        return library.songs.filter {
            $0.title.localizedCaseInsensitiveContains(search)
                || $0.artist.localizedCaseInsensitiveContains(search)
                || $0.album.localizedCaseInsensitiveContains(search)
        }
    }

    // MARK: - Actions

    private func play(_ album: LibraryAlbum) {
        model.play(album.tracks, startingAt: 0)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.directoryURL = library.root
        panel.prompt = "Use as Library"
        if panel.runModal() == .OK, let url = panel.url {
            library.setRoot(url)
        }
    }
}
