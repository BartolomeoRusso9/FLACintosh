import Foundation

/// Jellyfin.
///
/// Unlike Subsonic there is a login step: username and password are
/// exchanged once for an access token, and every later request carries it.
actor JellyfinClient: MusicServerClient {
    let server: MusicServer
    private let password: String
    private let session: URLSession

    private var token: String?
    private var userID: String?

    /// Identifies this client to the server; Jellyfin shows it in its
    /// devices list, so it should say what it actually is.
    private static let deviceID = "macos-music-player"

    init(server: MusicServer, password: String, session: URLSession = .shared) {
        self.server = server
        self.password = password
        self.session = session
    }

    func albums(progress: @escaping @Sendable (_ done: Int, _ total: Int) -> Void) async throws -> [LibraryAlbum] {
        let user = try await authenticate()
        let albums: ItemsResponse = try await get(
            "Items",
            [
                "userId": user,
                "IncludeItemTypes": "MusicAlbum",
                "Recursive": "true",
                "SortBy": "SortName",
                "Fields": "DateCreated,ProductionYear,AlbumArtist",
                "Limit": "5000",
            ]
        )

        let listed = albums.Items ?? []
        progress(0, listed.count)
        var found: [LibraryAlbum] = []
        for (index, album) in listed.enumerated() {
            found.append(try await detail(album, user: user))
            progress(index + 1, listed.count)
        }
        return found
    }

    private func detail(_ album: Item, user: String) async throws -> LibraryAlbum {
        let songs: ItemsResponse = try await get(
            "Items",
            [
                "userId": user,
                "ParentId": album.Id,
                "IncludeItemTypes": "Audio",
                "SortBy": "ParentIndexNumber,IndexNumber,SortName",
                "Fields": "RunTimeTicks",
                "Limit": "500",
            ]
        )

        let artist = album.AlbumArtist ?? album.Name ?? "Unknown Artist"
        let tracks = (songs.Items ?? []).enumerated().map { index, song in
            LibraryTrack(
                id: streamURL(for: song.Id) ?? server.address,
                title: song.Name ?? "Untitled",
                artist: song.AlbumArtist ?? artist,
                albumArtist: artist,
                album: album.Name ?? "Unknown Album",
                trackNumber: song.IndexNumber ?? index + 1,
                discNumber: song.ParentIndexNumber,
                // Jellyfin counts in ticks: ten million to the second.
                duration: song.RunTimeTicks.map { Double($0) / 10_000_000 },
                hasLyrics: false,
                artworkURL: coverURL(album.Id, maxHeight: 600),
                source: .server(server.id)
            )
        }

        return LibraryAlbum(
            id: "\(server.id.uuidString)|\(album.Id)",
            title: album.Name ?? "Unknown Album",
            artist: artist,
            tracks: tracks,
            cover: try? await cover(album.Id),
            addedAt: album.DateCreated.flatMap { ISO8601DateFormatter().date(from: $0) } ?? .distantPast,
            year: album.ProductionYear.map(String.init),
            source: .server(server.id)
        )
    }

    func cover(_ albumID: String) async throws -> Data? {
        guard let url = coverURL(albumID, maxHeight: 320) else { return nil }
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    /// Images need no token: Jellyfin serves them to anyone who can reach it.
    nonisolated private func coverURL(_ albumID: String, maxHeight: Int) -> URL? {
        var components = URLComponents(
            url: server.address.appendingPathComponent("Items/\(albumID)/Images/Primary"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "maxHeight", value: String(maxHeight))]
        return components?.url
    }

    nonisolated func streamURL(for trackID: String) -> URL? {
        // The token goes in the query rather than a header: this URL is
        // handed to the downloader, which has no idea it is talking to
        // Jellyfin.
        guard let token = cachedToken else { return nil }
        var components = URLComponents(
            url: server.address.appendingPathComponent("Audio/\(trackID)/stream"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "static", value: "true"),
            URLQueryItem(name: "api_key", value: token),
        ]
        return components?.url
    }

    /// Read from a non-isolated cache so `streamURL` can stay synchronous —
    /// it is called from view code building a track list.
    nonisolated private var cachedToken: String? { TokenCache.shared.token(for: server.id) }

    func ping() async throws {
        _ = try await authenticate()
    }

    /// Asks Jellyfin to look for new files now rather than at its next
    /// scheduled scan — after a download, so the record shows up in minutes
    /// instead of hours. Only an administrator may; anyone else is refused,
    /// and the library still reloads later on its own.
    func refreshLibrary() async throws {
        _ = try await authenticate()
        var request = URLRequest(url: server.address.appendingPathComponent("Library/Refresh"))
        request.httpMethod = "POST"
        request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")

        let response: URLResponse
        do {
            (_, response) = try await session.data(for: request)
        } catch {
            throw MusicServerError.notReachable
        }
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            throw MusicServerError.badResponse("Jellyfin did not start a library scan")
        }
    }

    // MARK: - Auth

    @discardableResult
    private func authenticate() async throws -> String {
        if let userID, token != nil { return userID }

        var request = URLRequest(url: server.address.appendingPathComponent("Users/AuthenticateByName"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(
            AuthRequest(Username: server.username, Pw: password)
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw MusicServerError.notReachable
        }
        guard let http = response as? HTTPURLResponse else { throw MusicServerError.notReachable }
        guard http.statusCode != 401 else { throw MusicServerError.auth }
        guard http.statusCode == 200 else {
            throw MusicServerError.badResponse("Login returned \(http.statusCode)")
        }

        let result = try JSONDecoder().decode(AuthResponse.self, from: data)
        token = result.AccessToken
        userID = result.User.Id
        TokenCache.shared.set(result.AccessToken, for: server.id)
        return result.User.Id
    }

    /// Sent as `Authorization`. Jellyfin 10.11 and later answer the legacy
    /// `X-Emby-Authorization` / `X-MediaBrowser-Token` headers with 400 and
    /// 401 unless the server re-enables legacy authorization.
    private var authorizationHeader: String {
        var header = """
        MediaBrowser Client="macos-music-player", Device="Mac", \
        DeviceId="\(Self.deviceID)", Version="0.1"
        """
        if let token { header += ", Token=\"\(token)\"" }
        return header
    }

    // MARK: - Requests

    private func get<T: Decodable>(_ path: String, _ parameters: [String: String]) async throws -> T {
        let token = try await authenticate() // ensures a token exists
        _ = token

        var components = URLComponents(
            url: server.address.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = parameters.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components?.url else { throw MusicServerError.notReachable }

        var request = URLRequest(url: url)
        request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw MusicServerError.notReachable
        }
        guard let http = response as? HTTPURLResponse else { throw MusicServerError.notReachable }
        guard http.statusCode != 401 else { throw MusicServerError.auth }
        guard http.statusCode == 200 else {
            throw MusicServerError.badResponse("\(path) returned \(http.statusCode)")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Wire types

    private struct AuthRequest: Encodable {
        let Username: String
        let Pw: String
    }

    private struct AuthResponse: Decodable {
        let AccessToken: String
        let User: User

        struct User: Decodable { let Id: String }
    }

    private struct ItemsResponse: Decodable {
        var Items: [Item]?
    }

    private struct Item: Decodable {
        var Id: String
        var Name: String?
        var AlbumArtist: String?
        var ProductionYear: Int?
        var DateCreated: String?
        var IndexNumber: Int?
        var ParentIndexNumber: Int?
        var RunTimeTicks: Int?
    }
}

/// Access tokens, so a stream URL can be built without awaiting an actor.
final class TokenCache: @unchecked Sendable {
    static let shared = TokenCache()

    private let lock = NSLock()
    private var tokens: [UUID: String] = [:]

    func token(for id: UUID) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return tokens[id]
    }

    func set(_ token: String, for id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        tokens[id] = token
    }
}
