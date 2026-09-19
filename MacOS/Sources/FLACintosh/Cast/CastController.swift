import Foundation
import Network
import Observation

/// Google Cast: finding devices, and playing on one.
///
/// Anything that speaks Cast is found the same way and driven the same way —
/// Chromecasts, TVs with Google TV or Android TV built in, Nest and Home
/// speakers, soundbars, and speaker groups, which advertise themselves as a
/// device of their own. Music goes to Google's Default Media Receiver, which
/// every one of them has.
@MainActor
@Observable
final class CastController {
    nonisolated static let senderID = "sender-0"
    nonisolated static let receiverID = "receiver-0"
    /// Google's Default Media Receiver.
    nonisolated static let mediaReceiverApp = "CC1AD845"

    struct Device: Identifiable, Hashable, Sendable {
        var id: String
        var name: String
        var model: String
        var endpoint: NWEndpoint

        var isGroup: Bool { model.localizedCaseInsensitiveContains("group") }
        /// A speaker rather than a screen, for the icon.
        var isSpeaker: Bool {
            ["home", "nest audio", "nest mini", "audio", "speaker", "soundbar"].contains { model.localizedCaseInsensitiveContains($0) }
                && !model.localizedCaseInsensitiveContains("hub")
        }
        var symbol: String { isGroup ? "hifispeaker.2.fill" : (isSpeaker ? "hifispeaker.fill" : "tv") }
    }

    enum State: Equatable {
        case idle
        case connecting(Device)
        case connected(Device)

        var device: Device? {
            switch self {
            case .idle: nil
            case .connecting(let device), .connected(let device): device
            }
        }
    }

    enum Failure: LocalizedError {
        case timedOut
        case disconnected
        case refused(String)

        var errorDescription: String? {
            switch self {
            case .timedOut: "The Cast device did not answer"
            case .disconnected: "Lost the connection to the Cast device"
            case .refused(let detail): detail
            }
        }
    }

    private(set) var devices: [Device] = []
    private(set) var state: State = .idle
    /// The device's own volume, 0…1.
    private(set) var volume: Double?

    var isActive: Bool { state != .idle }
    var activeDevice: Device? { state.device }

    // What the receiver last said about the track. Read by the player's own
    // clock, which polls — so none of it needs observing.
    @ObservationIgnored private(set) var playerState = "IDLE"
    @ObservationIgnored private var reportedTime: TimeInterval = 0
    @ObservationIgnored private var reportedAt = Date.distantPast

    var isPlaying: Bool { playerState == "PLAYING" || playerState == "BUFFERING" }
    var isBuffering: Bool { playerState == "BUFFERING" || loading }

    /// Where the receiver is now, extrapolated from its last report.
    var estimatedTime: TimeInterval {
        playerState == "PLAYING" ? reportedTime + Date.now.timeIntervalSince(reportedAt) : reportedTime
    }

    /// The track came to its end on the device.
    @ObservationIgnored var onFinished: (() -> Void)?
    /// The receiver could not play what it was given.
    @ObservationIgnored var onMediaError: ((String) -> Void)?
    /// The session is over without being asked to end here — the device was
    /// switched off, or someone started something else on it.
    @ObservationIgnored var onSessionEnded: ((String) -> Void)?

    /// This Mac's address on the network the device is on.
    @ObservationIgnored private(set) var localAddress: String?

    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var channel: CastChannel?
    @ObservationIgnored private var channelToken: UUID?
    @ObservationIgnored private var ready: CheckedContinuation<Void, Error>?
    @ObservationIgnored private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    @ObservationIgnored private var nextRequest = 1
    @ObservationIgnored private var sessionID: String?
    @ObservationIgnored private var transportID: String?
    @ObservationIgnored private var mediaSessionID: Int?
    @ObservationIgnored private var finishReported = false
    @ObservationIgnored private var loading = false
    @ObservationIgnored private var poller: Task<Void, Never>?

    // MARK: - Discovery

    func startDiscovery() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_googlecast._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { results, _ in
            let found: [Device] = results.compactMap { result in
                guard case let .bonjour(txt) = result.metadata else { return nil }
                let name = txt["fn"] ?? {
                    if case let .service(name, _, _, _) = result.endpoint { return name }
                    return nil
                }()
                guard let name else { return nil }
                return Device(id: txt["id"] ?? name, name: name, model: txt["md"] ?? "Google Cast", endpoint: result.endpoint)
            }
            Task { @MainActor [weak self] in
                self?.devices = found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            }
        }
        browser.start(queue: DispatchQueue(label: "FLACintosh.cast.browser"))
        self.browser = browser
    }

    // MARK: - Session

    /// Connects and starts the media receiver on `device`, ready for `load`.
    func connect(to device: Device) async throws {
        if state.device != nil { disconnect(stopReceiver: state.device?.id != device.id) }
        state = .connecting(device)

        // Events from a socket already replaced — the old one closing after
        // a switch to another device — must not tear down the new session.
        let token = UUID()
        channelToken = token
        let channel = CastChannel(endpoint: device.endpoint) { [weak self] event in
            guard let self, self.channelToken == token else { return }
            self.handle(event)
        }
        self.channel = channel
        do {
            try await withTimeout(10) {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    self.ready = continuation
                    channel.start()
                }
            }

            send(namespace: CastMessage.Namespace.connection, to: Self.receiverID, ["type": "CONNECT"])
            let status = try await request(namespace: CastMessage.Namespace.receiver, to: Self.receiverID, [
                "type": "LAUNCH", "appId": Self.mediaReceiverApp,
            ], matching: { ($0["type"] as? String) == "RECEIVER_STATUS" && Self.mediaApp(in: $0) != nil })

            if let error = status["type"] as? String, error != "RECEIVER_STATUS" {
                throw Failure.refused("The Cast device could not start its media player (\(error))")
            }
            guard let app = Self.mediaApp(in: status),
                  let transport = app["transportId"] as? String
            else { throw Failure.refused("The Cast device did not start its media player") }
            sessionID = app["sessionId"] as? String
            transportID = transport
            applyReceiverStatus(status)
            send(namespace: CastMessage.Namespace.connection, to: transport, ["type": "CONNECT"])

            guard self.channel === channel else { throw Failure.disconnected }
            state = .connected(device)
            UserDefaults.standard.set(device.id, forKey: Self.lastDeviceKey)
            startPolling()
        } catch {
            if self.channel === channel { teardown() }
            throw error
        }
    }

    /// Ends casting. The receiver app is closed too, so the TV goes back to
    /// what it was showing rather than a frozen sleeve.
    func disconnect(stopReceiver: Bool = true) {
        guard channel != nil else {
            state = .idle
            return
        }
        if stopReceiver {
            // The track first, then the receiver app, so the TV goes back to
            // its own screen rather than holding a paused sleeve.
            if let transportID, let mediaSessionID {
                send(namespace: CastMessage.Namespace.media, to: transportID, [
                    "type": "STOP", "mediaSessionId": mediaSessionID, "requestId": takeRequestID(),
                ])
            }
            if let sessionID {
                send(namespace: CastMessage.Namespace.receiver, to: Self.receiverID, [
                    "type": "STOP", "sessionId": sessionID, "requestId": takeRequestID(),
                ])
            }
            UserDefaults.standard.removeObject(forKey: Self.lastDeviceKey)
        }
        if let transportID {
            send(namespace: CastMessage.Namespace.connection, to: transportID, ["type": "CLOSE"])
        }
        teardown()
    }

    /// The device last cast to, until casting is stopped from here. If the
    /// app quit while casting, the TV kept playing; this is how "This Mac"
    /// can still find it and stop it.
    nonisolated static let lastDeviceKey = "castLastDevice"

    /// Stops what this app left playing on a device in an earlier session.
    ///
    /// Connects without launching anything, and stops Google's media
    /// receiver only if it is the app running there.
    func stopLeftoverSession() async {
        guard !isActive,
              let id = UserDefaults.standard.string(forKey: Self.lastDeviceKey),
              let device = devices.first(where: { $0.id == id })
        else { return }
        UserDefaults.standard.removeObject(forKey: Self.lastDeviceKey)

        let token = UUID()
        channelToken = token
        let channel = CastChannel(endpoint: device.endpoint) { [weak self] event in
            guard let self, self.channelToken == token else { return }
            if case .ready(let address) = event {
                self.localAddress = address
                self.ready?.resume()
                self.ready = nil
            } else if case .message(let message) = event {
                self.receive(message)
            }
        }
        self.channel = channel
        defer {
            if self.channel === channel {
                channel.close()
                self.channel = nil
                channelToken = nil
            }
        }
        do {
            try await withTimeout(8) {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    self.ready = continuation
                    channel.start()
                }
            }
            send(namespace: CastMessage.Namespace.connection, to: Self.receiverID, ["type": "CONNECT"])
            let status = try await request(namespace: CastMessage.Namespace.receiver, to: Self.receiverID, ["type": "GET_STATUS"], timeout: 6)
            guard let app = Self.mediaApp(in: status), let session = app["sessionId"] as? String else { return }
            send(namespace: CastMessage.Namespace.receiver, to: Self.receiverID, [
                "type": "STOP", "sessionId": session, "requestId": takeRequestID(),
            ])
        } catch {
            return
        }
    }

    // MARK: - Media

    func load(_ media: CastMedia.Prepared, startAt: TimeInterval, autoplay: Bool) async throws {
        guard let transportID else { throw Failure.disconnected }

        var metadata: [String: Any] = [
            "metadataType": 3,
            "title": media.title,
            "artist": media.artist,
            "albumArtist": media.albumArtist,
            "albumName": media.album,
        ]
        if let number = media.trackNumber { metadata["trackNumber"] = number }
        if let artwork = media.artworkURL { metadata["images"] = [["url": artwork.absoluteString]] }

        var item: [String: Any] = [
            "contentId": media.url.absoluteString,
            "contentUrl": media.url.absoluteString,
            "contentType": media.contentType,
            "streamType": "BUFFERED",
            "metadata": metadata,
        ]
        if let duration = media.duration { item["duration"] = duration }

        loading = true
        finishReported = true
        defer { loading = false }
        reportedTime = startAt
        reportedAt = .now

        let reply = try await request(namespace: CastMessage.Namespace.media, to: transportID, [
            "type": "LOAD",
            "sessionId": sessionID ?? "",
            "media": item,
            "autoplay": autoplay,
            "currentTime": startAt,
        ], timeout: 30)

        if let failure = Self.failure(in: reply) { throw Failure.refused(failure) }
        applyMediaStatus(reply)
        finishReported = false
    }

    func play() { mediaCommand("PLAY", optimistic: "PLAYING") }
    func pause() { mediaCommand("PAUSE", optimistic: "PAUSED") }

    func seek(to time: TimeInterval) {
        reportedTime = time
        reportedAt = .now
        mediaCommand("SEEK", extra: ["currentTime": time])
    }

    func setVolume(_ level: Double) {
        guard channel != nil else { return }
        volume = level
        send(namespace: CastMessage.Namespace.receiver, to: Self.receiverID, [
            "type": "SET_VOLUME", "volume": ["level": min(max(level, 0), 1)], "requestId": takeRequestID(),
        ])
    }

    // MARK: - Incoming

    private func handle(_ event: CastChannel.Event) {
        switch event {
        case .ready(let address):
            localAddress = address
            ready?.resume()
            ready = nil
        case .closed(let error):
            let wasConnected: Bool = { if case .connected = state { return true }; return false }()
            ready?.resume(throwing: error ?? Failure.disconnected)
            ready = nil
            teardown()
            if wasConnected {
                onSessionEnded?("Lost the connection to the Cast device")
            }
        case .message(let message):
            receive(message)
        }
    }

    private func receive(_ message: CastMessage) {
        guard let json = message.json else { return }
        let type = json["type"] as? String

        // An error answers the request whatever it was waiting for.
        let isError = type.map { $0.hasSuffix("ERROR") || $0.hasSuffix("FAILED") || $0 == "INVALID_REQUEST" } ?? false
        if let id = json["requestId"] as? Int, id != 0, pending[id] != nil, isError || (matchers[id]?(json) ?? true) {
            matchers[id] = nil
            pending.removeValue(forKey: id)?.resume(returning: json)
        } else if let waiting = matchers.first(where: { pending[$0.key] != nil && $0.value(json) }) {
            // LAUNCH is answered by whichever status first shows the app
            // running, and that one does not always echo the request id.
            matchers[waiting.key] = nil
            pending.removeValue(forKey: waiting.key)?.resume(returning: json)
        }

        switch (message.namespace, type) {
        case (CastMessage.Namespace.connection, "CLOSE"):
            if message.source == transportID, case .connected = state {
                teardown()
                onSessionEnded?("Casting stopped on the device")
            }
        case (CastMessage.Namespace.receiver, "RECEIVER_STATUS"):
            applyReceiverStatus(json)
            if case .connected = state, let transportID {
                let apps = (json["status"] as? [String: Any])?["applications"] as? [[String: Any]] ?? []
                if !apps.contains(where: { $0["transportId"] as? String == transportID }) {
                    teardown()
                    onSessionEnded?("Casting stopped on the device")
                }
            }
        case (CastMessage.Namespace.media, "MEDIA_STATUS"):
            applyMediaStatus(json)
        case (CastMessage.Namespace.media, "LOAD_FAILED"), (CastMessage.Namespace.media, "INVALID_REQUEST"):
            if !loading { onMediaError?(Self.failure(in: json) ?? "The Cast device could not play this track") }
        default:
            break
        }
    }

    private func applyReceiverStatus(_ json: [String: Any]) {
        guard let level = ((json["status"] as? [String: Any])?["volume"] as? [String: Any])?["level"] as? Double else { return }
        if volume.map({ abs($0 - level) > 0.005 }) ?? true { volume = level }
    }

    private func applyMediaStatus(_ json: [String: Any]) {
        guard let status = (json["status"] as? [[String: Any]])?.first else { return }
        if let id = status["mediaSessionId"] as? Int { mediaSessionID = id }
        if let state = status["playerState"] as? String { playerState = state }
        if let time = status["currentTime"] as? Double {
            reportedTime = time
            reportedAt = .now
        }
        guard !loading, playerState == "IDLE" else { return }
        switch status["idleReason"] as? String {
        case "FINISHED":
            guard !finishReported else { return }
            finishReported = true
            onFinished?()
        case "ERROR":
            guard !finishReported else { return }
            finishReported = true
            onMediaError?("The Cast device could not play this track")
        default:
            break
        }
    }

    private static func mediaApp(in status: [String: Any]) -> [String: Any]? {
        let apps = (status["status"] as? [String: Any])?["applications"] as? [[String: Any]]
        return apps?.first { $0["appId"] as? String == mediaReceiverApp && $0["transportId"] != nil }
    }

    private static func failure(in json: [String: Any]) -> String? {
        switch json["type"] as? String {
        case "LOAD_FAILED": "The Cast device could not play this track"
        case "LOAD_CANCELLED": "Loading was cancelled on the Cast device"
        case "INVALID_REQUEST":
            "The Cast device refused the request" + ((json["reason"] as? String).map { " (\($0))" } ?? "")
        default: nil
        }
    }

    // MARK: - Plumbing

    @ObservationIgnored private var matchers: [Int: ([String: Any]) -> Bool] = [:]

    private func takeRequestID() -> Int {
        nextRequest += 1
        return nextRequest
    }

    private func send(namespace: String, to destination: String, _ json: [String: Any]) {
        channel?.send(CastMessage(source: Self.senderID, destination: destination, namespace: namespace, json: json))
    }

    private func request(
        namespace: String,
        to destination: String,
        _ json: [String: Any],
        timeout: TimeInterval = 15,
        matching: (([String: Any]) -> Bool)? = nil
    ) async throws -> [String: Any] {
        guard channel != nil else { throw Failure.disconnected }
        let id = takeRequestID()
        var json = json
        json["requestId"] = id
        return try await withTimeout(timeout, onTimeout: { [weak self] in
            self?.matchers[id] = nil
            self?.pending.removeValue(forKey: id)?.resume(throwing: Failure.timedOut)
        }) {
            try await withCheckedThrowingContinuation { continuation in
                self.pending[id] = continuation
                if let matching { self.matchers[id] = matching }
                self.send(namespace: namespace, to: destination, json)
            }
        }
    }

    private func mediaCommand(_ type: String, optimistic: String? = nil, extra: [String: Any] = [:]) {
        guard let transportID, let mediaSessionID else { return }
        if let optimistic {
            reportedTime = estimatedTime
            reportedAt = .now
            playerState = optimistic
        }
        var json = extra
        json["type"] = type
        json["mediaSessionId"] = mediaSessionID
        json["requestId"] = takeRequestID()
        send(namespace: CastMessage.Namespace.media, to: transportID, json)
    }

    /// The receiver sends status when something changes; asking now and
    /// then keeps the clock honest across a long track.
    private func startPolling() {
        poller?.cancel()
        poller = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, let transportID = self.transportID else { return }
                if let mediaSessionID = self.mediaSessionID {
                    self.send(namespace: CastMessage.Namespace.media, to: transportID, [
                        "type": "GET_STATUS", "mediaSessionId": mediaSessionID, "requestId": self.takeRequestID(),
                    ])
                }
            }
        }
    }

    private func teardown() {
        poller?.cancel()
        poller = nil
        channel?.close()
        channel = nil
        channelToken = nil
        sessionID = nil
        transportID = nil
        mediaSessionID = nil
        playerState = "IDLE"
        loading = false
        matchers = [:]
        let waiting = pending
        pending = [:]
        waiting.values.forEach { $0.resume(throwing: Failure.disconnected) }
        state = .idle
        volume = nil
    }

    private func withTimeout<T>(
        _ seconds: TimeInterval,
        onTimeout: (() -> Void)? = nil,
        _ operation: @escaping () async throws -> T
    ) async throws -> T {
        let timer = Task { [weak self] in
            try await Task.sleep(for: .seconds(seconds))
            if let onTimeout {
                onTimeout()
            } else if let self {
                self.ready?.resume(throwing: Failure.timedOut)
                self.ready = nil
            }
        }
        defer { timer.cancel() }
        return try await operation()
    }
}
