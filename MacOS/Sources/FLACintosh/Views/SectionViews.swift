import SwiftUI

// MARK: - View modes and sorts

/// How a section lays its contents out.
enum ViewMode: String, CaseIterable, Identifiable {
    case grid, list, table

    var id: Self { self }

    var title: String {
        switch self {
        case .grid: "Grid"
        case .list: "List"
        case .table: "Table"
        }
    }

    var symbol: String {
        switch self {
        case .grid: "square.grid.2x2"
        case .list: "list.bullet"
        case .table: "tablecells"
        }
    }
}

/// A way to order a section, and the words for its two directions — "A to
/// Z" means nothing for a date, "Newest First" nothing for a name.
protocol SectionSort: RawRepresentable, CaseIterable, Identifiable, Hashable
where RawValue == String, AllCases: RandomAccessCollection {
    var title: String { get }
    /// The direction picked when this sort is chosen: dates and counts read
    /// best biggest first, names from A.
    var defaultAscending: Bool { get }
    var ascendingLabel: String { get }
    var descendingLabel: String { get }
}

enum AlbumSort: String, SectionSort {
    case title, artist, year, added, source

    var id: Self { self }

    var title: String {
        switch self {
        case .title: "Title"
        case .artist: "Artist"
        case .year: "Year"
        case .added: "Date Added"
        case .source: "Source"
        }
    }

    var defaultAscending: Bool { !(self == .year || self == .added) }

    var ascendingLabel: String {
        switch self {
        case .title, .artist, .source: "A to Z"
        case .year, .added: "Oldest First"
        }
    }

    var descendingLabel: String {
        switch self {
        case .title, .artist, .source: "Z to A"
        case .year, .added: "Newest First"
        }
    }

    func apply(
        _ albums: [LibraryAlbum],
        ascending: Bool,
        sourceName: (LibrarySource) -> String
    ) -> [LibraryAlbum] {
        let byTitle: (LibraryAlbum, LibraryAlbum) -> ComparisonResult = {
            Sorting.text($0.title, $1.title)
        }
        switch self {
        case .title:
            return Sorting.ordered(albums, ascending: ascending, by: byTitle) {
                Sorting.text($0.artist, $1.artist)
            }
        case .artist:
            return Sorting.ordered(albums, ascending: ascending, by: {
                Sorting.text($0.artist, $1.artist)
            }, then: byTitle)
        case .year:
            // Records without a year go last either way: at the top of
            // "Newest First" they would bury every dated one.
            let dated = albums.filter { Self.year(of: $0) != nil }
            let undated = albums.filter { Self.year(of: $0) == nil }
            return Sorting.ordered(dated, ascending: ascending, by: {
                Sorting.compare(Self.year(of: $0) ?? 0, Self.year(of: $1) ?? 0)
            }, then: byTitle)
                + Sorting.ordered(undated, ascending: true, by: byTitle, then: byTitle)
        case .added:
            return Sorting.ordered(albums, ascending: ascending, by: {
                Sorting.compare($0.addedAt, $1.addedAt)
            }, then: byTitle)
        case .source:
            return Sorting.ordered(albums, ascending: ascending, by: {
                Sorting.text(sourceName($0.source), sourceName($1.source))
            }, then: byTitle)
        }
    }

    private static func year(of album: LibraryAlbum) -> Int? {
        album.year.flatMap { Int($0.prefix(4)) }
    }
}

enum SongSort: String, SectionSort {
    case title, artist, album, duration, source

    var id: Self { self }

    var title: String {
        switch self {
        case .title: "Title"
        case .artist: "Artist"
        case .album: "Album"
        case .duration: "Duration"
        case .source: "Source"
        }
    }

    var defaultAscending: Bool { true }

    var ascendingLabel: String { self == .duration ? "Shortest First" : "A to Z" }
    var descendingLabel: String { self == .duration ? "Longest First" : "Z to A" }

    func apply(
        _ songs: [LibraryTrack],
        ascending: Bool,
        sourceName: (LibrarySource) -> String
    ) -> [LibraryTrack] {
        // Within an artist or album, the record's own running order — the
        // alternative is an album listed alphabetically by song.
        let byRecord: (LibraryTrack, LibraryTrack) -> ComparisonResult = {
            let album = Sorting.text($0.album, $1.album)
            if album != .orderedSame { return album }
            return Sorting.compare(
                [$0.discNumber ?? 1, $0.trackNumber ?? 0],
                [$1.discNumber ?? 1, $1.trackNumber ?? 0]
            )
        }
        let byTitle: (LibraryTrack, LibraryTrack) -> ComparisonResult = {
            Sorting.text($0.title, $1.title)
        }
        switch self {
        case .title:
            return Sorting.ordered(songs, ascending: ascending, by: byTitle) {
                Sorting.text($0.artist, $1.artist)
            }
        case .artist:
            return Sorting.ordered(songs, ascending: ascending, by: {
                Sorting.text($0.artist, $1.artist)
            }, then: byRecord)
        case .album:
            return Sorting.ordered(songs, ascending: ascending, by: {
                Sorting.text($0.album, $1.album)
            }, then: byRecord)
        case .duration:
            return Sorting.ordered(songs, ascending: ascending, by: {
                Sorting.compare($0.duration ?? 0, $1.duration ?? 0)
            }, then: byTitle)
        case .source:
            return Sorting.ordered(songs, ascending: ascending, by: {
                Sorting.text(sourceName($0.source), sourceName($1.source))
            }, then: byTitle)
        }
    }
}

enum ArtistSort: String, SectionSort {
    case name, albums, songs

    var id: Self { self }

    var title: String {
        switch self {
        case .name: "Name"
        case .albums: "Number of Albums"
        case .songs: "Number of Songs"
        }
    }

    var defaultAscending: Bool { self == .name }
    var ascendingLabel: String { self == .name ? "A to Z" : "Fewest First" }
    var descendingLabel: String { self == .name ? "Z to A" : "Most First" }

    func apply(_ artists: [LibraryArtist], ascending: Bool) -> [LibraryArtist] {
        let byName: (LibraryArtist, LibraryArtist) -> ComparisonResult = {
            Sorting.text($0.name, $1.name)
        }
        switch self {
        case .name:
            return Sorting.ordered(artists, ascending: ascending, by: byName, then: byName)
        case .albums:
            return Sorting.ordered(artists, ascending: ascending, by: {
                Sorting.compare($0.albums.count, $1.albums.count)
            }, then: byName)
        case .songs:
            return Sorting.ordered(artists, ascending: ascending, by: {
                Sorting.compare($0.trackCount, $1.trackCount)
            }, then: byName)
        }
    }
}

enum Sorting {
    static func text(_ a: String, _ b: String) -> ComparisonResult {
        a.localizedStandardCompare(b)
    }

    static func compare<Value: Comparable>(_ a: Value, _ b: Value) -> ComparisonResult {
        a < b ? .orderedAscending : (a > b ? .orderedDescending : .orderedSame)
    }

    static func compare(_ a: [Int], _ b: [Int]) -> ComparisonResult {
        a.lexicographicallyPrecedes(b) ? .orderedAscending : (a == b ? .orderedSame : .orderedDescending)
    }

    /// Sorted by `primary` in the chosen direction. Ties go to `tiebreak`,
    /// always ascending: reversing a list by year should not also put each
    /// year's records Z to A.
    static func ordered<Item>(
        _ items: [Item],
        ascending: Bool,
        by primary: (Item, Item) -> ComparisonResult,
        then tiebreak: (Item, Item) -> ComparisonResult
    ) -> [Item] {
        items.sorted { a, b in
            let first = primary(a, b)
            if first != .orderedSame {
                return ascending ? first == .orderedAscending : first == .orderedDescending
            }
            return tiebreak(a, b) == .orderedAscending
        }
    }
}

// MARK: - Toolbar

/// The view switch and the sort menu, in the window toolbar beside search.
struct SectionToolbar<Sort: SectionSort>: ToolbarContent {
    let modes: [ViewMode]
    @Binding var mode: ViewMode
    @Binding var sort: Sort
    @Binding var ascending: Bool

    var body: some ToolbarContent {
        #if os(iOS)
        // Two items of their own, and the view choice a menu: grouped, the
        // segmented picker's capsule was drawn over the sort button's, one
        // outline inside the other.
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Picker("View", selection: $mode) {
                    ForEach(modes) { mode in
                        Label(mode.title, systemImage: mode.symbol).tag(mode)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: mode.symbol)
            }
        }
        ToolbarItem(placement: .primaryAction) { sortMenu }
        #else
        ToolbarItemGroup(placement: .primaryAction) {
            Picker("View", selection: $mode) {
                ForEach(modes) { mode in
                    Image(systemName: mode.symbol)
                        .help(mode.title)
                        .tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help("View as")

            sortMenu
        }
        #endif
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort By", selection: $sort) {
                ForEach(Array(Sort.allCases)) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.inline)

            Picker("Order", selection: $ascending) {
                Text(sort.ascendingLabel).tag(true)
                Text(sort.descendingLabel).tag(false)
            }
            .pickerStyle(.inline)
        } label: {
            Label("Sort: \(sort.title)", systemImage: "arrow.up.arrow.down")
        }
        .help("Sorted by \(sort.title.lowercased()), \((ascending ? sort.ascendingLabel : sort.descendingLabel).lowercased())")
    }
}

// MARK: - Albums

/// Albums or Recently Added: the same records, each section with its own
/// remembered view and order.
struct AlbumsSection: View {
    let albums: [LibraryAlbum]
    let model: PlaybackModel
    let library: LibraryStore

    @AppStorage private var mode: ViewMode
    @AppStorage private var sort: AlbumSort
    @AppStorage private var ascending: Bool

    init(
        albums: [LibraryAlbum],
        model: PlaybackModel,
        library: LibraryStore,
        key: String,
        defaultSort: AlbumSort
    ) {
        self.albums = albums
        self.model = model
        self.library = library
        _mode = AppStorage(wrappedValue: .grid, "view.\(key).mode")
        _sort = AppStorage(wrappedValue: defaultSort, "view.\(key).sort")
        _ascending = AppStorage(wrappedValue: defaultSort.defaultAscending, "view.\(key).ascending")
    }

    var body: some View {
        let sorted = sort.apply(albums, ascending: ascending, sourceName: library.name(of:))

        Group {
            switch mode {
            case .grid:
                AlbumGrid(albums: sorted) { model.play($0.tracks, startingAt: 0) }
            case .list, .table:
                AlbumList(albums: sorted, model: model)
            }
        }
        .toolbar {
            SectionToolbar(modes: [.list, .grid], mode: $mode, sort: $sort, ascending: $ascending)
        }
        .onChange(of: sort) { _, chosen in ascending = chosen.defaultAscending }
    }
}

struct AlbumList: View {
    let albums: [LibraryAlbum]
    let model: PlaybackModel

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(albums) { album in
                    NavigationLink(value: album) {
                        AlbumListRow(album: album) { model.play(album.tracks, startingAt: 0) }
                    }
                    .buttonStyle(.plain)
                    Divider().padding(.leading, 76)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
    }
}

private struct AlbumListRow: View {
    let album: LibraryAlbum
    let onPlay: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            AlbumArt(id: album.id, data: album.cover, corner: 4)
                .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 2) {
                Text(album.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(album.artist)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            SourceBadge(source: album.source)

            Group {
                Text(album.year ?? "")
                    .frame(width: 44, alignment: .trailing)
                Text("\(album.tracks.count) songs")
                    .frame(width: 70, alignment: .trailing)
                Text(AlbumDetail.length(album.duration))
                    .frame(width: 84, alignment: .trailing)
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .monospacedDigit()

            Button(action: onPlay) {
                Image(systemName: "play.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.red)
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0)
            .help("Play")
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(hovering ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

// MARK: - Artists

struct ArtistsSection: View {
    let artists: [LibraryArtist]
    let model: PlaybackModel

    @AppStorage("view.artists.mode") private var mode: ViewMode = .list
    @AppStorage("view.artists.sort") private var sort: ArtistSort = .name
    @AppStorage("view.artists.ascending") private var ascending = true

    var body: some View {
        let sorted = sort.apply(artists, ascending: ascending)

        Group {
            switch mode {
            case .grid:
                ArtistGrid(artists: sorted)
            case .list, .table:
                ArtistsList(artists: sorted) { model.play($0.tracks, startingAt: 0) }
            }
        }
        .toolbar {
            SectionToolbar(modes: [.list, .grid], mode: $mode, sort: $sort, ascending: $ascending)
        }
        .onChange(of: sort) { _, chosen in ascending = chosen.defaultAscending }
    }
}

struct ArtistGrid: View {
    let artists: [LibraryArtist]

    private let columns = [GridItem(.adaptive(minimum: 140, maximum: 180), spacing: 24)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 24) {
                ForEach(artists) { artist in
                    NavigationLink(value: artist) {
                        VStack(spacing: 8) {
                            let sleeve = artist.albums.first { $0.cover != nil } ?? artist.albums.first
                            AlbumArt(id: sleeve?.id ?? artist.id, data: sleeve?.cover)
                                .aspectRatio(1, contentMode: .fit)
                                .clipShape(Circle())
                                .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
                            Text(artist.name)
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1)
                            Text("\(artist.albums.count) albums · \(artist.trackCount) songs")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(24)
        }
    }
}

/// One artist: their records, and a way to play all of them.
struct ArtistDetail: View {
    let artist: LibraryArtist
    let model: PlaybackModel

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 196), spacing: 24)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(artist.name)
                        .font(.system(size: 26, weight: .bold))
                    Text("\(artist.albums.count) albums · \(artist.trackCount) songs")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 10) {
                        Button {
                            model.isShuffling = false
                            model.play(tracks, startingAt: 0)
                        } label: {
                            Label("Play", systemImage: "play.fill").lineLimit(1).frame(minWidth: 76)
                        }
                        Button {
                            model.isShuffling = true
                            model.play(tracks, startingAt: Int.random(in: tracks.indices))
                        } label: {
                            Label("Shuffle", systemImage: "shuffle").lineLimit(1).frame(minWidth: 76)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.red)
                    .controlSize(.large)
                    .disabled(tracks.isEmpty)
                    .padding(.top, 8)
                }

                LazyVGrid(columns: columns, alignment: .leading, spacing: 24) {
                    ForEach(artist.albums) { album in
                        NavigationLink(value: album) {
                            AlbumTile(album: album) { model.play(album.tracks, startingAt: 0) }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(28)
        }
        .navigationTitle(artist.name)
    }

    private var tracks: [LibraryTrack] {
        artist.albums.flatMap(\.tracks)
    }
}

// MARK: - Songs

struct SongsSection: View {
    let songs: [LibraryTrack]
    let model: PlaybackModel
    let library: LibraryStore

    @AppStorage("view.songs.mode") private var mode: ViewMode = .list
    @AppStorage("view.songs.sort") private var sort: SongSort = .title
    @AppStorage("view.songs.ascending") private var ascending = true
    /// Compact on a phone; never on the Mac, where it is nil.
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let sorted = sort.apply(songs, ascending: ascending, sourceName: library.name(of:))
        let phone = sizeClass == .compact

        Group {
            switch mode {
            case .table:
                // A table is columns, and a phone has room for one: the
                // title, and nothing else — which made the two views look
                // the same. There the second view is the dense list instead.
                if phone {
                    SongsList(songs: sorted, model: model, library: library)
                } else {
                    SongsTable(songs: sorted, model: model, library: library)
                }
            case .list, .grid:
                // On a phone the list leads with the covers.
                SongsList(songs: sorted, model: model, library: library, showsCovers: phone)
            }
        }
        .toolbar {
            SectionToolbar(modes: [.list, .table], mode: $mode, sort: $sort, ascending: $ascending)
        }
        .onChange(of: sort) { _, chosen in ascending = chosen.defaultAscending }
    }
}

/// Songs as columns: denser than the list, for scanning a big library.
struct SongsTable: View {
    let songs: [LibraryTrack]
    let model: PlaybackModel
    let library: LibraryStore

    @State private var selection: Set<LibraryTrack.ID> = []

    var body: some View {
        Table(songs, selection: $selection) {
            TableColumn("Title") { track in
                HStack(spacing: 6) {
                    if model.currentTrack?.id == track.id {
                        Image(systemName: model.isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Palette.red)
                    }
                    Text(track.title)
                        .lineLimit(1)
                    if track.hasLyrics {
                        Image(systemName: "quote.bubble")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .help("Has timed lyrics")
                    }
                }
            }
            .width(min: 160, ideal: 260)

            TableColumn("Artist", value: \.artist)
                .width(min: 100, ideal: 160)

            TableColumn("Album", value: \.album)
                .width(min: 100, ideal: 180)

            TableColumn("Time") { track in
                Text(TrackRow.clock(track.duration))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(56)

            TableColumn("Source") { track in
                SourceBadge(source: track.source)
            }
            .width(min: 70, ideal: 110)
        }
        .contextMenu(forSelectionType: LibraryTrack.ID.self) { ids in
            Button("Play") { play(ids) }
            AddToPlaylistMenu(tracks: songs.filter { ids.contains($0.id) })
            let chosen = songs.filter { ids.contains($0.id) && !$0.hasLyrics }
            if !chosen.isEmpty {
                Button("Find Lyrics") { library.findLyrics(for: chosen) }
            }
        } primaryAction: { ids in
            play(ids)
        }
    }

    /// From the first chosen song, with the rest of the list queued behind it.
    private func play(_ ids: Set<LibraryTrack.ID>) {
        guard let first = songs.firstIndex(where: { ids.contains($0.id) }) else { return }
        model.play(songs, startingAt: first)
    }
}
