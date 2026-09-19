import SwiftUI

/// "Add to Playlist" for context menus and the album page: every playlist
/// kept on this Mac, and a new one made from the songs.
struct AddToPlaylistMenu: View {
    let tracks: [LibraryTrack]
    /// What a playlist made from these songs is called — the album's title,
    /// say. A generic name otherwise.
    var suggestedName: String?

    @Environment(PlaylistStore.self) private var playlists: PlaylistStore?

    var body: some View {
        if let playlists, !tracks.isEmpty {
            Menu("Add to Playlist") {
                Button("New Playlist") {
                    playlists.create(named: suggestedName, with: tracks)
                }
                if !playlists.playlists.isEmpty {
                    Divider()
                    ForEach(playlists.playlists) { playlist in
                        Button(playlist.name) { playlists.add(tracks, to: playlist.id) }
                    }
                }
            }
        }
    }
}

/// A playlist's page: yours, which can be renamed, reordered and trimmed, or
/// one from a server, shown as the server has it.
struct PlaylistDetail: View {
    let reference: PlaylistStore.Reference
    let model: PlaybackModel
    let library: LibraryStore
    /// After the playlist is deleted, to leave its page.
    let onDeleted: () -> Void

    @Environment(PlaylistStore.self) private var playlists
    @Environment(OfflineStore.self) private var offline: OfflineStore?

    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmingDelete = false
    @State private var editing: LibraryTrack?

    var body: some View {
        Group {
            switch reference {
            case .local(let id):
                if let playlist = playlists.playlist(id) {
                    page(
                        name: playlist.name,
                        items: playlists.tracks(of: playlist, in: library, offline: offline),
                        titles: playlist.entries.map { "\($0.title) — \($0.artist)" },
                        place: "On this Mac",
                        localID: id
                    )
                } else {
                    missing
                }
            case .server(let id):
                if let playlist = library.serverPlaylists.first(where: { $0.id == id }) {
                    let tracks = playlists.tracks(of: playlist, in: library)
                    page(
                        name: playlist.name,
                        items: tracks.map(Optional.some),
                        titles: tracks.map(\.title),
                        place: library.name(of: playlist.source),
                        localID: nil
                    )
                } else {
                    missing
                }
            }
        }
        .sheet(item: $editing) { track in
            MetadataEditor(track: track, onSaved: { library.rescanFolder() }, onClose: { editing = nil })
        }
    }

    private var missing: some View {
        ContentUnavailableView(
            "Playlist Not Available",
            systemImage: "music.note.list",
            description: Text("It may have been deleted, or its server is not loaded yet.")
        )
    }

    // MARK: - Page

    private func page(name: String, items: [LibraryTrack?], titles: [String], place: String, localID: UUID?) -> some View {
        let playable = items.compactMap { $0 }
        let duration = playable.compactMap(\.duration).reduce(0, +)

        return List {
            header(name: name, playable: playable, count: items.count, duration: duration, place: place, localID: localID)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .padding(.bottom, 14)

            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                Group {
                    if let track = item {
                        TrackRow(
                            track: track,
                            subtitle: "\(track.artist) — \(track.album)",
                            isCurrent: model.currentTrack?.id == track.id,
                            isPlaying: model.isPlaying,
                            onPlay: { play(playable, from: items, at: index) },
                            onFindLyrics: { library.findLyrics(for: [track]) },
                            onEdit: { editing = track },
                            onRemoveFromPlaylist: localID.map { id in { playlists.remove(at: [index], from: id) } }
                        )
                    } else {
                        HStack(spacing: 12) {
                            Image(systemName: "exclamationmark.circle")
                                .frame(width: 24)
                            Text(titles.indices.contains(index) ? titles[index] : "Unknown song")
                                .lineLimit(1)
                            Spacer()
                            Text("Not available")
                                .font(.system(size: 11))
                        }
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                        .padding(.vertical, 7)
                        .padding(.horizontal, 8)
                        .help("The file has moved, or its server is not loaded and the song is not downloaded")
                        .contextMenu {
                            if let localID {
                                Button("Remove from Playlist", role: .destructive) {
                                    playlists.remove(at: [index], from: localID)
                                }
                            }
                        }
                    }
                }
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
            }
            .onMove(perform: localID.map { id in { source, destination in
                playlists.move(from: source, to: destination, in: id)
            } })
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .navigationTitle(name)
        .alert("Rename Playlist", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Rename") {
                if let localID { playlists.rename(localID, to: newName) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete “\(name)”?", isPresented: $confirmingDelete) {
            Button("Delete Playlist", role: .destructive) {
                if let localID {
                    playlists.delete(localID)
                    onDeleted()
                }
            }
        } message: {
            Text("The songs stay in your library.")
        }
    }

    private func header(name: String, playable: [LibraryTrack], count: Int, duration: TimeInterval, place: String, localID: UUID?) -> some View {
        HStack(alignment: .bottom, spacing: 28) {
            PlaylistMosaic(tracks: playable, library: library)
                .frame(width: 220, height: 220)
                .shadow(color: .black.opacity(0.3), radius: 18, y: 10)

            VStack(alignment: .leading, spacing: 7) {
                Text("PLAYLIST")
                    .font(.system(size: 11, weight: .bold))
                    .kerning(0.8)
                    .foregroundStyle(.secondary)
                Text(name)
                    .font(.system(size: 32, weight: .bold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                Text([
                    AlbumDetail.songs(count),
                    duration > 0 ? AlbumDetail.length(duration) : nil,
                    place,
                ].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    Button {
                        model.play(playable, startingAt: 0)
                    } label: {
                        Label("Play", systemImage: "play.fill").frame(width: 86)
                    }
                    Button {
                        model.isShuffling = true
                        model.play(playable, startingAt: Int.random(in: playable.indices))
                    } label: {
                        Label("Shuffle", systemImage: "shuffle").frame(width: 86)
                    }
                    if localID != nil {
                        Menu {
                            Button("Rename…") {
                                newName = name
                                renaming = true
                            }
                            Button("Delete Playlist…", role: .destructive) { confirmingDelete = true }
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                        .menuIndicator(.hidden)
                        .fixedSize()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Palette.red)
                .controlSize(.large)
                .disabled(playable.isEmpty)
                .padding(.top, 10)

                if localID != nil, count > 1 {
                    Text("Drag songs to reorder them.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.top, 24)
    }

    /// From the song clicked, with the rest of the playlist behind it.
    private func play(_ playable: [LibraryTrack], from items: [LibraryTrack?], at index: Int) {
        let position = items.prefix(index).compactMap { $0 }.count
        guard playable.indices.contains(position) else { return }
        model.play(playable, startingAt: position)
    }
}

/// A playlist's cover: the sleeves of its first four records, in a square,
/// the way every music app draws one.
struct PlaylistMosaic: View {
    let tracks: [LibraryTrack]
    let library: LibraryStore

    var body: some View {
        let covers = albums
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Palette.brand)
            .overlay {
                if covers.count >= 4 {
                    Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                        GridRow {
                            AlbumArt(id: covers[0].id, data: covers[0].cover, corner: 0)
                            AlbumArt(id: covers[1].id, data: covers[1].cover, corner: 0)
                        }
                        GridRow {
                            AlbumArt(id: covers[2].id, data: covers[2].cover, corner: 0)
                            AlbumArt(id: covers[3].id, data: covers[3].cover, corner: 0)
                        }
                    }
                } else if let first = covers.first {
                    AlbumArt(id: first.id, data: first.cover, corner: 0)
                } else {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 64, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// The first four different records with a cover.
    private var albums: [LibraryAlbum] {
        var found: [LibraryAlbum] = []
        for track in tracks {
            guard found.count < 4 else { break }
            guard let album = library.albums.first(where: { $0.title == track.album && $0.tracks.contains { $0.id == track.id } }),
                  album.cover != nil, !found.contains(where: { $0.id == album.id })
            else { continue }
            found.append(album)
        }
        return found
    }
}
