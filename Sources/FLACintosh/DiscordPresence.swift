import Darwin
import Foundation
import Observation

/// "Listening to …" on your Discord profile.
///
/// Discord's desktop app takes Rich Presence over a local socket,
/// `discord-ipc-0` in the temporary folder: a handshake with an application
/// ID, then `SET_ACTIVITY` messages, each a little-endian opcode and length
/// in front of a JSON body. No Discord SDK, no network — if Discord is not
/// running there is simply nobody on the other end, and this tries again
/// later.
///
/// The application ID is what Discord shows as the name: one made at
/// discord.com/developers and called "FLACintosh" reads "Listening to
/// FLACintosh". It is pasted in Settings rather than built in.
@MainActor
@Observable
final class DiscordPresence {
    enum Status: Equatable {
        case off
        case missingID
        case waitingForDiscord
        case connected(String)
        case failed(String)

        var text: String {
            switch self {
            case .off: "Off"
            case .missingID: "Needs an application ID"
            case .waitingForDiscord: "Waiting for Discord to open…"
            case .connected(let user): "Connected as \(user)"
            case .failed(let message): message
            }
        }
    }

    var enabled = UserDefaults.standard.bool(forKey: "discordPresence") {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "discordPresence")
            restart()
        }
    }

    var applicationID = UserDefaults.standard.string(forKey: "discordApplicationID") ?? "" {
        didSet {
            let trimmed = applicationID.trimmingCharacters(in: .whitespacesAndNewlines)
            UserDefaults.standard.set(trimmed, forKey: "discordApplicationID")
            if oldValue.trimmingCharacters(in: .whitespacesAndNewlines) != trimmed { restart() }
        }
    }

    /// Covers looked up on Apple Music by artist and album: Discord can only
    /// show a picture from a public URL, and a sleeve inside a local file or
    /// on a home server is neither.
    var showArtwork = UserDefaults.standard.object(forKey: "discordArtwork") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(showArtwork, forKey: "discordArtwork")
            sentKey = nil
            schedule()
        }
    }

    private(set) var status: Status = .off

    @ObservationIgnored private weak var model: PlaybackModel?
    @ObservationIgnored private var socket: DiscordSocket?
    @ObservationIgnored private var socketToken: UUID?
    @ObservationIgnored private var retry: Task<Void, Never>?
    @ObservationIgnored private var pendingUpdate: Task<Void, Never>?
    @ObservationIgnored private var clock: Task<Void, Never>?
    @ObservationIgnored private var sentKey: String?
    @ObservationIgnored private var sentStart: Double = 0
    @ObservationIgnored private var artworkCache: [String: String] = [:]

    func attach(to model: PlaybackModel) {
        guard self.model == nil else { return }
        self.model = model
        observe()
        restart()
        // A seek moves the timestamps; checked now and then rather than on
        // every tick of the interface clock.
        clock = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                self?.checkDrift()
            }
        }
    }

    // MARK: - Connection

    private func restart() {
        retry?.cancel()
        socket?.close()
        socket = nil
        socketToken = nil
        sentKey = nil

        guard enabled else { status = .off; return }
        let id = applicationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, id.allSatisfy(\.isNumber) else { status = .missingID; return }
        connect(id)
    }

    private func connect(_ id: String) {
        // Events from a socket already replaced — the old one reporting its
        // own close after a restart — must not touch the new one.
        let token = UUID()
        socketToken = token
        let socket = DiscordSocket { [weak self] event in
            Task { @MainActor in
                guard let self, self.socketToken == token else { return }
                self.handle(event)
            }
        }
        guard socket.open(applicationID: id) else {
            status = .waitingForDiscord
            scheduleRetry()
            return
        }
        self.socket = socket
        status = .waitingForDiscord
    }

    private func handle(_ event: DiscordSocket.Event) {
        switch event {
        case .ready(let user):
            status = .connected(user)
            sentKey = nil
            schedule()
        case .closed(let message):
            socket = nil
            if let message {
                // A bad application ID is not going to fix itself on retry.
                status = .failed(message)
                if !message.lowercased().contains("client id") { scheduleRetry() }
            } else if enabled {
                status = .waitingForDiscord
                scheduleRetry()
            }
        }
    }

    private func scheduleRetry() {
        retry?.cancel()
        retry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard let self, !Task.isCancelled, self.enabled, self.socket == nil else { return }
            self.restart()
        }
    }

    // MARK: - Activity

    private func observe() {
        guard let model else { return }
        withObservationTracking {
            _ = model.track?.title
            _ = model.track?.artist
            _ = model.track?.album
            _ = model.track?.duration
            _ = model.isPlaying
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.schedule()
                self?.observe()
            }
        }
    }

    /// Coalesced: a track change touches title, artist, album and duration
    /// one after another, and Discord allows five updates in twenty seconds.
    private func schedule() {
        pendingUpdate?.cancel()
        pendingUpdate = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            await self?.send()
        }
    }

    private func checkDrift() {
        guard let model, model.isPlaying, sentKey != nil else { return }
        let start = Date.now.timeIntervalSince1970 - model.currentTime
        if abs(start - sentStart) > 3 {
            sentKey = nil
            schedule()
        }
    }

    private func send() async {
        guard let socket, case .connected = status, let model else { return }

        guard model.isPlaying, let track = model.track, !track.title.isEmpty else {
            if sentKey != "" {
                socket.setActivity(nil)
                sentKey = ""
            }
            return
        }

        let start = Date.now.timeIntervalSince1970 - model.currentTime
        let key = "\(track.title)|\(track.artist)|\(track.album)|\(Int(start / 3))|\(showArtwork)"
        guard key != sentKey else { return }
        sentKey = key
        sentStart = start

        var activity: [String: Any] = [
            // 2 is "Listening to"; status_display_type 1 puts the artist in
            // the member list line instead of the app's name.
            "type": 2,
            "status_display_type": 1,
            "details": Self.field(track.title),
        ]
        if !track.artist.isEmpty { activity["state"] = Self.field(track.artist) }

        var timestamps: [String: Any] = ["start": Int(start * 1000)]
        if let duration = track.duration, duration > 0 {
            timestamps["end"] = Int((start + duration) * 1000)
        }
        activity["timestamps"] = timestamps

        var assets: [String: Any] = [:]
        if showArtwork, let url = await artwork(artist: track.artist, album: track.album, title: track.title) {
            assets["large_image"] = url
        }
        if !track.album.isEmpty { assets["large_text"] = Self.field(track.album) }
        if !assets.isEmpty { activity["assets"] = assets }

        // Still the same song after the lookup, and still connected.
        guard sentKey == key, self.socket === socket else { return }
        socket.setActivity(activity)
    }

    /// Discord refuses strings under two characters or over 128.
    private static func field(_ text: String) -> String {
        let trimmed = String(text.prefix(128))
        return trimmed.count < 2 ? trimmed + "\u{2009}\u{2009}" : trimmed
    }

    /// The record's cover on Apple Music — only one whose artist matches.
    /// A search takes the closest thing it has, and a wrong sleeve on your
    /// profile is worse than none: the album first, then the song, which
    /// finds singles and records the catalogue files under another title.
    private func artwork(artist: String, album: String, title: String) async -> String? {
        let key = "\(artist)|\(album)|\(title)".lowercased()
        guard !artist.isEmpty else { return nil }
        if let cached = artworkCache[key] { return cached.isEmpty ? nil : cached }

        let wanted = Self.normal(artist)
        func search(_ term: String, entity: String, name: String, matching: String?) async -> String? {
            var components = URLComponents(string: "https://itunes.apple.com/search")!
            components.queryItems = [
                URLQueryItem(name: "term", value: term),
                URLQueryItem(name: "entity", value: entity),
                URLQueryItem(name: "limit", value: "10"),
            ]
            guard let url = components.url,
                  let (data, _) = try? await URLSession.shared.data(from: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]]
            else { return nil }
            let sameArtist = results.filter {
                let found = Self.normal($0["artistName"] as? String ?? "")
                return found.contains(wanted) || wanted.contains(found)
            }
            let chosen = matching.flatMap { target in
                sameArtist.first { Self.normal($0[name] as? String ?? "").hasPrefix(target) }
            } ?? (matching == nil ? sameArtist.first : nil)
            return (chosen?["artworkUrl100"] as? String)?.replacingOccurrences(of: "100x100bb", with: "512x512bb")
        }

        var found: String?
        if !album.isEmpty {
            found = await search("\(artist) \(album)", entity: "album", name: "collectionName", matching: Self.normal(album))
        }
        if found == nil, !title.isEmpty {
            found = await search("\(artist) \(title)", entity: "song", name: "trackName", matching: Self.normal(title))
        }
        artworkCache[key] = found ?? ""
        return found
    }

    /// Lowercased, accents and punctuation gone: "Awaken, My Love!" and
    /// "awaken my love" are the same record.
    private static func normal(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return String(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }
}

/// The socket itself, off the main thread.
final class DiscordSocket: @unchecked Sendable {
    enum Event {
        case ready(String)
        case closed(String?)
    }

    private let queue = DispatchQueue(label: "FLACintosh.discord")
    private var descriptor: Int32 = -1
    private let onEvent: (Event) -> Void

    init(onEvent: @escaping (Event) -> Void) {
        self.onEvent = onEvent
    }

    /// Connects and sends the handshake; false if Discord is not running.
    func open(applicationID: String) -> Bool {
        for path in Self.candidatePaths() {
            let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { continue }
            var noSigPipe: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let capacity = MemoryLayout.size(ofValue: address.sun_path)
            guard path.utf8.count < capacity else { Darwin.close(fd); continue }
            withUnsafeMutableBytes(of: &address.sun_path) { buffer in
                buffer.copyBytes(from: path.utf8)
                buffer[path.utf8.count] = 0
            }
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard connected == 0 else { Darwin.close(fd); continue }

            descriptor = fd
            write(op: 0, ["v": 1, "client_id": applicationID])
            let thread = Thread { [weak self] in self?.readLoop(fd) }
            thread.name = "FLACintosh.discord.read"
            thread.start()
            return true
        }
        return false
    }

    func setActivity(_ activity: [String: Any]?) {
        write(op: 1, [
            "cmd": "SET_ACTIVITY",
            "args": ["pid": Int(getpid()), "activity": activity.map { $0 as Any } ?? NSNull()],
            "nonce": UUID().uuidString,
        ])
    }

    func close() {
        queue.async {
            guard self.descriptor >= 0 else { return }
            shutdown(self.descriptor, SHUT_RDWR)
            Darwin.close(self.descriptor)
            self.descriptor = -1
        }
    }

    // MARK: -

    private static func candidatePaths() -> [String] {
        let environment = ProcessInfo.processInfo.environment
        var folders = ["XDG_RUNTIME_DIR", "TMPDIR", "TMP", "TEMP"].compactMap { environment[$0] }
        folders.append(NSTemporaryDirectory())
        folders.append("/tmp")
        var seen = Set<String>()
        return folders
            .map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
            .filter { seen.insert($0).inserted }
            .flatMap { folder in (0 ... 9).map { "\(folder)/discord-ipc-\($0)" } }
    }

    private func write(op: UInt32, _ json: [String: Any]) {
        guard let body = try? JSONSerialization.data(withJSONObject: json) else { return }
        var frame = Data()
        withUnsafeBytes(of: op.littleEndian) { frame.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(body.count).littleEndian) { frame.append(contentsOf: $0) }
        frame.append(body)
        queue.async {
            guard self.descriptor >= 0 else { return }
            frame.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let sent = Darwin.send(self.descriptor, buffer.baseAddress! + offset, buffer.count - offset, 0)
                    if sent <= 0 { return }
                    offset += sent
                }
            }
        }
    }

    private func readLoop(_ fd: Int32) {
        func readExactly(_ count: Int) -> Data? {
            var data = Data(count: count)
            var offset = 0
            while offset < count {
                let received = data.withUnsafeMutableBytes { Darwin.recv(fd, $0.baseAddress! + offset, count - offset, 0) }
                if received <= 0 { return nil }
                offset += received
            }
            return data
        }

        while true {
            guard let header = readExactly(8) else { break }
            let op = header.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self).littleEndian }
            let length = Int(header.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self).littleEndian })
            guard length < 1_048_576 else { break }
            let body = length == 0 ? Data() : readExactly(length)
            guard let body else { break }
            let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]

            switch op {
            case 1:
                if json["evt"] as? String == "READY" {
                    let user = ((json["data"] as? [String: Any])?["user"] as? [String: Any])
                    let name = (user?["global_name"] as? String) ?? (user?["username"] as? String) ?? "Discord"
                    onEvent(.ready(name))
                } else if json["evt"] as? String == "ERROR" {
                    let message = (json["data"] as? [String: Any])?["message"] as? String
                    NSLog("Discord Rich Presence: %@", message ?? "error")
                }
            case 2:
                let message = json["message"] as? String ?? "Discord closed the connection"
                onEvent(.closed(message))
                return
            case 3:
                // PING: answered with PONG carrying the same body.
                write(op: 4, json)
            default:
                break
            }
        }
        onEvent(.closed(nil))
    }
}
