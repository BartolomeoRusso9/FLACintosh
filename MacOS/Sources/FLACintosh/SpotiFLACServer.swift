import Foundation
import Observation

/// SpotiFLAC running as a server (`spotiflac --web`), for finding music and
/// downloading it into the library.
///
/// Everything goes through the server's own web API — the same one its
/// browser page uses — so what this app downloads is exactly what the page
/// would: same services, quality, lyrics and folder layout, read from the
/// settings saved on the server rather than duplicated here.
///
/// Opening a result and downloading it both start the same way, and the web
/// API only offers the steps one at a time:
///
/// 1. `fetch_metadata` with the item's link. The server resolves it and
///    pushes, over its WebSocket, a header (`app_set_metadata`) and then the
///    track list (`showTracklist`); the HTTP call itself returns before
///    either exists.
/// 2. To download: `load_settings`, for the download configuration.
/// 3. `download_tracks` with the chosen indices of that list. The batch is
///    queued on the server with the tracks themselves, so it survives a
///    restart there; its end is pushed as `app_download_finished`.
///
/// Step 1 replaces the server's one working track list. In single-token mode
/// there is only one, shared with anyone using the web page at the same
/// moment — so every step 1 here waits for the one before it, and a download
/// is submitted before anything else may load another list.
@MainActor
@Observable
final class SpotiFLACServer {
    enum Connection: Equatable {
        /// No address or token saved.
        case unconfigured
        case connecting
        case connected
        case failed(String)
    }

    /// One thing a search found.
    struct Item: Identifiable, Hashable, Sendable {
        enum Kind: String, Sendable {
            case track, album, playlist, artist

            var title: String {
                switch self {
                case .track: "Song"
                case .album: "Album"
                case .playlist: "Playlist"
                case .artist: "Artist"
                }
            }
        }

        var id: String { "\(kind.rawValue):\(link)" }
        let kind: Kind
        let title: String
        /// Artist for a track or album; owner or blank for a playlist.
        let subtitle: String
        let album: String
        let cover: URL?
        /// The link SpotiFLAC resolves: a Spotify URL.
        let link: String
        let year: String?
        let duration: TimeInterval?
    }

    struct Results: Equatable {
        var tracks: [Item] = []
        var albums: [Item] = []
        var playlists: [Item] = []
        var artists: [Item] = []

        var isEmpty: Bool { tracks.isEmpty && albums.isEmpty && playlists.isEmpty && artists.isEmpty }
    }

    /// What a link resolves to: the header the server sends, and its tracks.
    struct Tracklist: Equatable, Sendable {
        struct Track: Identifiable, Equatable, Hashable, Sendable {
            /// The position in the server's list — what a download names.
            let index: Int
            var id: Int { index }
            let title: String
            let artist: String
            let album: String
            /// The track's album, as a link that can be opened in turn.
            let albumLink: String?
            let cover: URL?
            let duration: TimeInterval?
            let explicit: Bool
            let releaseDate: String?
        }

        let link: String
        var title: String
        var artist: String
        var cover: URL?
        var releaseDate: String?
        var description: String?
        var owner: String?
        var followers: Int?
        var listeners: Int?
        var tracks: [Track]
    }

    struct Download: Identifiable, Equatable {
        enum State: Equatable {
            case waiting
            /// Asking the server for the track list.
            case preparing
            /// Queued on the server; the last progress line it sent, if any.
            case downloading(String?)
            case finished(tracks: Int)
            case failed(String)
            /// The connection dropped while the server was downloading: the
            /// batch is still running there, but its end can no longer be
            /// seen from here.
            case unknown

            var isActive: Bool {
                switch self {
                case .waiting, .preparing, .downloading: true
                default: false
                }
            }
        }

        let id = UUID()
        let item: Item
        /// Positions in the item's track list; nil for all of it.
        let indices: [Int]?
        var state: State = .waiting
    }

    private(set) var connection: Connection = .unconfigured
    private(set) var results = Results()
    private(set) var isSearching = false
    private(set) var searchError: String?
    private(set) var downloads: [Download] = []

    /// Called on the main actor when a batch has finished on the server, so
    /// the library can go and look for it.
    @ObservationIgnored var onDownloadFinished: (() -> Void)?

    private(set) var address: URL?
    @ObservationIgnored private var token: String?

    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var tracklistWaiter: CheckedContinuation<Tracklist, Error>?
    @ObservationIgnored private var tracklistLink: String?
    @ObservationIgnored private var pendingHeader: [String: Any] = [:]
    @ObservationIgnored private var finishWaiter: CheckedContinuation<Bool?, Never>?
    /// The last step that touched the server's working list; the next one
    /// waits for it.
    @ObservationIgnored private var listLock: Task<Void, Never>?
    /// Which link the server's working list holds right now, and its length.
    @ObservationIgnored private var loaded: (link: String, count: Int)?
    /// Lists already opened, so going back and forth does not ask again.
    @ObservationIgnored private var tracklistCache: [String: Tracklist] = [:]

    private static let addressKey = "spotiflacAddress"
    nonisolated private static let tokenKey = "spotiflac-token"
    private static let cookieName = "spotiflac_web_token"

    /// Settings the web page saves for its own look, not for downloading.
    private static let pageOnlySettings = ["accent", "font", "theme", "preview_volume"]

    init() {
        address = UserDefaults.standard.string(forKey: Self.addressKey).flatMap(URL.init(string:))
    }

    var isConfigured: Bool { address != nil }

    // MARK: - Setup

    /// Saves where the server is and its token, then connects.
    func configure(address text: String, token newToken: String) async {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.contains("://") { trimmed = "http://" + trimmed }
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let url = URL(string: trimmed), url.host != nil else {
            connection = .failed("That is not a server address")
            return
        }

        address = url
        UserDefaults.standard.set(url.absoluteString, forKey: Self.addressKey)

        let cleanToken = newToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanToken.isEmpty {
            token = cleanToken
            await Task.detached { Credentials.save(cleanToken, for: Self.tokenKey) }.value
        }
        disconnect()
        connection = .unconfigured
        await connect()
    }

    func forget() {
        disconnect()
        address = nil
        token = nil
        UserDefaults.standard.removeObject(forKey: Self.addressKey)
        Credentials.remove(Self.tokenKey)
        results = Results()
        tracklistCache = [:]
        connection = .unconfigured
    }

    /// Checks the server answers to the token, and opens the event stream.
    func connect() async {
        guard address != nil else {
            connection = .unconfigured
            return
        }
        if case .connected = connection, socket != nil { return }
        connection = .connecting

        if token == nil {
            // Off the main thread: when macOS asks for the Mac's password
            // before handing the token over, the window must not wait.
            let read = await Task.detached { Credentials.read(Self.tokenKey) }.value
            switch read {
            case .success(let saved): token = saved
            case .failure(let failure):
                connection = .failed(failure == .missing ? "No saved token — enter it again" : failure.message)
                return
            }
        }

        do {
            _ = try await call("get_version")
            openSocket()
            connection = .connected
        } catch {
            connection = .failed(error.localizedDescription)
        }
    }

    private func disconnect() {
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }

    // MARK: - Search

    /// Searches after a short pause, so typing does not send a request per
    /// letter; a newer query cancels the one still waiting.
    func search(_ query: String) {
        searchTask?.cancel()
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            results = Results()
            searchError = nil
            isSearching = false
            return
        }

        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            isSearching = true
            defer { if !Task.isCancelled { isSearching = false } }
            do {
                let found = try await call("search_provider", ["query": text, "limit": 24])
                guard !Task.isCancelled else { return }
                results = Self.parseResults(found)
                searchError = nil
            } catch {
                guard !Task.isCancelled else { return }
                searchError = error.localizedDescription
            }
        }
    }

    // MARK: - Track lists

    /// The tracks behind a result, for showing before downloading.
    func tracklist(for item: Item) async throws -> Tracklist {
        if let cached = tracklistCache[item.link] { return cached }
        return try await withListLock {
            try await self.load(item.link)
        }
    }

    /// Loads a link into the server's working list. Only ever called holding
    /// the list lock.
    private func load(_ link: String) async throws -> Tracklist {
        if socket == nil { await connect() }
        guard socket != nil else { throw ServerError.offline }

        let list = try await withCheckedThrowingContinuation { continuation in
            tracklistWaiter = continuation
            tracklistLink = link
            pendingHeader = [:]
            Task {
                do {
                    _ = try await call("fetch_metadata", ["url": link])
                } catch {
                    resolveTrackList(.failure(error))
                }
            }
            // A list that never comes — a link the server cannot read logs an
            // error and sends nothing else.
            Task {
                try? await Task.sleep(for: .seconds(120))
                if tracklistLink == link { resolveTrackList(.failure(ServerError.timedOut)) }
            }
        }
        loaded = (link, list.tracks.count)
        tracklistCache[link] = list
        return list
    }

    /// Runs `body` once every earlier step on the server's working list has
    /// finished, so no two ever overlap.
    private func withListLock<T>(_ body: @escaping @MainActor () async throws -> T) async throws -> T {
        let previous = listLock
        let task = Task { @MainActor () async throws -> T in
            await previous?.value
            return try await body()
        }
        listLock = Task { _ = try? await task.value }
        return try await task.value
    }

    private func resolveTrackList(_ result: Result<Tracklist, Error>) {
        guard let waiter = tracklistWaiter else { return }
        tracklistWaiter = nil
        tracklistLink = nil
        waiter.resume(with: result)
    }

    // MARK: - Downloads

    /// Downloads a result: all of it, or the tracks at `indices` of its list.
    func download(_ item: Item, indices: [Int]? = nil) {
        guard indices != [] else { return }
        if indices == nil, isDownloading(item) { return }
        downloads.insert(Download(item: item, indices: indices), at: 0)
        runQueue()
    }

    func isDownloading(_ item: Item) -> Bool {
        downloads.contains { $0.item.link == item.link && $0.state.isActive }
    }

    func state(of item: Item) -> Download.State? {
        downloads.first { $0.item.link == item.link }?.state
    }

    func clearFinished() {
        downloads.removeAll { !$0.state.isActive }
    }

    private func runQueue() {
        guard worker == nil else { return }
        worker = Task {
            // Oldest first: the list is shown newest first.
            while let next = downloads.last(where: { $0.state == .waiting }) {
                await run(next.id)
            }
            worker = nil
        }
    }

    private func run(_ id: UUID) async {
        guard let download = downloads.first(where: { $0.id == id }) else { return }
        set(id, .preparing)

        do {
            // Loading the list and submitting the batch hold the lock
            // together: in between, anything else loading a list would make
            // the indices point at someone else's tracks.
            let count = try await withListLock { () async throws -> Int in
                let length: Int
                if let loaded = self.loaded, loaded.link == download.item.link {
                    length = loaded.count
                } else {
                    length = try await self.load(download.item.link).tracks.count
                }
                guard length > 0 else { throw ServerError.nothingFound }

                let indices = (download.indices ?? Array(0 ..< length)).filter { $0 >= 0 && $0 < length }
                guard !indices.isEmpty else { throw ServerError.nothingFound }

                var config = try await self.call("load_settings") as? [String: Any] ?? [:]
                for key in Self.pageOnlySettings { config.removeValue(forKey: key) }

                self.set(id, .downloading(nil))
                self.armFinish()
                _ = try await self.call("download_tracks", ["selected_indices": indices, "config": config])
                return indices.count
            }

            switch await waitForFinish() {
            case true?:
                set(id, .finished(tracks: count))
                onDownloadFinished?()
            case false?:
                set(id, .failed("SpotiFLAC could not download every track — its log says which"))
                // Some tracks may still have arrived.
                onDownloadFinished?()
            case nil:
                set(id, .unknown)
            }
        } catch {
            cancelFinish()
            set(id, .failed(error.localizedDescription))
        }
    }

    private func set(_ id: UUID, _ state: Download.State) {
        guard let index = downloads.firstIndex(where: { $0.id == id }) else { return }
        downloads[index].state = state
    }

    // The end of a batch can arrive before anything is waiting for it — a
    // one-track download can finish while `download_tracks` is still
    // answering — so the outcome is caught from the moment the batch is sent
    // and kept until it is asked for.
    @ObservationIgnored private var finishArmed = false
    @ObservationIgnored private var finishOutcome: Bool??

    private func armFinish() {
        finishArmed = true
        finishOutcome = nil
    }

    private func cancelFinish() {
        finishArmed = false
        finishOutcome = nil
    }

    private func waitForFinish() async -> Bool? {
        if let outcome = finishOutcome {
            cancelFinish()
            return outcome
        }
        return await withCheckedContinuation { continuation in
            finishWaiter = continuation
        }
    }

    private func resolveFinish(_ outcome: Bool?) {
        if let waiter = finishWaiter {
            finishWaiter = nil
            cancelFinish()
            waiter.resume(returning: outcome)
        } else if finishArmed {
            finishOutcome = .some(outcome)
        }
    }

    private func updateProgress(_ label: String) {
        guard let index = downloads.firstIndex(where: {
            if case .downloading = $0.state { return true }
            return false
        }) else { return }
        downloads[index].state = .downloading(label.isEmpty ? nil : label)
    }

    // MARK: - Event stream

    private func openSocket() {
        guard let address, let token,
              var components = URLComponents(url: address, resolvingAgainstBaseURL: false)
        else { return }
        disconnect()

        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.path = (components.path.hasSuffix("/") ? components.path : components.path + "/") + "ws"
        components.queryItems = [URLQueryItem(name: "token", value: token)]
        guard let url = components.url else { return }

        let task = URLSession.shared.webSocketTask(with: url)
        // A long discography arrives as one message.
        task.maximumMessageSize = 64 * 1024 * 1024
        socket = task
        task.resume()
        receive(on: task)
    }

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, task === self.socket else { return }
                switch result {
                case .success(let message):
                    if case .string(let text) = message { self.handle(text) }
                    self.receive(on: task)
                case .failure:
                    self.socketDropped()
                }
            }
        }
    }

    private func socketDropped() {
        socket = nil
        loaded = nil
        connection = .failed("Lost the connection to SpotiFLAC")
        resolveTrackList(.failure(ServerError.offline))
        resolveFinish(nil)
    }

    private func handle(_ text: String) {
        guard
            let data = text.data(using: .utf8),
            let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let name = message["fn"] as? String
        else { return }
        let args = message["args"] as? [Any] ?? []

        switch name {
        case "app_set_metadata":
            pendingHeader = args.first as? [String: Any] ?? [:]
        case "showTracklist":
            guard let link = tracklistLink else {
                // Someone on the server's web page loaded a list of their
                // own: the working list is no longer the one noted here.
                loaded = nil
                return
            }
            let rows = args.first as? [[String: Any]] ?? []
            resolveTrackList(.success(Self.parseTracklist(link: link, header: pendingHeader, rows: rows)))
        case "app_download_finished":
            resolveFinish(args.first as? Bool ?? false)
        case "app_set_progress":
            updateProgress(args.first as? String ?? "")
        case "app_log":
            // The one sign a link could not be read: nothing else is pushed.
            if tracklistWaiter != nil,
               (args.dropFirst().first as? String)?.hasPrefix("error") == true,
               let line = args.first as? String {
                resolveTrackList(.failure(ServerError.server(line)))
            }
        default:
            break
        }
    }

    // MARK: - HTTP

    enum ServerError: LocalizedError {
        case token
        case offline
        case timedOut
        case nothingFound
        case server(String)

        var errorDescription: String? {
            switch self {
            case .token: "SpotiFLAC refused the token"
            case .offline: "Could not reach SpotiFLAC"
            case .timedOut: "SpotiFLAC did not answer in time"
            case .nothingFound: "SpotiFLAC found no tracks at that link"
            case .server(let detail): detail
            }
        }
    }

    /// One method of the web API: `POST /api/<method>` with its arguments as
    /// a JSON object, answered with `{"result": …}`.
    private func call(_ method: String, _ arguments: [String: Any]? = nil) async throws -> Any? {
        guard let address, let token else { throw ServerError.offline }

        var request = URLRequest(url: address.appendingPathComponent("api/\(method)"))
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // The token as the cookie the web page would carry. The session's
        // own cookie store is kept out of it, so it cannot swap in a stale one.
        request.httpShouldHandleCookies = false
        request.setValue("\(Self.cookieName)=\(token)", forHTTPHeaderField: "Cookie")
        request.httpBody = try JSONSerialization.data(withJSONObject: arguments ?? [:])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ServerError.offline
        }
        guard let http = response as? HTTPURLResponse else { throw ServerError.offline }
        guard http.statusCode != 401 else { throw ServerError.token }

        let body = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? [String: Any]
        guard http.statusCode == 200 else {
            throw ServerError.server(body?["error"] as? String ?? "SpotiFLAC answered \(http.statusCode)")
        }
        return body?["result"]
    }

    // MARK: - Parsing

    private static func parseResults(_ value: Any?) -> Results {
        let sections = value as? [String: Any] ?? [:]
        func items(_ key: String, _ kind: Item.Kind) -> [Item] {
            (sections[key] as? [[String: Any]] ?? []).compactMap { item(from: $0, kind: kind) }
        }
        return Results(
            tracks: items("tracks", .track),
            albums: items("albums", .album),
            playlists: items("playlists", .playlist),
            artists: items("artists", .artist)
        )
    }

    private static func item(from row: [String: Any], kind: Item.Kind) -> Item? {
        guard let link = text(row["external_url"]), !link.isEmpty else { return nil }
        let date = text(row["release_date"]) ?? ""
        return Item(
            kind: kind,
            title: text(row["name"]) ?? text(row["title"]) ?? "Untitled",
            subtitle: text(row["artist"]) ?? text(row["artists"]) ?? text(row["owner"]) ?? "",
            album: text(row["album"]) ?? "",
            cover: (text(row["cover"]) ?? text(row["images"])).flatMap(URL.init(string:)),
            link: link,
            year: date.count >= 4 ? String(date.prefix(4)) : nil,
            duration: number(row["duration_ms"]).flatMap { $0 > 0 ? $0 / 1000 : nil }
        )
    }

    private static func parseTracklist(link: String, header: [String: Any], rows: [[String: Any]]) -> Tracklist {
        let tracks = rows.enumerated().map { position, row in
            Tracklist.Track(
                index: (row["index"] as? Int) ?? position,
                title: text(row["title"]) ?? "Untitled",
                artist: text(row["artist"]) ?? "",
                album: text(row["album"]) ?? "",
                albumLink: text(row["album_url"]),
                cover: text(row["cover"]).flatMap(URL.init(string:)),
                duration: number(row["duration_ms"]).flatMap { $0 > 0 ? $0 / 1000 : nil },
                explicit: row["explicit"] as? Bool ?? false,
                releaseDate: text(row["release_date"])
            )
        }
        return Tracklist(
            link: link,
            title: text(header["title"]) ?? tracks.first?.album ?? "",
            artist: text(header["artist"]) ?? "",
            cover: text(header["cover"]).flatMap(URL.init(string:)) ?? tracks.first?.cover,
            releaseDate: text(header["release_date"]),
            description: text(header["description"]),
            owner: text(header["owner"]),
            followers: number(header["followers"]).map { Int($0) },
            listeners: number(header["artist_listeners"]).map { Int($0) },
            tracks: tracks
        )
    }

    /// A string field, or nil when it is missing or not a string — the
    /// server sends lists and blanks for some fields depending on provider.
    private static func text(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return string
    }

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let double as Double: double
        case let int as Int: Double(int)
        case let string as String: Double(string)
        default: nil
        }
    }
}
