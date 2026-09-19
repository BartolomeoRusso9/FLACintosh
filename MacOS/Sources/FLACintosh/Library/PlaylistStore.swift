import Foundation
import Observation
import SwiftUI

/// Playlists: your own, kept on this Mac, and the ones on your servers.
///
/// A playlist here is a list of songs by address, with their names beside
/// them. The address finds the song in the library — a file's path, or a
/// server track's stable key — and the names stand in when it cannot: a file
/// that moved, a server that is switched off. Songs from every source can
/// sit in the same playlist.
///
/// Server playlists are read with the library and shown as they are; they
/// are edited on the server.
@MainActor
@Observable
final class PlaylistStore {
    struct Entry: Codable, Hashable, Sendable {
        var url: String
        var title: String
        var artist: String
        var album: String
        var duration: Double?

        init(_ track: LibraryTrack) {
            url = LibraryTrack.storable(track.url)
            title = track.title
            artist = track.artist
            album = track.album
            duration = track.duration
        }
    }

    struct Playlist: Codable, Identifiable, Hashable, Sendable {
        var id: UUID
        var name: String
        var entries: [Entry]
        var created: Date
        var modified: Date
    }

    /// A playlist from either place, the way the sidebar and the playlist
    /// page see them.
    enum Reference: Hashable, Sendable {
        case local(UUID)
        case server(String)
    }

    private(set) var playlists: [Playlist] = []

    private static var fileURL: URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let folder = support.appendingPathComponent("FLACintosh", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("playlists.json")
    }

    init() {
        guard let url = Self.fileURL, let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        playlists = (try? decoder.decode([Playlist].self, from: data)) ?? []
    }

    func playlist(_ id: UUID) -> Playlist? {
        playlists.first { $0.id == id }
    }

    // MARK: - Editing

    @discardableResult
    func create(named name: String? = nil, with tracks: [LibraryTrack] = []) -> Playlist {
        let playlist = Playlist(
            id: UUID(),
            name: name ?? nextName(),
            entries: tracks.map(Entry.init),
            created: .now,
            modified: .now
        )
        playlists.append(playlist)
        save()
        return playlist
    }

    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        update(id) { $0.name = trimmed }
    }

    func delete(_ id: UUID) {
        playlists.removeAll { $0.id == id }
        save()
    }

    func add(_ tracks: [LibraryTrack], to id: UUID) {
        update(id) { $0.entries.append(contentsOf: tracks.map(Entry.init)) }
    }

    func remove(at offsets: IndexSet, from id: UUID) {
        update(id) { playlist in
            for index in offsets.sorted(by: >) where playlist.entries.indices.contains(index) {
                playlist.entries.remove(at: index)
            }
        }
    }

    func move(from source: IndexSet, to destination: Int, in id: UUID) {
        update(id) { $0.entries.move(fromOffsets: source, toOffset: destination) }
    }

    private func update(_ id: UUID, _ change: (inout Playlist) -> Void) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        change(&playlists[index])
        playlists[index].modified = .now
        save()
    }

    private func nextName() -> String {
        let names = Set(playlists.map(\.name))
        if !names.contains("New Playlist") { return "New Playlist" }
        var number = 2
        while names.contains("New Playlist \(number)") { number += 1 }
        return "New Playlist \(number)"
    }

    // MARK: - Resolving

    /// The playlist's songs as tracks, one per entry, in order — nil where a
    /// song cannot be found or played right now, so positions still line up
    /// with the entries for moving and removing.
    func tracks(of playlist: Playlist, in library: LibraryStore, offline: OfflineStore?) -> [LibraryTrack?] {
        playlist.entries.map { entry in
            guard let url = URL(string: entry.url) else { return nil }
            if let found = library.track(for: url) { return found }
            let available = url.isFileURL
                ? FileManager.default.fileExists(atPath: url.path)
                : offline?.localFile(for: url) != nil
            guard available else {
                // Last resort: the same song under another address.
                return library.tracks.first { $0.title == entry.title && $0.artist == entry.artist }
            }
            return LibraryTrack(
                id: url,
                title: entry.title,
                artist: entry.artist,
                albumArtist: entry.artist,
                album: entry.album,
                duration: entry.duration,
                hasLyrics: false
            )
        }
    }

    func tracks(of playlist: ServerPlaylist, in library: LibraryStore) -> [LibraryTrack] {
        playlist.trackURLs.compactMap { library.track(for: $0) }
    }

    // MARK: - Disk

    private func save() {
        guard let url = Self.fileURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(playlists) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
