import Foundation

/// A remote library: Navidrome (or anything else speaking Subsonic) and
/// Jellyfin.
///
/// Both are made to produce the same `LibraryAlbum` and `LibraryTrack` values
/// the folder scanner produces, so every view in the app already knows how to
/// show them. What differs is only where the bytes come from — and that is
/// handled in one place, because SFBAudioEngine plays local files and nothing
/// else (`NSParameterAssert(url.isFileURL)`), so a remote track is fetched to
/// a cache before it plays.
struct MusicServer: Identifiable, Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable, CaseIterable {
        case subsonic
        case jellyfin

        var title: String {
            switch self {
            case .subsonic: "Navidrome / Subsonic"
            case .jellyfin: "Jellyfin"
            }
        }

        var symbol: String {
            switch self {
            case .subsonic: "server.rack"
            case .jellyfin: "play.tv"
            }
        }
    }

    var id: UUID = UUID()
    var kind: Kind
    var name: String
    var address: URL
    var username: String

    /// Never stored here — the keychain holds it, keyed by `id`.
    var passwordKey: String { "server-\(id.uuidString)" }
}

/// What a server hands back: the same shapes the folder scanner makes.
protocol MusicServerClient: Sendable {
    /// Everything on the server, grouped into records.
    ///
    /// `progress` is called with how many records are read and how many
    /// there are: each one is a request of its own, and on a big library
    /// that is minutes a sidebar should be able to count.
    func albums(progress: @escaping @Sendable (_ done: Int, _ total: Int) -> Void) async throws -> [LibraryAlbum]
    /// A cover, full size, for one album.
    func cover(_ albumID: String) async throws -> Data?
    /// Where to fetch a track's audio.
    func streamURL(for trackID: String) -> URL?
}

enum MusicServerError: LocalizedError {
    case badResponse(String)
    case auth
    case notReachable

    var errorDescription: String? {
        switch self {
        case .badResponse(let detail): detail
        case .auth: "The server refused those credentials"
        case .notReachable: "Could not reach the server"
        }
    }
}

// MARK: - Credentials

/// Passwords go in the keychain, never in `UserDefaults`.
enum Credentials {
    private static let service = "com.macos-music-player.servers"

    enum ReadError: Error, Equatable, Sendable {
        case missing
        /// macOS asked for the Mac's password and did not get it.
        case denied
        case failed(OSStatus)

        var message: String {
            switch self {
            case .missing: "No saved password for this server — remove it and add it again"
            case .denied: "macOS did not hand over the saved password"
            case .failed(let status): "Keychain error \(status)"
            }
        }
    }

    static func save(_ password: String, for key: String) {
        var query = base(key)
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = Data(password.utf8)
        if SecItemAdd(query as CFDictionary, nil) == errSecSuccess {
            // The copy that creates an item is on its access list.
            KeychainSignature.remember()
        }
    }

    /// Blocks while macOS asks for the Mac's password, when it does — so
    /// never on the main thread.
    static func read(_ key: String) -> Result<String, ReadError> {
        var query = base(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let password = String(data: data, encoding: .utf8) else {
                return .failure(.failed(status))
            }
            KeychainSignature.remember()
            return .success(password)
        case errSecItemNotFound:
            return .failure(.missing)
        case errSecAuthFailed, errSecUserCanceled, errSecInteractionNotAllowed:
            return .failure(.denied)
        default:
            return .failure(.failed(status))
        }
    }

    static func remove(_ key: String) {
        SecItemDelete(base(key) as CFDictionary)
    }

    private static func base(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }
}
