import SwiftUI

/// The Download shelf: search Spotify through a SpotiFLAC server, open what
/// it finds, and send it to the server — then, further down, SpotiFLAC on
/// this Mac.
///
/// The query is the window's own search field. On this shelf it searches
/// the catalogue instead of filtering the library, which is the one thing a
/// search box on a download screen could sensibly mean.
///
/// Every result opens its track list (`RemoteTracklistView`), and every one
/// that can be in the library says whether it already is, so the question
/// "do I need this?" is answered before the button is there to press.
struct DownloadView: View {
    @Bindable var server: SpotiFLACServer
    @Bindable var local: SpotiFLACBridge
    let library: LibraryStore
    let query: String

    @State private var editingServer = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                if server.isConfigured {
                    status
                } else {
                    ServerForm(server: server, onDone: nil)
                        .frame(maxWidth: 460)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 30)
                }

                if !server.downloads.isEmpty {
                    DownloadQueue(server: server)
                }

                if server.isConfigured {
                    if query.trimmingCharacters(in: .whitespaces).isEmpty {
                        hint
                    } else {
                        results
                    }
                }

                Divider()

                LocalSpotiFLACView(spotiflac: local, library: library)
                    .padding(.bottom, 20)
            }
            .padding(.horizontal, 28)
            .padding(.top, 18)
        }
        .navigationTitle("Download")
        .task {
            await server.connect()
            server.search(query)
        }
        .onChange(of: query) { _, new in server.search(new) }
        .sheet(isPresented: $editingServer) {
            ServerForm(server: server) { editingServer = false }
                .padding(24)
                .frame(width: 460)
        }
    }

    // MARK: - Connection

    private var status: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColour)
                .frame(width: 8, height: 8)
            Text(statusText)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            if case .failed = server.connection {
                Button("Retry") { Task { await server.connect() } }
                    .controlSize(.small)
            }
            Button("Server…") { editingServer = true }
                .controlSize(.small)
        }
    }

    private var statusColour: Color {
        switch server.connection {
        case .connected: .green
        case .connecting: .orange
        case .failed, .unconfigured: Palette.red
        }
    }

    private var statusText: String {
        let host = server.address?.host() ?? "SpotiFLAC"
        switch server.connection {
        case .connected: return "Connected to SpotiFLAC on \(host)"
        case .connecting: return "Connecting to \(host)…"
        case .failed(let reason): return reason
        case .unconfigured: return "No SpotiFLAC server"
        }
    }

    private var hint: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Search Spotify with the field in the toolbar")
                .font(.system(size: 14, weight: .medium))
            Text("Open an album, playlist or artist to see its tracks, then download all of them or only the ones you pick.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    // MARK: - Results

    @ViewBuilder
    private var results: some View {
        if let error = server.searchError {
            Text(error)
                .font(.system(size: 12))
                .foregroundStyle(.red)
        } else if server.isSearching && server.results.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 30)
        } else if server.results.isEmpty {
            Text("Nothing found for “\(query)”")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 30)
        } else {
            if !server.results.tracks.isEmpty {
                songs(server.results.tracks)
            }
            if !server.results.albums.isEmpty {
                shelf("Albums", server.results.albums)
            }
            if !server.results.artists.isEmpty {
                shelf("Artists", server.results.artists)
            }
            if !server.results.playlists.isEmpty {
                shelf("Playlists", server.results.playlists)
            }
        }
    }

    private func shelf(_ title: String, _ items: [SpotiFLACServer.Item]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading(title: title)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 158, maximum: 200), spacing: 20, alignment: .top)],
                alignment: .leading,
                spacing: 24
            ) {
                ForEach(items) { item in
                    ResultTile(item: item, server: server, library: library)
                }
            }
        }
    }

    private func songs(_ items: [SpotiFLACServer.Item]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeading(title: "Songs")
            // Two columns when there is room, the way a search shows songs:
            // the list is a glance, not a shelf to scroll.
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 380), spacing: 24, alignment: .top)],
                alignment: .leading,
                spacing: 0
            ) {
                ForEach(items) { item in
                    SongResultRow(item: item, server: server, library: library)
                }
            }
        }
    }
}

// MARK: - Pieces shared with the track list screen

struct SectionHeading: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 19, weight: .bold))
    }
}

/// A cover from the catalogue, or a placeholder while it loads.
///
/// The frame comes first and the picture is fitted into it, never the other
/// way round. Catalogue images are not all square — artist photos especially
/// — and an image allowed to size itself grows past its tile and over the
/// ones beside it. Here the placeholder shape takes whatever size it is
/// given, the image fills it from inside an overlay, and anything beyond the
/// edge is cut off.
struct RemoteCover: View {
    let url: URL?
    var symbol = "music.note"

    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.07))
            .overlay {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image
                            .resizable()
                            .scaledToFill()
                    } else {
                        Image(systemName: symbol)
                            .font(.system(size: 22, weight: .light))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .clipped()
    }
}

/// An album, playlist or artist found by the search. The picture and the
/// words open it; the button underneath downloads it.
private struct ResultTile: View {
    let item: SpotiFLACServer.Item
    @Bindable var server: SpotiFLACServer
    let library: LibraryStore

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            NavigationLink(value: item) {
                VStack(alignment: item.kind == .artist ? .center : .leading, spacing: 7) {
                    artwork
                    Text(item.title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(2)
                        .multilineTextAlignment(item.kind == .artist ? .center : .leading)
                        .foregroundStyle(.primary)
                    if !caption.isEmpty {
                        Text(caption)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: item.kind == .artist ? .center : .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }

            if item.kind != .artist {
                DownloadButton(item: item, server: server, library: library)
            }
        }
    }

    /// A square as wide as the column, whatever shape the image is. No
    /// growing on hover: tiles sit close together, and a cover that swells
    /// covers its neighbours. The shadow deepens instead.
    @ViewBuilder
    private var artwork: some View {
        let cover = RemoteCover(url: item.cover, symbol: symbol)
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: .infinity)
        if item.kind == .artist {
            cover
                .clipShape(Circle())
                .shadow(color: .black.opacity(hovering ? 0.3 : 0.12), radius: hovering ? 9 : 5, y: 3)
                .animation(.easeOut(duration: 0.15), value: hovering)
        } else {
            cover
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .shadow(color: .black.opacity(hovering ? 0.3 : 0.12), radius: hovering ? 9 : 5, y: 3)
                .animation(.easeOut(duration: 0.15), value: hovering)
        }
    }

    private var symbol: String {
        switch item.kind {
        case .artist: "music.microphone"
        case .playlist: "music.note.list"
        default: "square.stack"
        }
    }

    private var caption: String {
        switch item.kind {
        case .album: [item.subtitle, item.year ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
        case .playlist: item.subtitle.isEmpty ? "Playlist" : "Playlist · \(item.subtitle)"
        case .artist: "Artist"
        case .track: item.subtitle
        }
    }
}

/// A song found by the search: opens its track list, downloads on its own.
private struct SongResultRow: View {
    let item: SpotiFLACServer.Item
    @Bindable var server: SpotiFLACServer
    let library: LibraryStore

    var body: some View {
        HStack(spacing: 12) {
            NavigationLink(value: item) {
                HStack(spacing: 12) {
                    RemoteCover(url: item.cover)
                        .frame(width: 42, height: 42)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.system(size: 13))
                            .lineLimit(1)
                        Text([item.subtitle, item.album].filter { !$0.isEmpty }.joined(separator: " — "))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if let duration = item.duration {
                        Text(TrackTime.format(duration))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            DownloadButton(item: item, server: server, library: library)
        }
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// "In Library", the progress of a download, or the button to start one.
struct DownloadButton: View {
    let item: SpotiFLACServer.Item
    @Bindable var server: SpotiFLACServer
    let library: LibraryStore

    var body: some View {
        if inLibrary {
            Label("In Library", systemImage: "checkmark.circle.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        } else {
            switch server.state(of: item) {
            case .waiting?, .preparing?, .downloading?:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Downloading")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            case .finished?:
                Label("Downloaded", systemImage: "arrow.down.circle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.red)
            default:
                Button {
                    server.download(item)
                } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(Palette.red)
                .disabled(server.connection != .connected)
            }
        }
    }

    /// A playlist or an artist is never "in the library": they are many records.
    private var inLibrary: Bool {
        switch item.kind {
        case .album: LibraryMatch.hasAlbum(title: item.title, artist: item.subtitle, in: library)
        case .track: LibraryMatch.hasSong(title: item.title, artist: item.subtitle, in: library)
        case .playlist, .artist: false
        }
    }
}

/// The downloads sent from this window, newest first.
struct DownloadQueue: View {
    @Bindable var server: SpotiFLACServer

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionHeading(title: "Downloads")
                Spacer()
                if server.downloads.contains(where: { !$0.state.isActive }) {
                    Button("Clear Finished") { server.clearFinished() }
                        .controlSize(.small)
                }
            }
            ForEach(server.downloads) { download in
                HStack(spacing: 12) {
                    RemoteCover(url: download.item.cover)
                        .frame(width: 36, height: 36)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title(download))
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                        Text(describe(download.state))
                            .font(.system(size: 11))
                            .foregroundStyle(isFailure(download.state) ? Color.red : .secondary)
                            .lineLimit(2)
                    }
                    Spacer()
                    if download.state.isActive {
                        ProgressView().controlSize(.small)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func title(_ download: SpotiFLACServer.Download) -> String {
        guard let indices = download.indices else { return download.item.title }
        return "\(download.item.title) — \(indices.count) \(indices.count == 1 ? "track" : "tracks")"
    }

    private func describe(_ state: SpotiFLACServer.Download.State) -> String {
        switch state {
        case .waiting: "Waiting for the one before it"
        case .preparing: "Asking SpotiFLAC for the track list…"
        case .downloading(let line): line ?? "Downloading on the server…"
        case .finished(let tracks): "Downloaded \(tracks) \(tracks == 1 ? "track" : "tracks") — the library reloads shortly"
        case .failed(let reason): reason
        case .unknown: "Still downloading on the server, but the connection dropped — check SpotiFLAC"
        }
    }

    private func isFailure(_ state: SpotiFLACServer.Download.State) -> Bool {
        if case .failed = state { return true }
        return false
    }
}

enum TrackTime {
    static func format(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Where the SpotiFLAC server is and the token it wants.
private struct ServerForm: View {
    @Bindable var server: SpotiFLACServer
    let onDone: (() -> Void)?

    @State private var address = ""
    @State private var token = ""
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("SpotiFLAC Server")
                .font(.system(size: 20, weight: .bold))
            Text("SpotiFLAC started with `--web`. The token is the one set with `--web-token` or `SPOTIFLAC_WEB_TOKEN`; it is kept in the Keychain.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            TextField("Address, e.g. http://spotiflac.lan", text: $address)
                .textFieldStyle(.roundedBorder)
            SecureField(server.isConfigured ? "Token (leave empty to keep the saved one)" : "Token", text: $token)
                .textFieldStyle(.roundedBorder)

            if case .failed(let reason) = server.connection {
                Text(reason)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }

            HStack {
                if server.isConfigured {
                    Button("Forget Server", role: .destructive) {
                        server.forget()
                        onDone?()
                    }
                }
                Spacer()
                if let onDone {
                    Button("Cancel", action: onDone)
                }
                Button(working ? "Connecting…" : "Connect") {
                    working = true
                    Task {
                        await server.configure(address: address, token: token)
                        working = false
                        if server.connection == .connected { onDone?() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Palette.red)
                .disabled(working || address.trimmingCharacters(in: .whitespaces).isEmpty
                    || (!server.isConfigured && token.isEmpty))
            }
        }
        .onAppear {
            address = server.address?.absoluteString ?? ""
        }
    }
}
