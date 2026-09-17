import Foundation
import Observation

/// The library: the folder on disk and every server, read side by side and
/// shown as one.
///
/// There is no database. A folder of files *is* the library — the same one
/// SpotiFLAC writes into — and re-reading it takes a couple of seconds on a
/// background thread. A cache would have to be invalidated, and getting that
/// wrong shows up as an album that will not go away.
///
/// Each source keeps its own records, progress and error; the shelves are
/// those of the sources that are not hidden, merged. The same album on two
/// sources stays two albums, each labelled with where it is.
@MainActor
@Observable
final class LibraryStore {
    typealias Source = LibrarySource

    /// One source's part of the library.
    struct SourceState {
        var albums: [LibraryAlbum] = []
        var tracks: [LibraryTrack] = []
        /// Folder thumbnails, keyed by album id. Servers hand covers over
        /// already attached to their albums.
        var covers: [String: Data] = [:]
        var isScanning = false
        /// Files (folder) or albums (server) read so far, and how many there are.
        var progress: (done: Int, total: Int) = (0, 0)
        var error: String?
        /// Read at least once since launch, successfully or not.
        var hasLoaded = false
        /// Not read yet: macOS will ask for the Mac's password first, and
        /// the explanation has not been accepted.
        var needsKeychainAccess = false
        /// macOS was asked and did not hand the password over.
        var keychainDenied = false
    }

    private(set) var states: [Source: SourceState] = [:]
    /// The visible sources' records, merged. Rebuilt when a source finishes
    /// a batch or is shown or hidden — not recomputed on every read, which
    /// with a thousand albums would be a sort per frame.
    private(set) var albums: [LibraryAlbum] = []
    private(set) var tracks: [LibraryTrack] = []

    private(set) var root: URL
    private(set) var servers: [MusicServer] = []
    /// Sources left out of the shelves, Home and AutoPlay. Remembered.
    private(set) var hidden: Set<Source> = []

    /// Servers waiting on the explanation of the Keychain prompt.
    private(set) var keychainRequest: KeychainRequest?

    struct KeychainRequest: Identifiable {
        var id: String { "keychain" }
        var sources: [Source]
    }

    /// The lyrics hunt, when one is running: which track, and how far in.
    private(set) var lyricsHunt: LyricsHunt?

    struct LyricsHunt: Equatable {
        var title: String
        var done: Int
        var total: Int
        var found: Int
    }

    @ObservationIgnored private var scans: [Source: Task<Void, Never>] = [:]
    @ObservationIgnored private var pendingDownloadReload: Task<Void, Never>?
    /// The explanation was accepted this session: read, and let macOS ask.
    @ObservationIgnored private var keychainExplained = false
    @ObservationIgnored private var hunt: Task<Void, Never>?
    @ObservationIgnored private static let rootKey = "libraryRoot"
    @ObservationIgnored private static let serversKey = "musicServers"
    @ObservationIgnored private static let hiddenKey = "hiddenSources"

    init() {
        servers = Self.loadServers()
        hidden = Self.loadHidden()
        if let path = UserDefaults.standard.string(forKey: Self.rootKey) {
            root = URL(fileURLWithPath: path)
        } else {
            root = FileManager.default
                .urls(for: .musicDirectory, in: .userDomainMask)
                .first ?? FileManager.default.homeDirectoryForCurrentUser
        }
    }

    // MARK: - Sources

    /// The folder first, then the servers in the order they were added.
    var sources: [Source] {
        [.folder] + servers.map { .server($0.id) }
    }

    var visibleSources: [Source] {
        sources.filter { !hidden.contains($0) }
    }

    /// Labels are only worth their space when there is more than one place a
    /// track could be.
    var showsSourceBadges: Bool { sources.count > 1 }

    /// Any shown source still being read.
    var isScanning: Bool {
        visibleSources.contains { states[$0]?.isScanning == true }
    }

    func state(of source: Source) -> SourceState {
        states[source] ?? SourceState()
    }

    func name(of source: Source) -> String {
        switch source {
        case .folder: root.lastPathComponent
        case .server(let id): server(id)?.name ?? "Server"
        }
    }

    func symbol(of source: Source) -> String {
        switch source {
        case .folder: "folder"
        case .server(let id): server(id)?.kind.symbol ?? "server.rack"
        }
    }

    func isHidden(_ source: Source) -> Bool {
        hidden.contains(source)
    }

    func setHidden(_ source: Source, _ isHidden: Bool) {
        if isHidden {
            hidden.insert(source)
        } else {
            hidden.remove(source)
        }
        UserDefaults.standard.set(hidden.map(\.key), forKey: Self.hiddenKey)
        rebuild()

        // Hidden sources are not read at launch — a server is a request per
        // album — so one shown for the first time is read now.
        if !isHidden, states[source]?.hasLoaded != true, states[source]?.isScanning != true {
            reload(source)
        }
    }

    private static func loadHidden() -> Set<Source> {
        let keys = UserDefaults.standard.stringArray(forKey: hiddenKey) ?? []
        return Set(keys.compactMap(Source.init(key:)))
    }

    // MARK: - Shelves

    var recentlyAdded: [LibraryAlbum] {
        albums.sorted { $0.addedAt > $1.addedAt }
    }

    var artists: [LibraryArtist] {
        Dictionary(grouping: albums, by: \.artist)
            .map { LibraryArtist(name: $0.key, albums: $0.value.sorted { $0.title < $1.title }) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var songs: [LibraryTrack] {
        tracks.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// Every visible track the way the records run: by artist, then album,
    /// then the album's own order. What "Play All" plays.
    var inOrder: [LibraryTrack] {
        albums.sorted {
            switch $0.artist.localizedStandardCompare($1.artist) {
            case .orderedAscending: true
            case .orderedDescending: false
            case .orderedSame: $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
        }
        .flatMap(\.tracks)
    }

    private func rebuild() {
        let visible = visibleSources
        albums = visible.flatMap { states[$0]?.albums ?? [] }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        tracks = visible.flatMap { states[$0]?.tracks ?? [] }
    }

    // MARK: - Lyrics

    /// Go and find lyrics for tracks that have none.
    ///
    /// One at a time on purpose. These are public endpoints doing this for
    /// free; firing forty parallel requests at them to fill a shelf a second
    /// faster is how an app gets blocked for everyone.
    func findLyrics(for tracks: [LibraryTrack]) {
        let missing = tracks.filter { !$0.hasLyrics }
        guard !missing.isEmpty, hunt == nil else { return }

        hunt = Task { [weak self] in
            var found = 0
            for (index, track) in missing.enumerated() {
                guard let self, !Task.isCancelled else { return }
                lyricsHunt = LyricsHunt(
                    title: track.title,
                    done: index,
                    total: missing.count,
                    found: found
                )
                let result = await LyricsSidecar.fetch(
                    title: track.title,
                    artist: track.artist,
                    album: track.album,
                    duration: track.duration ?? 0,
                    for: track.url
                )
                if case .success = result {
                    found += 1
                    self.markHasLyrics(track.url)
                }
            }
            self?.lyricsHunt = nil
            self?.hunt = nil
        }
    }

    func cancelLyricsHunt() {
        hunt?.cancel()
        hunt = nil
        lyricsHunt = nil
    }

    private func markHasLyrics(_ url: URL) {
        for (source, var state) in states {
            guard let index = state.tracks.firstIndex(where: { $0.id == url }) else { continue }
            state.tracks[index].hasLyrics = true
            state.albums = state.albums.map { album in
                var album = album
                if let position = album.tracks.firstIndex(where: { $0.id == url }) {
                    album.tracks[position].hasLyrics = true
                }
                return album
            }
            states[source] = state
            rebuild()
            return
        }
    }

    // MARK: - Root

    func setRoot(_ url: URL) {
        root = url
        UserDefaults.standard.set(url.path, forKey: Self.rootKey)
        reload(.folder)
    }

    func rescanIfNeeded() {
        guard states.isEmpty else { return }
        reload()
    }

    // MARK: - Servers

    private static func loadServers() -> [MusicServer] {
        guard
            let data = UserDefaults.standard.data(forKey: serversKey),
            let decoded = try? JSONDecoder().decode([MusicServer].self, from: data)
        else { return [] }
        return decoded
    }

    private func saveServers() {
        guard let data = try? JSONEncoder().encode(servers) else { return }
        UserDefaults.standard.set(data, forKey: Self.serversKey)
    }

    func add(_ server: MusicServer, password: String) {
        Credentials.save(password, for: server.passwordKey)
        servers.append(server)
        saveServers()
        reload(.server(server.id))
    }

    func remove(_ server: MusicServer) {
        let source = Source.server(server.id)
        Credentials.remove(server.passwordKey)
        scans[source]?.cancel()
        scans[source] = nil
        states[source] = nil
        servers.removeAll { $0.id == server.id }
        saveServers()
        if hidden.remove(source) != nil {
            UserDefaults.standard.set(hidden.map(\.key), forKey: Self.hiddenKey)
        }
        if var request = keychainRequest {
            request.sources.removeAll { $0 == source }
            keychainRequest = request.sources.isEmpty ? nil : request
        }
        rebuild()
    }

    func server(_ id: UUID) -> MusicServer? {
        servers.first { $0.id == id }
    }

    /// A download has landed on the music server: ask each Jellyfin to scan
    /// for it now, then read the shown servers again once the scans have had
    /// time to find it.
    ///
    /// Several downloads finishing close together cost one reload, not one
    /// each — the wait restarts with every call. The delay is a guess rather
    /// than a signal: Jellyfin does not say when a scan it was asked for has
    /// ended.
    func refreshAfterDownload() {
        pendingDownloadReload?.cancel()

        for server in servers where server.kind == .jellyfin && !isHidden(.server(server.id)) {
            let key = server.passwordKey
            Task.detached(priority: .utility) {
                // Only with a password the app already holds access to:
                // a download is no reason for a Keychain prompt.
                guard !KeychainSignature.mayAsk, case .success(let password) = Credentials.read(key) else { return }
                try? await JellyfinClient(server: server, password: password).refreshLibrary()
            }
        }

        pendingDownloadReload = Task { [weak self] in
            try? await Task.sleep(for: .seconds(45))
            guard !Task.isCancelled, let self else { return }
            for source in visibleSources {
                if case .server = source { reload(source) }
            }
        }
    }

    static func client(for server: MusicServer, password: String) -> MusicServerClient {
        switch server.kind {
        case .subsonic: SubsonicClient(server: server, password: password)
        case .jellyfin: JellyfinClient(server: server, password: password)
        }
    }

    // MARK: - Keychain permission

    /// Shown servers not read because of the Keychain: still waiting on the
    /// explanation, or refused by macOS.
    var sourcesAwaitingKeychain: [Source] {
        visibleSources.filter {
            states[$0]?.needsKeychainAccess == true || states[$0]?.keychainDenied == true
        }
    }

    private func explainKeychainAccess(for sources: [Source]) {
        var waiting = keychainRequest?.sources ?? []
        for source in sources where !waiting.contains(source) {
            waiting.append(source)
        }
        keychainRequest = waiting.isEmpty ? nil : KeychainRequest(sources: waiting)
    }

    /// The explanation again, from Home's notice.
    func reviewKeychainAccess() {
        explainKeychainAccess(for: sourcesAwaitingKeychain)
    }

    /// "Continue": read the passwords, and let macOS ask.
    func allowKeychainAccess() {
        let waiting = keychainRequest?.sources ?? sourcesAwaitingKeychain
        keychainExplained = true
        keychainRequest = nil
        for source in waiting where !hidden.contains(source) {
            reload(source)
        }
    }

    /// "Not Now": the servers stay unread, with a notice on Home.
    func postponeKeychainAccess() {
        keychainRequest = nil
    }

    // MARK: - Reading

    /// Every shown source, side by side.
    func reload() {
        for source in visibleSources {
            reload(source)
        }
    }

    /// Just the folder — after a tag edit, say, which cannot have changed
    /// anything on a server and is not worth a request per album to find out.
    func rescanFolder() {
        reload(.folder)
    }

    func reload(_ source: Source) {
        switch source {
        case .folder: scanFolder()
        case .server(let id): load(id)
        }
    }

    private func load(_ id: UUID) {
        let source = Source.server(id)
        scans[source]?.cancel()

        guard let server = server(id) else { return }

        // This copy of the app is not the one that last read the passwords,
        // so macOS will ask for the Mac's password before handing one over.
        // Say why first: a system dialog appearing unannounced at launch,
        // asking for a password, looks like exactly what it is not.
        if KeychainSignature.mayAsk, !keychainExplained {
            states[source] = SourceState(hasLoaded: true, needsKeychainAccess: true)
            rebuild()
            explainKeychainAccess(for: [source])
            return
        }

        states[source] = SourceState(isScanning: true)
        rebuild()

        // A strong capture, and harmless: the store lives as long as the app.
        let report: @Sendable (Int, Int) -> Void = { done, total in
            Task { @MainActor in self.reportProgress(done, total, from: source) }
        }
        let key = server.passwordKey

        scans[source] = Task { [weak self] in
            // Off the main thread: when macOS does ask, the read waits for
            // the answer, and the window must not wait with it.
            let credential = await Task.detached(priority: .userInitiated) {
                Credentials.read(key)
            }.value
            guard !Task.isCancelled, let self else { return }

            switch credential {
            case .failure(let failure):
                states[source] = SourceState(
                    error: failure.message,
                    hasLoaded: true,
                    keychainDenied: failure == .denied
                )
            case .success(let password):
                do {
                    let found = try await Self.client(for: server, password: password)
                        .albums(progress: report)
                    guard !Task.isCancelled else { return }
                    states[source] = SourceState(
                        albums: found,
                        tracks: found.flatMap(\.tracks),
                        progress: (found.count, found.count),
                        hasLoaded: true
                    )
                } catch {
                    guard !Task.isCancelled else { return }
                    states[source] = SourceState(error: error.localizedDescription, hasLoaded: true)
                }
            }
            rebuild()
        }
    }

    /// Late arrivals are dropped: one landing after the load finished would
    /// put a stale count back on screen.
    private func reportProgress(_ done: Int, _ total: Int, from source: Source) {
        guard var state = states[source], state.isScanning,
              done >= state.progress.done || total != state.progress.total
        else { return }
        state.progress = (done, total)
        states[source] = state
    }

    private func scanFolder() {
        scans[.folder]?.cancel()
        states[.folder] = SourceState(isScanning: true)
        rebuild()

        let root = root
        scans[.folder] = Task { [weak self] in
            let files = await LibraryScanner.audioFiles(under: root)
            guard !Task.isCancelled, let self else { return }

            var state = SourceState(isScanning: true, progress: (0, files.count))
            states[.folder] = state

            for await batch in LibraryScanner.read(files) {
                guard !Task.isCancelled else { return }
                state.tracks.append(contentsOf: batch.tracks)
                state.covers.merge(batch.covers) { current, _ in current }
                state.albums = LibraryScanner.group(state.tracks, covers: state.covers)
                state.progress = (min(state.progress.done + batch.tracks.count, files.count), files.count)
                states[.folder] = state
                rebuild()
            }

            state.isScanning = false
            state.hasLoaded = true
            states[.folder] = state
            rebuild()
        }
    }
}
