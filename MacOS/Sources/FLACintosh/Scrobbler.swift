import CryptoKit
import Foundation
import Observation

/// Scrobbling: telling Last.fm and ListenBrainz what you listened to.
///
/// A scrobble follows the same rule as the Recap — half the song or four
/// minutes, and nothing under thirty seconds — because it is the same rule
/// both services use, and `ListeningHistory` already applies it. What it
/// records, this sends.
///
/// Anything that fails to send is kept and tried again: the services are
/// free, and a flat network should not lose an evening of listening.
@MainActor
@Observable
final class Scrobbler {
    struct Pending: Codable, Hashable, Sendable {
        var service: String
        var artist: String
        var track: String
        var album: String
        var duration: Int?
        /// Unix time the song started.
        var timestamp: Int
    }

    enum Status: Equatable {
        case off
        case connected(String)
        case needsSetup(String)
        case failed(String)

        var text: String {
            switch self {
            case .off: "Off"
            case .connected(let user): "Connected as \(user)"
            case .needsSetup(let message), .failed(let message): message
            }
        }

        var isConnected: Bool {
            if case .connected = self { return true }
            return false
        }
    }

    // MARK: Settings

    var listenBrainzOn = UserDefaults.standard.bool(forKey: "listenBrainzEnabled") {
        didSet {
            UserDefaults.standard.set(listenBrainzOn, forKey: "listenBrainzEnabled")
            Task { await loadSecrets(); await refreshListenBrainz() }
        }
    }

    /// Held in memory only while the app runs; the keychain has the copy.
    var listenBrainzToken = "" {
        didSet {
            guard listenBrainzToken != oldValue, !loadingSecrets else { return }
            let token = listenBrainzToken.trimmingCharacters(in: .whitespacesAndNewlines)
            if token.isEmpty {
                Credentials.remove(Self.listenBrainzKey)
            } else {
                Credentials.save(token, for: Self.listenBrainzKey)
            }
            Task { await refreshListenBrainz() }
        }
    }

    var lastFMOn = UserDefaults.standard.bool(forKey: "lastFMEnabled") {
        didSet {
            UserDefaults.standard.set(lastFMOn, forKey: "lastFMEnabled")
            Task {
                await loadSecrets()
                lastFMStatus = lastFMOn ? storedLastFMStatus : .off
            }
        }
    }

    var lastFMKey = UserDefaults.standard.string(forKey: "lastFMKey") ?? "" {
        didSet { UserDefaults.standard.set(lastFMKey.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "lastFMKey") }
    }

    var lastFMSecret = "" {
        didSet {
            guard lastFMSecret != oldValue, !loadingSecrets else { return }
            let secret = lastFMSecret.trimmingCharacters(in: .whitespacesAndNewlines)
            if secret.isEmpty {
                Credentials.remove(Self.lastFMSecretKey)
            } else {
                Credentials.save(secret, for: Self.lastFMSecretKey)
            }
        }
    }

    private(set) var listenBrainzStatus: Status = .off
    private(set) var lastFMStatus: Status = .off
    /// Waiting for the Last.fm page to be approved in the browser.
    private(set) var lastFMAuthorising = false
    private(set) var pendingCount = 0

    nonisolated static let listenBrainzKey = "listenbrainz-token"
    nonisolated static let lastFMSecretKey = "lastfm-secret"
    nonisolated static let lastFMSessionKey = "lastfm-session"

    @ObservationIgnored private var lastFMSession: String?
    @ObservationIgnored private weak var model: PlaybackModel?
    @ObservationIgnored private var pending: [Pending] = []
    @ObservationIgnored private var sending: Task<Void, Never>?
    @ObservationIgnored private var nowPlayingSent: String?
    @ObservationIgnored private var loadedSecrets = false
    @ObservationIgnored private var loadingSecrets = false

    private var storedLastFMStatus: Status {
        if lastFMSession != nil, let user = UserDefaults.standard.string(forKey: "lastFMUser") {
            return .connected(user)
        }
        return .needsSetup("Not connected")
    }

    // MARK: - Setting up

    func attach(to model: PlaybackModel, history: ListeningHistory) {
        guard self.model == nil else { return }
        self.model = model
        pending = Self.loadPending()
        pendingCount = pending.count

        history.onPlay.append { [weak self] play in
            self?.scrobble(play)
        }
        observe()

        // Only when something is switched on: reading the keychain is what
        // makes macOS ask for the Mac's password.
        guard listenBrainzOn || lastFMOn else { return }
        Task {
            await loadSecrets()
            lastFMStatus = lastFMOn ? storedLastFMStatus : .off
            await refreshListenBrainz()
            flush()
        }
    }

    private func loadSecrets() async {
        guard !loadedSecrets else { return }
        loadedSecrets = true
        let keys = [Self.listenBrainzKey, Self.lastFMSecretKey, Self.lastFMSessionKey]
        let values = await Task.detached(priority: .utility) {
            keys.map { key -> String? in
                if case .success(let value) = Credentials.read(key) { return value }
                return nil
            }
        }.value
        // Read back, not typed: not saved again.
        loadingSecrets = true
        listenBrainzToken = values[0] ?? ""
        lastFMSecret = values[1] ?? ""
        loadingSecrets = false
        lastFMSession = values[2]
    }

    /// Checks the ListenBrainz token and shows whose it is.
    func refreshListenBrainz() async {
        guard listenBrainzOn else {
            listenBrainzStatus = .off
            return
        }
        let token = listenBrainzToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            listenBrainzStatus = .needsSetup("Needs a user token")
            return
        }
        var request = URLRequest(url: URL(string: "https://api.listenbrainz.org/1/validate-token")!)
        request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            listenBrainzStatus = .failed("Could not reach ListenBrainz")
            return
        }
        if json["valid"] as? Bool == true, let user = json["user_name"] as? String {
            listenBrainzStatus = .connected(user)
            flush()
        } else {
            listenBrainzStatus = .failed(json["message"] as? String ?? "That token was refused")
        }
    }

    // MARK: - Last.fm sign-in

    /// Opens Last.fm's approval page, then waits for it to be approved.
    ///
    /// Last.fm has no device flow: a request token is approved in a browser
    /// while the app waits, and is then exchanged for a session key. The key
    /// goes in the keychain and does not expire.
    func connectLastFM() async {
        let key = lastFMKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = lastFMSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !secret.isEmpty else {
            lastFMStatus = .needsSetup("Needs an API key and shared secret")
            return
        }
        lastFMAuthorising = true
        defer { lastFMAuthorising = false }

        guard let token = await lastFMCall(["method": "auth.getToken", "api_key": key], secret: secret)?["token"] as? String else {
            lastFMStatus = .failed("Last.fm refused the API key or shared secret")
            return
        }
        if let url = URL(string: "https://www.last.fm/api/auth/?api_key=\(key)&token=\(token)") {
            openInBrowser(url)
        }
        lastFMStatus = .needsSetup("Waiting for approval in your browser…")

        // Asked every few seconds while the page is open, for two minutes.
        for _ in 0 ..< 40 {
            try? await Task.sleep(for: .seconds(3))
            guard let session = await lastFMCall(
                ["method": "auth.getSession", "api_key": key, "token": token],
                secret: secret
            )?["session"] as? [String: Any],
                let sessionKey = session["key"] as? String,
                let name = session["name"] as? String
            else { continue }
            lastFMSession = sessionKey
            Credentials.save(sessionKey, for: Self.lastFMSessionKey)
            UserDefaults.standard.set(name, forKey: "lastFMUser")
            lastFMStatus = .connected(name)
            flush()
            return
        }
        lastFMStatus = .failed("The request was not approved in time")
    }

    func disconnectLastFM() {
        lastFMSession = nil
        Credentials.remove(Self.lastFMSessionKey)
        UserDefaults.standard.removeObject(forKey: "lastFMUser")
        lastFMStatus = lastFMOn ? .needsSetup("Not connected") : .off
    }

    // MARK: - Sending

    /// "Listening now", which both services show while a song plays and
    /// neither keeps.
    private func observe() {
        guard let model else { return }
        withObservationTracking {
            _ = model.track?.title
            _ = model.track?.artist
            _ = model.isPlaying
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.sendNowPlaying()
                self?.observe()
            }
        }
    }

    private func sendNowPlaying() {
        guard let model, model.isPlaying, let track = model.track,
              !track.title.isEmpty, !track.artist.isEmpty
        else { return }
        let key = "\(track.title)|\(track.artist)"
        guard key != nowPlayingSent else { return }
        nowPlayingSent = key

        let duration = track.duration.map { Int($0.rounded()) }
        if listenBrainzOn, listenBrainzStatus.isConnected {
            Task { _ = await sendToListenBrainz(playingNow: track, duration: duration) }
        }
        if lastFMOn, lastFMStatus.isConnected {
            Task {
                _ = await lastFMSigned([
                    "method": "track.updateNowPlaying",
                    "artist": track.artist,
                    "track": track.title,
                    "album": track.album,
                    "duration": duration.map(String.init) ?? "",
                ])
            }
        }
    }

    private func scrobble(_ play: ListeningHistory.Play) {
        guard !play.artist.isEmpty, !play.title.isEmpty else { return }
        let timestamp = Int(play.date.timeIntervalSince1970)
        let duration = play.duration.map { Int($0.rounded()) }

        for (service, on) in [("listenbrainz", listenBrainzOn), ("lastfm", lastFMOn)] where on {
            pending.append(Pending(
                service: service,
                artist: play.artist,
                track: play.title,
                album: play.album,
                duration: duration,
                timestamp: timestamp
            ))
        }
        pendingCount = pending.count
        savePending()
        flush()
    }

    /// Sends everything waiting, oldest first, and keeps what will not go.
    func flush() {
        guard !pending.isEmpty, sending == nil else { return }
        sending = Task { [weak self] in
            guard let self else { return }
            let batch = pending
            var sent: Set<Pending> = []
            for item in batch {
                let ok: Bool = switch item.service {
                case "listenbrainz": listenBrainzStatus.isConnected ? await sendToListenBrainz(item) : false
                case "lastfm": lastFMStatus.isConnected ? await sendToLastFM(item) : false
                default: true
                }
                if ok { sent.insert(item) }
            }
            // Scrobbles recorded while this batch was going are kept.
            pending.removeAll { sent.contains($0) }
            pendingCount = pending.count
            savePending()
            sending = nil
            if !pending.isEmpty, !sent.isEmpty || batch.count != pending.count {
                flush()
            } else if !pending.isEmpty {
                // Later, quietly, while some are still waiting.
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(300))
                    self?.flush()
                }
            }
        }
    }

    private func sendToListenBrainz(_ item: Pending) async -> Bool {
        var info: [String: Any] = ["media_player": "FLACintosh", "submission_client": "FLACintosh"]
        if let duration = item.duration { info["duration"] = duration }
        let metadata: [String: Any] = [
            "artist_name": item.artist,
            "track_name": item.track,
            "release_name": item.album,
            "additional_info": info,
        ]
        return await postToListenBrainz([
            "listen_type": "single",
            "payload": [["listened_at": item.timestamp, "track_metadata": metadata]],
        ])
    }

    private func sendToListenBrainz(playingNow track: TrackInfo, duration: Int?) async -> Bool {
        var info: [String: Any] = ["media_player": "FLACintosh", "submission_client": "FLACintosh"]
        if let duration { info["duration"] = duration }
        let metadata: [String: Any] = [
            "artist_name": track.artist,
            "track_name": track.title,
            "release_name": track.album,
            "additional_info": info,
        ]
        return await postToListenBrainz([
            "listen_type": "playing_now",
            "payload": [["track_metadata": metadata]],
        ])
    }

    private func postToListenBrainz(_ body: [String: Any]) async -> Bool {
        let token = listenBrainzToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, let data = try? JSONSerialization.data(withJSONObject: body) else { return false }
        var request = URLRequest(url: URL(string: "https://api.listenbrainz.org/1/submit-listens")!)
        request.httpMethod = "POST"
        request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse
        else { return false }
        // A 4xx other than rate limiting will never be accepted; dropping it
        // beats trying forever.
        return (200 ..< 300).contains(http.statusCode) || (400 ..< 429).contains(http.statusCode)
    }

    private func sendToLastFM(_ item: Pending) async -> Bool {
        let answer = await lastFMSigned([
            "method": "track.scrobble",
            "artist": item.artist,
            "track": item.track,
            "album": item.album,
            "duration": item.duration.map(String.init) ?? "",
            "timestamp": String(item.timestamp),
        ])
        guard let answer else { return false }
        if let code = answer["error"] as? Int {
            // 9: the session is no longer valid and has to be connected again.
            if code == 9 {
                disconnectLastFM()
                lastFMStatus = .needsSetup("Connect Last.fm again")
                return false
            }
            // 11, 16 and 29 are temporary; anything else will not change.
            return ![11, 16, 29].contains(code)
        }
        return true
    }

    // MARK: - Last.fm plumbing

    /// A signed call carrying the session key.
    private func lastFMSigned(_ parameters: [String: String]) async -> [String: Any]? {
        let key = lastFMKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = lastFMSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let session = lastFMSession, !key.isEmpty, !secret.isEmpty else { return nil }
        var all = parameters.filter { !$0.value.isEmpty }
        all["api_key"] = key
        all["sk"] = session
        return await lastFMCall(all, secret: secret, post: true)
    }

    /// Last.fm signs a request with an MD5 of its parameters in name order
    /// followed by the shared secret. MD5 is the protocol's, not a choice.
    private func lastFMCall(_ parameters: [String: String], secret: String, post: Bool = false) async -> [String: Any]? {
        var parameters = parameters
        let signature = parameters.keys.sorted()
            .map { $0 + parameters[$0]! }
            .joined() + secret
        parameters["api_sig"] = Insecure.MD5.hash(data: Data(signature.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        parameters["format"] = "json"

        var components = URLComponents(string: "https://ws.audioscrobbler.com/2.0/")!
        let items = parameters.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request: URLRequest
        if post {
            request = URLRequest(url: components.url!)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            var body = URLComponents()
            body.queryItems = items
            // `+` is left alone by URLComponents and read as a space by
            // form decoding, which would change the signed value.
            let encoded = body.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
            request.httpBody = encoded.map { Data($0.utf8) }
        } else {
            components.queryItems = items
            request = URLRequest(url: components.url!)
        }

        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // MARK: - Waiting scrobbles

    private static var pendingURL: URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let folder = support.appendingPathComponent("FLACintosh", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("scrobble-queue.json")
    }

    private static func loadPending() -> [Pending] {
        guard let url = pendingURL, let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Pending].self, from: data)) ?? []
    }

    private func savePending() {
        guard let url = Self.pendingURL, let data = try? JSONEncoder().encode(pending) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
