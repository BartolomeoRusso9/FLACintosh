import PhotosUI
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
    /// Compact on a phone; never on the Mac, where it is nil.
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var editingDetails = false
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
                        place: Self.thisDevice,
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
            #if os(iOS)
            // With Edit, on a phone: the handles to reorder, and the red
            // minus to take a song out.
            .onDelete(perform: localID.map { id in { offsets in
                playlists.remove(at: offsets, from: id)
            } })
            #endif
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .navigationTitle(name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if localID != nil {
                ToolbarItem(placement: .primaryAction) { EditButton() }
            }
        }
        #endif
        .sheet(isPresented: $editingDetails) {
            if let localID, let playlist = playlists.playlist(localID) {
                PlaylistEditor(playlist: playlist, store: playlists) { editingDetails = false }
            }
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

    /// Where a playlist made here lives, in the words of the device.
    private static var thisDevice: String {
        #if os(macOS)
        "On this Mac"
        #else
        "On this device"
        #endif
    }

    /// The mosaic beside the details in a window; above them on a phone.
    @ViewBuilder
    private func header(name: String, playable: [LibraryTrack], count: Int, duration: TimeInterval, place: String, localID: UUID?) -> some View {
        Group {
            if sizeClass == .compact {
                VStack(alignment: .leading, spacing: 20) {
                    PlaylistCover(localID: localID, tracks: playable, library: library)
                        .frame(width: 240, height: 240)
                        .shadow(color: .black.opacity(0.3), radius: 18, y: 10)
                        .frame(maxWidth: .infinity)
                    headerInfo(name: name, playable: playable, count: count, duration: duration, place: place, localID: localID)
                }
            } else {
                HStack(alignment: .bottom, spacing: 28) {
                    PlaylistCover(localID: localID, tracks: playable, library: library)
                        .frame(width: 220, height: 220)
                        .shadow(color: .black.opacity(0.3), radius: 18, y: 10)
                    headerInfo(name: name, playable: playable, count: count, duration: duration, place: place, localID: localID)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 24)
    }

    private func headerInfo(name: String, playable: [LibraryTrack], count: Int, duration: TimeInterval, place: String, localID: UUID?) -> some View {
            VStack(alignment: .leading, spacing: 7) {
                Text("PLAYLIST")
                    .font(.system(size: 11, weight: .bold))
                    .kerning(0.8)
                    .foregroundStyle(.secondary)
                Text(name)
                    .font(.system(size: 32, weight: .bold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                if let note = localID.flatMap({ playlists.playlist($0)?.note }) {
                    Text(note)
                        .font(.list(13))
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                }
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
                        Label("Play", systemImage: "play.fill").lineLimit(1).frame(minWidth: 86)
                    }
                    Button {
                        model.isShuffling = true
                        model.play(playable, startingAt: Int.random(in: playable.indices))
                    } label: {
                        Label("Shuffle", systemImage: "shuffle").lineLimit(1).frame(minWidth: 86)
                    }
                    if localID != nil {
                        Menu {
                            Button("Edit Details…") { editingDetails = true }
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

                // Dragging rows needs no mode on a Mac; on a phone a list only
                // reorders in edit mode, so the hint would promise too much.
                #if os(macOS)
                if localID != nil, count > 1 {
                    Text("Drag songs to reorder them.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 4)
                }
                #endif
            }
    }

    /// From the song clicked, with the rest of the playlist behind it.
    private func play(_ playable: [LibraryTrack], from items: [LibraryTrack?], at index: Int) {
        let position = items.prefix(index).compactMap { $0 }.count
        guard playable.indices.contains(position) else { return }
        model.play(playable, startingAt: position)
    }
}

/// A playlist's picture: the one chosen for it if there is one, and the
/// mosaic of its songs' sleeves if not.
private struct PlaylistCover: View {
    let localID: UUID?
    let tracks: [LibraryTrack]
    let library: LibraryStore

    @Environment(PlaylistStore.self) private var playlists
    @State private var image: PlatformImage?

    var body: some View {
        let file = localID.flatMap { playlists.playlist($0)?.coverFile }
        Group {
            if let image, file != nil {
                // Filled into whatever square the page gives it, and cut at
                // the corners, so a wide photo does not spill out of it.
                Color.clear
                    .overlay { Image(platformImage: image).resizable().scaledToFill() }
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                PlaylistMosaic(tracks: tracks, library: library)
            }
        }
        .task(id: file) {
            guard let file, let localID, let playlist = playlists.playlist(localID),
                  let data = playlists.coverData(of: playlist)
            else {
                image = nil
                return
            }
            image = await CoverCache.shared.load(id: "playlist-\(file)", data: data, maxPixel: 720)
        }
    }
}

/// Name, description and picture of a playlist of your own.
struct PlaylistEditor: View {
    let playlist: PlaylistStore.Playlist
    let store: PlaylistStore
    let onDone: () -> Void

    @State private var name: String
    @State private var note: String
    @State private var picked: PhotosPickerItem?
    /// A picture chosen here and not saved yet.
    @State private var newImageData: Data?
    @State private var newImage: PlatformImage?
    @State private var removingPicture = false

    init(playlist: PlaylistStore.Playlist, store: PlaylistStore, onDone: @escaping () -> Void) {
        self.playlist = playlist
        self.store = store
        self.onDone = onDone
        _name = State(initialValue: playlist.name)
        _note = State(initialValue: playlist.note ?? "")
    }

    private var hasPicture: Bool {
        newImage != nil || (playlist.coverFile != nil && !removingPicture)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Text("Edit Playlist")
                    .font(.headline)

                picture
                    .frame(width: 200, height: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .shadow(color: .black.opacity(0.25), radius: 10, y: 5)

                HStack(spacing: 14) {
                    PhotosPicker(selection: $picked, matching: .images) {
                        Label("Choose Photo…", systemImage: "photo")
                    }
                    if hasPicture {
                        Button(role: .destructive) {
                            newImage = nil
                            newImageData = nil
                            picked = nil
                            removingPicture = true
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Name").font(.caption).foregroundStyle(.secondary)
                    TextField("Name", text: $name)
                        .textFieldStyle(.roundedBorder)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Description").font(.caption).foregroundStyle(.secondary)
                    TextField("What is this playlist for?", text: $note, axis: .vertical)
                        .lineLimit(3 ... 6)
                        .textFieldStyle(.roundedBorder)
                }

                HStack {
                    Button("Cancel", action: onDone)
                    Spacer()
                    Button("Save", action: save)
                        .buttonStyle(.borderedProminent)
                        .tint(Palette.red)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.top, 6)
            }
            .padding(22)
        }
        #if os(macOS)
        .frame(width: 400, height: 560)
        #endif
        .onChange(of: picked) { _, item in
            guard let item else { return }
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self),
                      let image = PlatformImage(data: data)
                else { return }
                newImageData = data
                newImage = image
                removingPicture = false
            }
        }
    }

    @ViewBuilder
    private var picture: some View {
        if let newImage {
            Color.clear.overlay { Image(platformImage: newImage).resizable().scaledToFill() }
        } else if !removingPicture, let data = store.coverData(of: playlist), let image = PlatformImage(data: data) {
            Color.clear.overlay { Image(platformImage: image).resizable().scaledToFill() }
        } else {
            ZStack {
                Rectangle().fill(Palette.brand)
                Image(systemName: "music.note.list")
                    .font(.system(size: 54, weight: .light))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
    }

    private func save() {
        store.setDetails(playlist.id, name: name, note: note)
        if let newImageData {
            store.setCover(playlist.id, imageData: newImageData)
        } else if removingPicture {
            store.setCover(playlist.id, imageData: nil)
        }
        onDone()
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
