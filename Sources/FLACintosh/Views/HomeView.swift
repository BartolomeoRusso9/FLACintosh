import SwiftUI

/// Home: every section at a glance, and the whole library one click from
/// playing — in order or shuffled.
///
/// The shelves below each have a "See All" that goes to the full section;
/// this page is the overview, not a replacement for them.
struct HomeView: View {
    let library: LibraryStore
    let model: PlaybackModel
    @Binding var section: LibrarySection
    /// The toolbar's search field. Home's rows are filtered by it like any
    /// section; left unused, typing in "Find in Home" did nothing.
    var search = ""

    private func matches(_ fields: String...) -> Bool {
        search.isEmpty || fields.contains { $0.localizedCaseInsensitiveContains(search) }
    }

    private var matchingAlbums: [LibraryAlbum] {
        library.albums.filter { matches($0.title, $0.artist) }
    }

    private var matchingArtists: [LibraryArtist] {
        library.artists.filter { matches($0.name) }
    }

    private var matchingSongs: [LibraryTrack] {
        library.songs.filter { matches($0.title, $0.artist, $0.album) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 34) {
                header
                KeychainNotice(library: library)
                sources

                if library.tracks.isEmpty, !library.isScanning {
                    nothing
                } else {
                    let albums = matchingAlbums
                    albumRow(
                        "Recently Added",
                        albums: Array(albums.sorted { $0.addedAt > $1.addedAt }.prefix(20)),
                        seeAll: .recentlyAdded
                    )
                    albumRow("Albums", albums: Array(albums.prefix(20)), seeAll: .albums)
                    artistsRow
                    songsBlock
                }
            }
            .padding(28)
        }
        .navigationTitle("Home")
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Home")
                .font(.system(size: 30, weight: .bold))

            Text("\(library.tracks.count) songs · \(library.albums.count) albums · \(library.visibleSources.count) of \(library.sources.count) sources shown")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button { playAll(shuffled: false) } label: {
                    Label("Play All", systemImage: "play.fill")
                        .frame(width: 110)
                }
                Button { playAll(shuffled: true) } label: {
                    Label("Shuffle All", systemImage: "shuffle")
                        .frame(width: 110)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Palette.red)
            .controlSize(.large)
            .disabled(library.tracks.isEmpty)
            .padding(.top, 4)

            if library.isScanning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Still reading — songs join as each source finishes.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Everything shown, from every visible source. Shuffle starts on a
    /// random track as well as shuffling the rest: turning shuffle on and
    /// then hearing the first song of the first album is not shuffle.
    private func playAll(shuffled: Bool) {
        let tracks = library.inOrder
        guard !tracks.isEmpty else { return }
        model.isShuffling = shuffled
        model.play(tracks, startingAt: shuffled ? Int.random(in: tracks.indices) : 0)
    }

    // MARK: - Sources

    private var sources: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sources")
                .font(.system(size: 20, weight: .bold))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(library.sources, id: \.self) { source in
                        SourceToggle(library: library, source: source)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var nothing: some View {
        Text(library.visibleSources.isEmpty
            ? "Every source is hidden. Show one above to fill Home again."
            : "Nothing to play yet. Choose a folder or add a server from the sidebar.")
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
    }

    // MARK: - Rows

    private func rowHeader(_ title: String, seeAll: LibrarySection) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 20, weight: .bold))
            Spacer()
            Button("See All") { section = seeAll }
                .buttonStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Palette.red)
        }
    }

    @ViewBuilder
    private func albumRow(_ title: String, albums: [LibraryAlbum], seeAll: LibrarySection) -> some View {
        if !albums.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                rowHeader(title, seeAll: seeAll)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 20) {
                        ForEach(albums) { album in
                            NavigationLink(value: album) {
                                AlbumTile(album: album) { model.play(album.tracks, startingAt: 0) }
                                    .frame(width: 160)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    @ViewBuilder
    private var artistsRow: some View {
        let artists = Array(matchingArtists.prefix(20))
        if !artists.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                rowHeader("Artists", seeAll: .artists)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 18) {
                        ForEach(artists) { artist in
                            Button { section = .artists } label: {
                                VStack(spacing: 8) {
                                    let sleeve = artist.albums.first { $0.cover != nil } ?? artist.albums.first
                                    AlbumArt(id: sleeve?.id ?? artist.id, data: sleeve?.cover)
                                        .frame(width: 110, height: 110)
                                        .clipShape(Circle())
                                    Text(artist.name)
                                        .font(.system(size: 13, weight: .medium))
                                        .lineLimit(1)
                                    Text("\(artist.albums.count) albums")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                                .frame(width: 124)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    @ViewBuilder
    private var songsBlock: some View {
        let songs = matchingSongs
        if !songs.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                rowHeader("Songs", seeAll: .songs)
                VStack(spacing: 0) {
                    ForEach(Array(songs.prefix(10).enumerated()), id: \.element.id) { index, track in
                        TrackRow(
                            track: track,
                            subtitle: "\(track.artist) — \(track.album)",
                            isCurrent: model.currentTrack?.id == track.id,
                            isPlaying: model.isPlaying,
                            onPlay: { model.play(songs, startingAt: index) },
                            onFindLyrics: { library.findLyrics(for: [track]) }
                        )
                        Divider().padding(.leading, 44)
                    }
                }
            }
        }
    }
}

/// A source on Home: what it is, how much it holds, and whether it is shown.
struct SourceToggle: View {
    let library: LibraryStore
    let source: LibrarySource

    var body: some View {
        let hidden = library.isHidden(source)
        let state = library.state(of: source)

        Button {
            library.setHidden(source, !hidden)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: library.symbol(of: source))
                VStack(alignment: .leading, spacing: 1) {
                    Text(library.name(of: source))
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    Text(detail(hidden: hidden, state: state))
                        .font(.system(size: 10))
                        .foregroundStyle(state.error == nil ? Color.secondary : Color.red)
                        .lineLimit(1)
                }
                Image(systemName: hidden ? "eye.slash" : "eye")
                    .foregroundStyle(hidden ? Color.secondary : Palette.red)
                    .padding(.leading, 4)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(hidden ? 0.03 : 0.07), in: RoundedRectangle(cornerRadius: 10))
            .opacity(hidden ? 0.55 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .help(hidden ? "Hidden — click to show its songs again" : "Shown — click to hide its songs everywhere")
    }

    private func detail(hidden: Bool, state: LibraryStore.SourceState) -> String {
        if hidden { return "Hidden" }
        if state.needsKeychainAccess { return "Needs Keychain permission" }
        if let error = state.error { return error }
        if state.isScanning {
            return state.progress.total == 0 ? "Loading…" : "Reading \(state.progress.done) of \(state.progress.total)"
        }
        return "\(state.tracks.count) songs"
    }
}
