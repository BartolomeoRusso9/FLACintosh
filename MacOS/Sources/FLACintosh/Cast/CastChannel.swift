import Foundation
import Network

/// The socket to one Cast device: TLS to port 8009, messages in and out.
///
/// Cast devices present a self-signed certificate, so it is accepted without
/// checking — the same thing every sender does. What is sent over it is
/// music metadata and play/pause, not anything worth impersonating a
/// Chromecast for.
///
/// Callbacks arrive on the main actor.
final class CastChannel: @unchecked Sendable {
    enum Event {
        case ready(localAddress: String?)
        case message(CastMessage)
        case closed(Error?)
    }

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "FLACintosh.cast.channel")
    private var buffer = Data()
    private var heartbeat: DispatchSourceTimer?
    private var closed = false
    private let onEvent: @MainActor (Event) -> Void

    init(endpoint: NWEndpoint, onEvent: @escaping @MainActor (Event) -> Void) {
        self.onEvent = onEvent

        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(
            tls.securityProtocolOptions,
            { _, _, complete in complete(true) },
            DispatchQueue(label: "FLACintosh.cast.tls")
        )
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 8
        tcp.enableKeepalive = true
        let parameters = NWParameters(tls: tls, tcp: tcp)
        // IPv4: the address this Mac hands the device for local files is
        // read off this socket, and an IPv6 link-local one with its scope
        // suffix is not something a receiver will put in a URL.
        (parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
        connection = NWConnection(to: endpoint, using: parameters)
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                let local: String? = {
                    guard case let .hostPort(host, _)? = self.connection.currentPath?.localEndpoint else { return nil }
                    switch host {
                    case .ipv4(let address): return "\(address)"
                    case .ipv6(let address): return "[\(address)]".replacingOccurrences(of: "%.*\\]", with: "]", options: .regularExpression)
                    case .name(let name, _): return name
                    @unknown default: return nil
                    }
                }()
                self.emit(.ready(localAddress: local))
                self.receive()
                self.startHeartbeat()
            case .failed(let error):
                self.finish(error)
            case .waiting(let error):
                // Unreachable right now — for a device on the same network
                // that means it is off. Waiting would hang the button.
                self.finish(error)
            case .cancelled:
                self.finish(nil)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func send(_ message: CastMessage) {
        connection.send(content: message.framed(), completion: .contentProcessed { [weak self] error in
            if let error { self?.finish(error) }
        })
    }

    /// Closes once what was just sent has had time to leave. Cancelling at
    /// once discarded the STOP sent right before it, and the TV kept playing.
    func close() {
        queue.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, !self.closed else { return }
            self.closed = true
            self.heartbeat?.cancel()
            self.heartbeat = nil
            self.connection.cancel()
        }
    }

    // MARK: -

    private func emit(_ event: Event) {
        let onEvent = onEvent
        Task { @MainActor in onEvent(event) }
    }

    private func finish(_ error: Error?) {
        guard !closed else { return }
        closed = true
        heartbeat?.cancel()
        heartbeat = nil
        connection.cancel()
        emit(.closed(error))
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data { self.buffer.append(data) }
            self.drain()
            if let error {
                self.finish(error)
            } else if complete {
                self.finish(nil)
            } else {
                self.receive()
            }
        }
    }

    private func drain() {
        while buffer.count >= 4 {
            let length = buffer.prefix(4).reduce(0) { $0 << 8 | Int($1) }
            guard buffer.count >= 4 + length else { return }
            let body = buffer.subdata(in: buffer.startIndex + 4 ..< buffer.startIndex + 4 + length)
            buffer.removeSubrange(buffer.startIndex ..< buffer.startIndex + 4 + length)
            guard let message = CastMessage.decode(body) else { continue }

            // Answered here, on the socket's own queue, so a busy main
            // thread never makes the device think the sender has gone.
            if message.namespace == CastMessage.Namespace.heartbeat, message.json?["type"] as? String == "PING" {
                send(CastMessage(source: message.destination, destination: message.source,
                                 namespace: CastMessage.Namespace.heartbeat, json: ["type": "PONG"]))
                continue
            }
            emit(.message(message))
        }
    }

    /// A PING every five seconds: without traffic the device drops the
    /// connection after about ten.
    private func startHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            self?.send(CastMessage(source: CastController.senderID, destination: CastController.receiverID,
                                   namespace: CastMessage.Namespace.heartbeat, json: ["type": "PING"]))
        }
        timer.resume()
        heartbeat = timer
    }
}
