import Foundation

/// One message of the Cast v2 protocol, as it goes over the wire.
///
/// Google Cast has no SDK for macOS, but the protocol under the SDKs is
/// small: a TLS socket to port 8009 carrying length-prefixed protobuf
/// `CastMessage`s, each of which is an envelope around a JSON string. Only
/// that one protobuf message exists, with seven fields, so it is encoded by
/// hand here rather than pulling in a protobuf runtime for it.
///
///     message CastMessage {
///       required ProtocolVersion protocol_version = 1;  // CASTV2_1_0 = 0
///       required string source_id = 2;
///       required string destination_id = 3;
///       required string namespace = 4;
///       required PayloadType payload_type = 5;          // STRING = 0
///       optional string payload_utf8 = 6;
///       optional bytes payload_binary = 7;
///     }
struct CastMessage: Sendable {
    var source: String
    var destination: String
    var namespace: String
    var payload: String

    // MARK: Namespaces

    enum Namespace {
        static let connection = "urn:x-cast:com.google.cast.tp.connection"
        static let heartbeat = "urn:x-cast:com.google.cast.tp.heartbeat"
        static let receiver = "urn:x-cast:com.google.cast.receiver"
        static let media = "urn:x-cast:com.google.cast.media"
    }

    /// The JSON inside, or nil for a payload that is not an object.
    var json: [String: Any]? {
        guard let data = payload.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    init(source: String, destination: String, namespace: String, payload: String) {
        self.source = source
        self.destination = destination
        self.namespace = namespace
        self.payload = payload
    }

    init(source: String, destination: String, namespace: String, json: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: json)) ?? Data("{}".utf8)
        self.init(source: source, destination: destination, namespace: namespace, payload: String(decoding: data, as: UTF8.self))
    }

    // MARK: Encoding

    /// The message with its four-byte, big-endian length in front — the
    /// framing the socket expects.
    func framed() -> Data {
        var body = Data()
        Self.appendVarintField(1, 0, to: &body)
        Self.appendStringField(2, source, to: &body)
        Self.appendStringField(3, destination, to: &body)
        Self.appendStringField(4, namespace, to: &body)
        Self.appendVarintField(5, 0, to: &body)
        Self.appendStringField(6, payload, to: &body)

        var length = UInt32(body.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(body)
        return frame
    }

    private static func appendVarint(_ value: UInt64, to data: inout Data) {
        var value = value
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            data.append(byte)
        } while value != 0
    }

    private static func appendVarintField(_ number: UInt64, _ value: UInt64, to data: inout Data) {
        appendVarint(number << 3 | 0, to: &data)
        appendVarint(value, to: &data)
    }

    private static func appendStringField(_ number: UInt64, _ value: String, to data: inout Data) {
        let bytes = Data(value.utf8)
        appendVarint(number << 3 | 2, to: &data)
        appendVarint(UInt64(bytes.count), to: &data)
        data.append(bytes)
    }

    // MARK: Decoding

    /// Reads one message body (without its length prefix). Binary payloads —
    /// only device authentication uses them — come back as an empty string.
    static func decode(_ body: Data) -> CastMessage? {
        let bytes = [UInt8](body)
        var index = 0
        var message = CastMessage(source: "", destination: "", namespace: "", payload: "")

        func varint() -> UInt64? {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while index < bytes.count, shift < 64 {
                let byte = bytes[index]
                index += 1
                result |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return result }
                shift += 7
            }
            return nil
        }

        while index < bytes.count {
            guard let key = varint() else { return nil }
            let field = key >> 3
            switch key & 7 {
            case 0:
                guard varint() != nil else { return nil }
            case 2:
                guard let length = varint(), index + Int(length) <= bytes.count else { return nil }
                let slice = bytes[index ..< index + Int(length)]
                index += Int(length)
                let text = String(decoding: slice, as: UTF8.self)
                switch field {
                case 2: message.source = text
                case 3: message.destination = text
                case 4: message.namespace = text
                case 6: message.payload = text
                default: break
                }
            case 5:
                index += 4
            case 1:
                index += 8
            default:
                return nil
            }
        }
        return message
    }
}
