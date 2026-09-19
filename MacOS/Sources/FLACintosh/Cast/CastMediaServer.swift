import Foundation
import Network

/// A tiny HTTP server the Cast device fetches local music from.
///
/// A Cast receiver plays URLs, not bytes: a file on this Mac has to be
/// somewhere it can ask for. Only what has been published is served, each
/// under a random name, so the port hands out nothing else on the disk.
/// Range requests are answered — the receiver seeks with them.
final class CastMediaServer: @unchecked Sendable {
    static let shared = CastMediaServer()

    private enum Body {
        case file(URL)
        case data(Data)
    }

    private struct Entry {
        var body: Body
        var contentType: String
    }

    private let queue = DispatchQueue(label: "FLACintosh.cast.http")
    private var listener: NWListener?
    private var port: UInt16?
    private var waiters: [CheckedContinuation<UInt16, Error>] = []
    private var entries: [String: Entry] = [:]
    /// Newest last, so the oldest can go: a long evening of casting should
    /// not keep every track it ever played reachable.
    private var order: [String] = []

    /// Publishes a file and returns the path it is served under.
    func publish(file: URL, contentType: String) -> String {
        add(Entry(body: .file(file), contentType: contentType), suffix: file.pathExtension)
    }

    func publish(data: Data, contentType: String) -> String {
        add(Entry(body: .data(data), contentType: contentType), suffix: contentType.hasSuffix("png") ? "png" : "jpg")
    }

    /// The port, starting the listener the first time.
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                if let port = self.port {
                    continuation.resume(returning: port)
                    return
                }
                self.waiters.append(continuation)
                guard self.listener == nil else { return }
                do {
                    let listener = try NWListener(using: .tcp)
                    listener.stateUpdateHandler = { [weak self] state in self?.listenerChanged(state) }
                    listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                    self.listener = listener
                    listener.start(queue: self.queue)
                } catch {
                    self.fail(error)
                }
            }
        }
    }

    // MARK: - Listener

    private func add(_ entry: Entry, suffix: String) -> String {
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let path = "/cast/\(token)" + (suffix.isEmpty ? "" : ".\(suffix)")
        queue.sync {
            entries[path] = entry
            order.append(path)
            while order.count > 64 {
                entries[order.removeFirst()] = nil
            }
        }
        return path
    }

    private func listenerChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            port = listener?.port?.rawValue
            if let port {
                waiters.forEach { $0.resume(returning: port) }
                waiters = []
            }
        case .failed(let error):
            fail(error)
        default:
            break
        }
    }

    private func fail(_ error: Error) {
        listener?.cancel()
        listener = nil
        port = nil
        waiters.forEach { $0.resume(throwing: error) }
        waiters = []
    }

    // MARK: - Requests

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        readRequest(connection, buffer: Data())
    }

    private func readRequest(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                self.respond(to: String(decoding: buffer[..<end.lowerBound], as: UTF8.self), on: connection)
            } else if error != nil || complete || buffer.count > 64 * 1024 {
                connection.cancel()
            } else {
                self.readRequest(connection, buffer: buffer)
            }
        }
    }

    private func respond(to request: String, on connection: NWConnection) {
        let lines = request.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return reply(connection, status: "400 Bad Request") }
        let method = String(parts[0])
        let path = String(parts[1].split(separator: "?").first ?? "")

        if method == "OPTIONS" { return reply(connection, status: "204 No Content") }
        guard method == "GET" || method == "HEAD" else { return reply(connection, status: "405 Method Not Allowed") }
        guard let entry = entries[path] else { return reply(connection, status: "404 Not Found") }

        let size: Int64
        switch entry.body {
        case .data(let data):
            size = Int64(data.count)
        case .file(let url):
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let bytes = attributes[.size] as? NSNumber
            else { return reply(connection, status: "404 Not Found") }
            size = bytes.int64Value
        }

        var start: Int64 = 0
        var end: Int64 = size - 1
        var partial = false
        if let range = lines.dropFirst().first(where: { $0.lowercased().hasPrefix("range:") }),
           let spec = range.split(separator: "=", maxSplits: 1).last {
            let bounds = spec.split(separator: ",").first?.split(separator: "-", omittingEmptySubsequences: false) ?? []
            if bounds.count == 2 {
                let low = Int64(bounds[0].trimmingCharacters(in: .whitespaces))
                let high = Int64(bounds[1].trimmingCharacters(in: .whitespaces))
                if let low {
                    start = low
                    if let high { end = min(high, size - 1) }
                } else if let high {
                    start = max(0, size - high)
                }
                partial = true
            }
        }
        guard size == 0 || (start <= end && start < size) else {
            return reply(connection, status: "416 Range Not Satisfiable", extra: ["Content-Range": "bytes */\(size)"])
        }

        let length = size == 0 ? 0 : end - start + 1
        var headers = [
            "Content-Type": entry.contentType,
            "Content-Length": "\(length)",
            "Accept-Ranges": "bytes",
        ]
        if partial { headers["Content-Range"] = "bytes \(start)-\(end)/\(size)" }
        let head = header(status: partial ? "206 Partial Content" : "200 OK", headers)

        guard method == "GET", length > 0 else {
            connection.send(content: head, completion: .contentProcessed { _ in connection.cancel() })
            return
        }

        switch entry.body {
        case .data(let data):
            var packet = head
            packet.append(data.subdata(in: Int(start) ..< Int(end + 1)))
            connection.send(content: packet, completion: .contentProcessed { _ in connection.cancel() })
        case .file(let url):
            guard let handle = try? FileHandle(forReadingFrom: url) else { return reply(connection, status: "404 Not Found") }
            try? handle.seek(toOffset: UInt64(start))
            connection.send(content: head, completion: .contentProcessed { [weak self] error in
                guard error == nil else {
                    try? handle.close()
                    connection.cancel()
                    return
                }
                self?.stream(handle, remaining: length, on: connection)
            })
        }
    }

    /// A chunk at a time, the next read only once the last one is sent: the
    /// receiver reads at playback speed, and nothing piles up in memory.
    private func stream(_ handle: FileHandle, remaining: Int64, on connection: NWConnection) {
        guard remaining > 0,
              let chunk = try? handle.read(upToCount: Int(min(remaining, 256 * 1024))),
              !chunk.isEmpty
        else {
            try? handle.close()
            connection.cancel()
            return
        }
        connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
            guard error == nil else {
                try? handle.close()
                connection.cancel()
                return
            }
            self?.stream(handle, remaining: remaining - Int64(chunk.count), on: connection)
        })
    }

    private func reply(_ connection: NWConnection, status: String, extra: [String: String] = [:]) {
        var headers = extra
        headers["Content-Length"] = "0"
        connection.send(content: header(status: status, headers), completion: .contentProcessed { _ in connection.cancel() })
    }

    private func header(status: String, _ headers: [String: String]) -> Data {
        var headers = headers
        headers["Access-Control-Allow-Origin"] = "*"
        headers["Access-Control-Allow-Headers"] = "Range, Content-Type"
        headers["Access-Control-Expose-Headers"] = "Content-Length, Content-Range"
        headers["Connection"] = "close"
        let lines = ["HTTP/1.1 \(status)"] + headers.map { "\($0.key): \($0.value)" }
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }
}
