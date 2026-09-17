import AppKit
import SwiftUI

/// The shelves in the sidebar. Deliberately the ones that mean something for
/// a folder of files: no Radio, no store, nothing that needs an account.
enum LibrarySection: Identifiable, Hashable {
    case home
    case recentlyAdded, artists, albums, songs
    case download
    case recap

    var id: String {
        switch self {
        case .home: "home"
        case .recentlyAdded: "recentlyAdded"
        case .artists: "artists"
        case .albums: "albums"
        case .songs: "songs"
        case .download: "download"
        case .recap: "recap"
        }
    }

    /// The shelves; `download` is not one of them.
    static var shelves: [LibrarySection] { [.home, .recentlyAdded, .artists, .albums, .songs] }

    var title: String {
        switch self {
        case .home: "Home"
        case .recentlyAdded: "Recently Added"
        case .artists: "Artists"
        case .albums: "Albums"
        case .songs: "Songs"
        case .download: "Download"
        case .recap: "Recap"
        }
    }

    var symbol: String {
        switch self {
        case .home: "house"
        case .recentlyAdded: "clock"
        case .artists: "music.microphone"
        case .albums: "square.stack"
        case .songs: "music.note"
        case .download: "arrow.down.circle"
        case .recap: "chart.bar.xaxis"
        }
    }
}

struct Sidebar: View {
    @Binding var selection: LibrarySection
    let library: LibraryStore
    let onChooseFolder: () -> Void
    let onAddServer: () -> Void

    var body: some View {
        List {
            Section("Library") {
                ForEach(LibrarySection.shelves) { section in
                    row(section)
                }
            }

            Section("Listening") {
                row(.recap)
            }

            Section("Get More") {
                row(.download)
            }

            // A row rather than something pinned to the bottom of the
            // column: the transport bar owns the bottom of the window, and
            // anything parked down there ends up behind it.
            Section("Sources") {
                // Every source is in the library at once; each row shows or
                // hides one, and says how its reading is going.
                ForEach(library.sources, id: \.self) { source in
                    sourceRow(source)
                }

                action("Add Server…", symbol: "plus", perform: onAddServer)
                action("Choose Folder…", symbol: "folder.badge.gearshape", perform: onChooseFolder)
            }
        }
        .listStyle(.sidebar)
        // The list paints an opaque backdrop of its own, which would sit in
        // front of the glass and defeat the whole point.
        .scrollContentBackground(.hidden)
        // The whole column, toolbar strip included. Inset as a rounded panel
        // it read as a grey slab dropped on a white sidebar: the glass only
        // looks like glass when there is no opaque backing left around it.
        .background {
            VisualEffect().ignoresSafeArea()
        }
        .navigationSplitViewColumnWidth(min: 216, ideal: 236, max: 320)
    }

    /// A shelf, carrying its own selection.
    ///
    /// Apple Music's sidebar highlight is the brand red, and a `List` will
    /// not give you that: on macOS the selected-row fill is drawn by AppKit
    /// from the *system* accent colour, which no amount of `.tint` reaches —
    /// that is why the rows here are buttons and the list is never told what
    /// is selected.
    private func row(
        _ section: LibrarySection,
        title: String? = nil,
        symbol: String? = nil
    ) -> some View {
        let isSelected = selection == section
        return Button { selection = section } label: {
            Label(title ?? section.title, systemImage: symbol ?? section.symbol)
                .lineLimit(1)
                .foregroundStyle(isSelected ? Palette.white : Color.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 5)
                .padding(.horizontal, 8)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isSelected ? Palette.red : .clear)
                )
                // The whole row, not just the words: a gap between the label
                // and the row edge that does nothing is a miss waiting to
                // happen.
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
    }

    /// A source: shown or hidden, and how its reading is going.
    ///
    /// Clicking hides or shows its songs everywhere — the shelves, Home,
    /// AutoPlay. It does not pick a source: they are all in the library
    /// together, and this is how one is left out.
    private func sourceRow(_ source: LibrarySource) -> some View {
        let hidden = library.isHidden(source)
        let state = library.state(of: source)

        return Button { library.setHidden(source, !hidden) } label: {
            HStack(spacing: 6) {
                Label(library.name(of: source), systemImage: library.symbol(of: source))
                    .lineLimit(1)
                    .foregroundStyle(hidden ? Color.secondary : Color.primary)

                Spacer(minLength: 4)

                if !hidden {
                    if state.needsKeychainAccess {
                        Image(systemName: "key.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Palette.red)
                            .help("Waiting for permission to use its saved password")
                    } else if state.isScanning {
                        // A count where there is one: files for the folder,
                        // albums for a server, each a request of its own.
                        if state.progress.total == 0 {
                            ProgressView().controlSize(.mini)
                        } else {
                            Text("\(state.progress.done)/\(state.progress.total)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    } else if let error = state.error {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .help(error)
                    }
                }

                Image(systemName: hidden ? "eye.slash" : "eye")
                    .font(.system(size: 11))
                    .foregroundStyle(hidden ? Color.secondary : Palette.red)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
        .help(hidden ? "Hidden — click to show its songs again" : "Click to hide its songs everywhere")
        .contextMenu {
            Button("Reload") { library.reload(source) }
            if case .server(let id) = source, let server = library.server(id) {
                Button("Remove", role: .destructive) { library.remove(server) }
            }
        }
    }

    /// A row that does something instead of going somewhere, so it never
    /// takes the highlight.
    private func action(
        _ title: String,
        symbol: String,
        perform: @escaping () -> Void
    ) -> some View {
        Button(action: perform) {
            Label(title, systemImage: symbol)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 5)
                .padding(.horizontal, 8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
    }
}

// MARK: - Shelves

struct AlbumGrid: View {
    let albums: [LibraryAlbum]
    let onPlay: (LibraryAlbum) -> Void

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 196), spacing: 24)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 24) {
                ForEach(albums) { album in
                    NavigationLink(value: album) {
                        AlbumTile(album: album, onPlay: { onPlay(album) })
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(24)
        }
    }
}

/// Also used by Home's rows.
struct AlbumTile: View {
    let album: LibraryAlbum
    let onPlay: () -> Void

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AlbumArt(id: album.id, data: album.cover)
                .shadow(color: .black.opacity(hovering ? 0.28 : 0.18), radius: hovering ? 12 : 8, y: hovering ? 6 : 3)
                // Lifted a couple of points, not scaled: a scaled sleeve
                // spills over its neighbours in a tight grid.
                .offset(y: hovering ? -2 : 0)
                .overlay(alignment: .bottomLeading) {
                    if hovering {
                        Button(action: onPlay) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(.white)
                                .padding(9)
                                .background(Palette.brand, in: Circle())
                                .shadow(radius: 4)
                        }
                        .buttonStyle(.plain)
                        .padding(10)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                    }
                }
                .overlay(alignment: .topTrailing) {
                    // The reason this app exists, said on the shelf: how
                    // many songs on this record can actually be sung along.
                    if album.lyricCount > 0 {
                        Image(systemName: "quote.bubble.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.white)
                            .padding(5)
                            .background(.black.opacity(0.45), in: Circle())
                            .padding(7)
                            .help("\(album.lyricCount) of \(album.tracks.count) tracks have timed lyrics")
                    }
                }

            Text(album.title)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(2)
                .foregroundStyle(.primary)
            Text(album.artist)
                .font(.system(size: 13))
                .lineLimit(1)
                .foregroundStyle(.secondary)
            SourceBadge(source: album.source)
        }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
    }
}

struct AlbumDetail: View {
    let album: LibraryAlbum
    let model: PlaybackModel
    let library: LibraryStore

    @State private var editing: LibraryTrack?
    /// The sleeve's own main colour, darkened to sit behind text — the band
    /// the page opens with. Read from the cover, not stored with the album:
    /// a small thumbnail makes it in a few milliseconds.
    @State private var tint: Color?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.horizontal, 32)
                    .padding(.top, 30)
                    .padding(.bottom, 28)

                tracks
                    .padding(.horizontal, 24)

                footer
                    .padding(.horizontal, 32)
                    .padding(.top, 22)

                if !moreByArtist.isEmpty {
                    moreShelf
                        .padding(.top, 40)
                }
            }
            .padding(.bottom, 30)
            .background(alignment: .top) {
                // Colour at the top, fading into the window: the record sets
                // the mood of its own page instead of leaving it a grey sheet.
                LinearGradient(
                    colors: [(tint ?? .clear).opacity(0.75), (tint ?? .clear).opacity(0.25), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 460)
                .allowsHitTesting(false)
            }
        }
        .navigationTitle(album.title)
        .task(id: album.id) {
            let cover = album.cover
            let palette = await Task.detached(priority: .utility) {
                cover.flatMap(Artwork.make(from:))?.palette.first
            }.value
            withAnimation(.easeOut(duration: 0.35)) { tint = palette?.asStageTint }
        }
        .sheet(item: $editing) { track in
            MetadataEditor(track: track, onSaved: { library.rescanFolder() }, onClose: { editing = nil })
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .bottom, spacing: 30) {
            AlbumArt(id: album.id, data: album.cover, corner: 12)
                .frame(width: 270, height: 270)
                .shadow(color: .black.opacity(0.35), radius: 22, y: 12)

            VStack(alignment: .leading, spacing: 7) {
                Text(kind)
                    .font(.system(size: 11, weight: .bold))
                    .kerning(0.8)
                    .foregroundStyle(.secondary)

                Text(album.title)
                    .font(.system(size: 34, weight: .bold))
                    .lineLimit(3)
                    .minimumScaleFactor(0.7)

                artistLink

                Text(details)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                SourceBadge(source: album.source)

                HStack(spacing: 10) {
                    Button {
                        model.play(album.tracks, startingAt: 0)
                    } label: {
                        Label("Play", systemImage: "play.fill")
                            .frame(width: 86)
                    }
                    Button {
                        model.isShuffling = true
                        model.play(album.tracks, startingAt: Int.random(in: album.tracks.indices))
                    } label: {
                        Label("Shuffle", systemImage: "shuffle")
                            .frame(width: 86)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Palette.red)
                .controlSize(.large)
                .padding(.top, 10)

                if album.lyricCount < album.tracks.count {
                    lyricsHunt
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// The artist, opening their page when the library has one for them.
    @ViewBuilder
    private var artistLink: some View {
        let label = Text(album.artist)
            .font(.system(size: 20, weight: .medium))
            .foregroundStyle(Palette.red)
            .lineLimit(2)
        if let artist = library.artists.first(where: { $0.name == album.artist }) {
            NavigationLink(value: artist) { label }
                .buttonStyle(.plain)
                .help("Show \(album.artist)")
        } else {
            label
        }
    }

    /// What kind of release it is, by the rule the stores use: a handful of
    /// short tracks is a single or an EP, not an album.
    private var kind: String {
        let minutes = album.duration / 60
        if album.tracks.count <= 3, minutes < 30 { return "SINGLE" }
        if album.tracks.count <= 6, minutes < 30 { return "EP" }
        return "ALBUM"
    }

    private var details: String {
        var parts: [String] = []
        if let year = album.year, !year.isEmpty { parts.append(year) }
        parts.append(Self.songs(album.tracks.count))
        if album.duration > 0 { parts.append(Self.length(album.duration)) }
        if album.lyricCount > 0 {
            parts.append(album.lyricCount == album.tracks.count
                ? "lyrics for every song"
                : "\(album.lyricCount) with lyrics")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Tracks

    private var tracks: some View {
        VStack(spacing: 0) {
            ForEach(Array(album.tracks.enumerated()), id: \.element.id) { index, track in
                TrackRow(
                    track: track,
                    position: index + 1,
                    isCurrent: model.currentTrack?.id == track.id,
                    isPlaying: model.isPlaying,
                    onPlay: { model.play(album.tracks, startingAt: index) },
                    onFindLyrics: { library.findLyrics(for: [track]) },
                    onEdit: { editing = track }
                )
                .padding(.horizontal, 8)
                if track.id != album.tracks.last?.id {
                    Divider().padding(.leading, 52)
                }
            }
        }
        .padding(.vertical, 6)
        .background(.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// The closing lines of a record's page, the way a sleeve's back ends.
    private var footer: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let year = album.year, !year.isEmpty {
                Text("Released \(year)")
            }
            Text("\(Self.songs(album.tracks.count))\(album.duration > 0 ? ", " + Self.length(album.duration, long: true) : "")")
            if album.addedAt > .distantPast {
                Text("Added \(album.addedAt.formatted(date: .long, time: .omitted))")
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
    }

    // MARK: - More by the artist

    private var moreByArtist: [LibraryAlbum] {
        library.albums
            .filter { $0.artist == album.artist && $0.id != album.id }
            .sorted { ($0.year ?? "") > ($1.year ?? "") }
    }

    private var moreShelf: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("More by \(album.artist)")
                .font(.system(size: 20, weight: .bold))
                .padding(.horizontal, 32)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 20) {
                    ForEach(moreByArtist) { other in
                        NavigationLink(value: other) {
                            AlbumTile(album: other) {
                                model.play(other.tracks, startingAt: 0)
                            }
                            .frame(width: 168)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 32)
            }
        }
    }

    /// The shelf says how many songs on this record can be sung along to;
    /// this is the button that changes that number.
    @ViewBuilder
    private var lyricsHunt: some View {
        if let hunt = library.lyricsHunt {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("\(hunt.done + 1) of \(hunt.total) — \(hunt.title)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Button("Stop") { library.cancelLyricsHunt() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.red)
            }
            .padding(.top, 6)
        } else {
            Button {
                library.findLyrics(for: album.tracks)
            } label: {
                Label(
                    "Find lyrics for \(album.tracks.count - album.lyricCount) tracks",
                    systemImage: "sparkle.magnifyingglass"
                )
                .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.red)
            .padding(.top, 6)
        }
    }

    /// Rounded to the nearest minute, and never "0 min": a 2:55 single is
    /// "3 min", not the "2 min" that cutting off the seconds used to give.
    static func length(_ seconds: TimeInterval, long: Bool = false) -> String {
        let minutes = max(1, Int((seconds / 60).rounded()))
        if minutes >= 60 {
            let hours = minutes / 60, rest = minutes % 60
            return long
                ? "\(hours) \(hours == 1 ? "hour" : "hours") \(rest) \(rest == 1 ? "minute" : "minutes")"
                : "\(hours) hr \(rest) min"
        }
        return long ? "\(minutes) \(minutes == 1 ? "minute" : "minutes")" : "\(minutes) min"
    }

    static func songs(_ count: Int) -> String {
        "\(count) \(count == 1 ? "song" : "songs")"
    }
}

struct TrackRow: View {
    let track: LibraryTrack
    var position: Int?
    var subtitle: String?
    let isCurrent: Bool
    let isPlaying: Bool
    let onPlay: () -> Void
    var onFindLyrics: (() -> Void)?
    var onEdit: (() -> Void)?

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                if isCurrent {
                    Image(systemName: isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.red)
                } else if hovering {
                    Image(systemName: "play.fill").font(.system(size: 11))
                } else if let position {
                    Text("\(position)")
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 24)

            VStack(alignment: .leading, spacing: 1) {
                Text(track.title)
                    .font(.system(size: 13))
                    .foregroundStyle(isCurrent ? Palette.red : .primary)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            // Only in lists that mix records. Inside an album the header
            // already says where it is, and a label on every row is noise.
            if subtitle != nil {
                SourceBadge(source: track.source)
            }

            if track.hasLyrics {
                Image(systemName: "quote.bubble")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .help("Has timed lyrics")
            }
            Text(Self.clock(track.duration))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 8)
        .background(hovering ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2, perform: onPlay)
        .onTapGesture(perform: onPlay)
        .contextMenu {
            Button("Play", action: onPlay)
            if !track.hasLyrics, let onFindLyrics {
                Button("Find Lyrics", action: onFindLyrics)
            }
            if track.url.isFileURL, let onEdit {
                Button("Get Info…", action: onEdit)
            }
            // A server track has no file on this Mac to show.
            if track.url.isFileURL {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([track.url])
                }
            }
        }
    }

    static func clock(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite, seconds > 0 else { return "--:--" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

struct SongsList: View {
    let songs: [LibraryTrack]
    let model: PlaybackModel
    let library: LibraryStore

    @State private var editing: LibraryTrack?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(songs.enumerated()), id: \.element.id) { index, track in
                    TrackRow(
                        track: track,
                        subtitle: "\(track.artist) — \(track.album)",
                        isCurrent: model.currentTrack?.id == track.id,
                        isPlaying: model.isPlaying,
                        onPlay: { model.play(songs, startingAt: index) },
                        onFindLyrics: { library.findLyrics(for: [track]) },
                        onEdit: { editing = track }
                    )
                    Divider().padding(.leading, 44)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .sheet(item: $editing) { track in
            MetadataEditor(track: track, onSaved: { library.rescanFolder() }, onClose: { editing = nil })
        }
    }
}

struct ArtistsList: View {
    let artists: [LibraryArtist]
    let onPlay: (LibraryAlbum) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 30) {
                ForEach(artists) { artist in
                    VStack(alignment: .leading, spacing: 12) {
                        NavigationLink(value: artist) {
                            Text(artist.name)
                                .font(.system(size: 20, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .help("Open \(artist.name)")
                        Text("\(artist.albums.count) albums · \(artist.trackCount) songs")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(alignment: .top, spacing: 20) {
                                ForEach(artist.albums) { album in
                                    NavigationLink(value: album) {
                                        VStack(alignment: .leading, spacing: 6) {
                                            AlbumArt(id: album.id, data: album.cover)
                                                .frame(width: 140)
                                            Text(album.title)
                                                .font(.system(size: 12))
                                                .lineLimit(1)
                                                .frame(width: 140, alignment: .leading)
                                            SourceBadge(source: album.source)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
            .padding(24)
        }
    }
}
