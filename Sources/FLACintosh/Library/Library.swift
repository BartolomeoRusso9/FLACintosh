import Foundation

/// Where a track lives: the library folder on this Mac, or a server.
///
/// Every source is in the library at once, so the same record can be there
/// twice — ripped locally and served by Jellyfin. This is what tells them
/// apart on screen.
enum LibrarySource: Hashable, Sendable {
    case folder
    case server(UUID)

    /// A stable string, for remembering which sources are hidden.
    var key: String {
        switch self {
        case .folder: "folder"
        case .server(let id): id.uuidString
        }
    }

    init?(key: String) {
        if key == "folder" {
            self = .folder
        } else if let id = UUID(uuidString: key) {
            self = .server(id)
        } else {
            return nil
        }
    }
}

/// One playable file, as the library knows it.
///
/// Identified by its URL rather than by a tag: two different rips of the
/// same song are two rows, which is what the file system says and what a
/// person renaming a folder expects.
struct LibraryTrack: Identifiable, Sendable, Equatable, Hashable {
    let id: URL
    var title: String
    var artist: String
    var albumArtist: String
    var album: String
    var trackNumber: Int?
    var discNumber: Int?
    var duration: TimeInterval?
    /// Whether this track has timed lyrics to show — the whole point of the
    /// app, so the library says so up front rather than after you press play.
    var hasLyrics: Bool
    /// A server track's sleeve. A stream carries no tags to read one from, so
    /// the player asks the server for it instead; local files leave it nil.
    var artworkURL: URL? = nil
    var source: LibrarySource = .folder

    var url: URL { id }
}

/// Tracks grouped the way a record is.
struct LibraryAlbum: Identifiable, Sendable, Equatable, Hashable {
    let id: String
    var title: String
    var artist: String
    var tracks: [LibraryTrack]
    /// A small JPEG, made during the scan. The full-size cover stays in the
    /// file: a grid of two hundred 3000×3000 sleeves is a gigabyte of RAM.
    var cover: Data?
    /// Newest file in the album, which is what "recently added" means when
    /// the library is a folder rather than a service.
    var addedAt: Date

    var year: String?
    var source: LibrarySource = .folder

    /// Hashed by id alone. The synthesised version would hash the cover
    /// too, and a navigation stack comparing values would then chew through
    /// twenty kilobytes of JPEG on every push.
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    var lyricCount: Int { tracks.count(where: \.hasLyrics) }
    var duration: TimeInterval { tracks.compactMap(\.duration).reduce(0, +) }
}

/// An artist and the records of theirs that are on disk.
struct LibraryArtist: Identifiable, Sendable, Hashable {
    var id: String { name }
    var name: String
    var albums: [LibraryAlbum]

    var trackCount: Int { albums.reduce(0) { $0 + $1.tracks.count } }
}
