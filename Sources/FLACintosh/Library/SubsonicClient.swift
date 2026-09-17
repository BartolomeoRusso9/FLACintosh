import CryptoKit
import Foundation

/// Navidrome, and anything else speaking Subsonic.
///
/// Authentication is the API's own scheme: a per-request salt and
/// `md5(password + salt)`, so the password itself never crosses the wire.
/// MD5 is not a choice here — it is what the protocol specifies.
struct SubsonicClient: MusicServerClient {
    let server: MusicServer
    let password: String
    var session: URLSession = .shared

    private static let version = "1.16.1"
    private static let client = "macos-music-player"

    func albums(progress: @escaping @Sendable (_ done: Int, _ total: Int) -> Void) async throws -> [LibraryAlbum] {
        var listed: [Album] = []
        var offset = 0
        // The API caps a page at 500 and says nothing about how many there
        // are, so it is walked until a page comes back short. The whole list
        // comes first, details after: that is what gives the count a total.
        while true {
            let page: AlbumList = try await get(
                "getAlbumList2",
                ["type": "alphabeticalByName", "size": "500", "offset": String(offset)]
            ) { $0.albumList2 }

            let albums = page.album ?? []
            if albums.isEmpty { break }
            listed.append(contentsOf: albums)
            offset += albums.count
            if albums.count < 500 { break }
        }

        progress(0, listed.count)
        var found: [LibraryAlbum] = []
        for (index, album) in listed.enumerated() {
            found.append(try await detail(album))
            progress(index + 1, listed.count)
        }
        return found
    }

    private func detail(_ album: Album) async throws -> LibraryAlbum {
        let detail: AlbumWithSongs = try await get("getAlbum", ["id": album.id]) { $0.album }
        let artist = album.artist ?? "Unknown Artist"
        let artworkURL = url("getCoverArt", ["id": album.coverArt ?? album.id, "size": "600"])

        let tracks = (detail.song ?? []).enumerated().map { index, song in
            LibraryTrack(
                id: streamURL(for: song.id) ?? server.address,
                title: song.title ?? "Untitled",
                artist: song.artist ?? artist,
                albumArtist: artist,
                album: album.name ?? "Unknown Album",
                trackNumber: song.track ?? index + 1,
                discNumber: song.discNumber,
                duration: song.duration.map(Double.init),
                hasLyrics: false,
                artworkURL: artworkURL,
                source: .server(server.id)
            )
        }

        return LibraryAlbum(
            id: "\(server.id.uuidString)|\(album.id)",
            title: album.name ?? "Unknown Album",
            artist: artist,
            tracks: tracks,
            cover: try? await cover(album.coverArt ?? album.id),
            addedAt: album.created.flatMap(ServerDate.parse) ?? .distantPast,
            year: album.year.map(String.init),
            source: .server(server.id)
        )
    }

    func cover(_ albumID: String) async throws -> Data? {
        guard let url = url("getCoverArt", ["id": albumID, "size": "320"]) else { return nil }
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        // A server with no art for the record answers with a JSON error
        // rather than a 404; a picture never starts with `{`.
        return data.first == UInt8(ascii: "{") ? nil : data
    }

    func streamURL(for trackID: String) -> URL? {
        url("stream", ["id": trackID])
    }

    /// Reachable, and the credentials work.
    func ping() async throws {
        let _: Empty = try await get("ping", [:]) { _ in Empty() }
    }

    func playlists() async throws -> [ServerPlaylist] {
        let listed: PlaylistList = try await get("getPlaylists", [:]) { $0.playlists }
        var found: [ServerPlaylist] = []
        for playlist in listed.playlist ?? [] {
            let detail: PlaylistWithSongs = try await get("getPlaylist", ["id": playlist.id]) { $0.playlist }
            found.append(ServerPlaylist(
                id: "\(server.id.uuidString)/\(playlist.id)",
                name: playlist.name ?? "Playlist",
                trackURLs: (detail.entry ?? []).compactMap { streamURL(for: $0.id) },
                source: .server(server.id)
            ))
        }
        return found
    }

    // MARK: - Requests

    private func url(_ method: String, _ parameters: [String: String]) -> URL? {
        let salt = UUID().uuidString.prefix(8).lowercased()
        let token = Insecure.MD5.hash(data: Data((password + salt).utf8))
            .map { String(format: "%02x", $0) }
            .joined()

        var components = URLComponents(
            url: server.address.appendingPathComponent("rest/\(method)"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "u", value: server.username),
            URLQueryItem(name: "t", value: token),
            URLQueryItem(name: "s", value: String(salt)),
            URLQueryItem(name: "v", value: Self.version),
            URLQueryItem(name: "c", value: Self.client),
            URLQueryItem(name: "f", value: "json"),
        ] + parameters.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components?.url
    }

    private func get<T>(
        _ method: String,
        _ parameters: [String: String],
        _ extract: (Response) -> T?
    ) async throws -> T {
        guard let url = url(method, parameters) else { throw MusicServerError.notReachable }
        let (data, _): (Data, URLResponse)
        do {
            (data, _) = try await session.data(from: url)
        } catch {
            throw MusicServerError.notReachable
        }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        if let error = envelope.subsonicResponse.error {
            throw error.code == 40 ? MusicServerError.auth : .badResponse(error.message ?? "Error \(error.code)")
        }
        guard let value = extract(envelope.subsonicResponse) else {
            throw MusicServerError.badResponse("\(method) returned nothing usable")
        }
        return value
    }

    // MARK: - Wire types

    struct Empty {}

    private struct Envelope: Decodable {
        let subsonicResponse: Response

        enum CodingKeys: String, CodingKey {
            case subsonicResponse = "subsonic-response"
        }
    }

    struct Response: Decodable {
        var error: APIError?
        var albumList2: AlbumList?
        var album: AlbumWithSongs?
        var playlists: PlaylistList?
        var playlist: PlaylistWithSongs?
    }

    struct PlaylistList: Decodable {
        var playlist: [Playlist]?
    }

    struct Playlist: Decodable {
        var id: String
        var name: String?
    }

    struct PlaylistWithSongs: Decodable {
        var entry: [Song]?
    }

    struct APIError: Decodable {
        var code: Int
        var message: String?
    }

    struct AlbumList: Decodable {
        var album: [Album]?
    }

    struct Album: Decodable {
        var id: String
        var name: String?
        var artist: String?
        var coverArt: String?
        var year: Int?
        var created: String?
    }

    struct AlbumWithSongs: Decodable {
        var song: [Song]?
    }

    struct Song: Decodable {
        var id: String
        var title: String?
        var artist: String?
        var track: Int?
        var discNumber: Int?
        var duration: Int?
    }
}
