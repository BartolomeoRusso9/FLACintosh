import SwiftUI

/// What a search result holds — an album's tracks, a playlist's, an artist's
/// records — read from the SpotiFLAC server, with the choice of downloading
/// all of it or only some.
///
/// Opening one asks the server to resolve the link, which takes a moment for
/// a long playlist or a whole discography; the list is kept once read, so
/// coming back to it is instant.
struct RemoteTracklistView: View {
    let item: SpotiFLACServer.Item
    @Bindable var server: SpotiFLACServer
    let library: LibraryStore

    @State private var tracklist: SpotiFLACServer.Tracklist?
    @State private var error: String?
    @State private var selected: Set<Int> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header

                if let tracklist {
                    if item.kind == .artist {
                        discography(tracklist)
                    } else {
                        trackTable(tracklist.tracks, showAlbum: item.kind == .playlist)
                    }
                } else if let error {
                    VStack(spacing: 10) {
                        Text(error)
                            .font(.system(size: 13))
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                        Button("Try Again") { Task { await load() } }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                } else {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text(item.kind == .artist
                            ? "Reading the discography — this can take a while"
                            : "Reading the track list…")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 60)
                }

                if !server.downloads.isEmpty {
                    DownloadQueue(server: server)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 20)
        }
        .navigationTitle(item.title)
        .task(id: item.link) { await load() }
    }

    private func load() async {
        error = nil
        do {
            tracklist = try await server.tracklist(for: item)
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .bottom, spacing: 24) {
            artwork
                .frame(width: 220, height: 220)

            VStack(alignment: .leading, spacing: 6) {
                Text(item.kind.title.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(tracklist?.title.isEmpty == false ? tracklist!.title : item.title)
                    .font(.system(size: 28, weight: .bold))
                    .lineLimit(3)
                if !artistLine.isEmpty {
                    Text(artistLine)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Palette.red)
                        .lineLimit(2)
                }
                if !details.isEmpty {
                    Text(details)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                if let description = tracklist?.description, !description.isEmpty {
                    Text(description)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .padding(.top, 2)
                }

                actions
                    .padding(.top, 10)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var artwork: some View {
        let cover = RemoteCover(url: tracklist?.cover ?? item.cover, symbol: item.kind == .artist ? "music.microphone" : "square.stack")
        if item.kind == .artist {
            cover
                .clipShape(Circle())
                .shadow(color: .black.opacity(0.2), radius: 12, y: 5)
        } else {
            cover
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(color: .black.opacity(0.2), radius: 12, y: 5)
        }
    }

    private var artistLine: String {
        switch item.kind {
        case .artist: ""
        case .playlist: tracklist?.owner ?? item.subtitle
        default: tracklist?.artist.isEmpty == false ? tracklist!.artist : item.subtitle
        }
    }

    private var details: String {
        var parts: [String] = []
        if let year = (tracklist?.releaseDate).flatMap({ $0.count >= 4 ? String($0.prefix(4)) : nil }) ?? item.year {
            parts.append(year)
        }
        if let tracks = tracklist?.tracks, !tracks.isEmpty {
            parts.append("\(tracks.count) \(tracks.count == 1 ? "song" : "songs")")
            let total = tracks.compactMap(\.duration).reduce(0, +)
            if total > 0 { parts.append(Self.longDuration(total)) }
        }
        if let followers = tracklist?.followers, followers > 0 {
            parts.append("\(followers.formatted()) followers")
        }
        if let listeners = tracklist?.listeners, listeners > 0 {
            parts.append("\(listeners.formatted()) monthly listeners")
        }
        return parts.joined(separator: " · ")
    }

    private var actions: some View {
        HStack(spacing: 10) {
            let busy = server.isDownloading(item)
            Button {
                server.download(item)
            } label: {
                Label(busy ? "Downloading…" : "Download All", systemImage: "arrow.down.circle.fill")
                    .frame(minWidth: 120)
            }
            .buttonStyle(.borderedProminent)
            .tint(Palette.red)
            .controlSize(.large)
            .disabled(tracklist == nil || busy || server.connection != .connected)

            Button {
                server.download(item, indices: selected.sorted())
                selected = []
            } label: {
                Label(selected.isEmpty ? "Download Selected" : "Download \(selected.count) Selected", systemImage: "checklist")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(selected.isEmpty || server.connection != .connected)

            if let tracks = tracklist?.tracks, tracks.count > 1 {
                Button(selected.count == tracks.count ? "Select None" : "Select All") {
                    selected = selected.count == tracks.count ? [] : Set(tracks.map(\.index))
                }
                .buttonStyle(.borderless)
                .controlSize(.large)
            }
        }
    }

    // MARK: - Tracks

    private func trackTable(_ tracks: [SpotiFLACServer.Tracklist.Track], showAlbum: Bool) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(tracks.enumerated()), id: \.element.id) { position, track in
                RemoteTrackRow(
                    track: track,
                    number: position + 1,
                    showAlbum: showAlbum,
                    showCover: showAlbum,
                    inLibrary: LibraryMatch.hasSong(title: track.title, artist: track.artist, in: library),
                    isSelected: selected.contains(track.index)
                ) {
                    if selected.contains(track.index) {
                        selected.remove(track.index)
                    } else {
                        selected.insert(track.index)
                    }
                }
                .background(position.isMultiple(of: 2) ? Color.primary.opacity(0.035) : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
    }

    /// An artist's tracks, one record at a time, in the order the server
    /// lists them; each record opens on its own.
    private func discography(_ list: SpotiFLACServer.Tracklist) -> some View {
        let records = Self.group(list.tracks)
        return VStack(alignment: .leading, spacing: 30) {
            ForEach(records, id: \.name) { record in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .center, spacing: 14) {
                        RemoteCover(url: record.tracks.first?.cover, symbol: "square.stack")
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(record.name.isEmpty ? "Other songs" : record.name)
                                .font(.system(size: 17, weight: .bold))
                                .lineLimit(2)
                            Text(recordCaption(record.tracks))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let album = albumItem(for: record) {
                            NavigationLink(value: album) {
                                Label("Open Album", systemImage: "chevron.right")
                                    .labelStyle(.titleAndIcon)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        Button {
                            let indices = record.tracks.map(\.index)
                            if indices.allSatisfy(selected.contains) {
                                selected.subtract(indices)
                            } else {
                                selected.formUnion(indices)
                            }
                        } label: {
                            Text(record.tracks.map(\.index).allSatisfy(selected.contains) ? "Deselect" : "Select")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    trackTable(record.tracks, showAlbum: false)
                }
            }
        }
    }

    private func recordCaption(_ tracks: [SpotiFLACServer.Tracklist.Track]) -> String {
        var parts: [String] = []
        if let year = tracks.first?.releaseDate, year.count >= 4 { parts.append(String(year.prefix(4))) }
        parts.append("\(tracks.count) \(tracks.count == 1 ? "song" : "songs")")
        return parts.joined(separator: " · ")
    }

    private func albumItem(for record: (name: String, tracks: [SpotiFLACServer.Tracklist.Track])) -> SpotiFLACServer.Item? {
        guard let first = record.tracks.first, let link = first.albumLink, !link.isEmpty, !record.name.isEmpty else { return nil }
        return SpotiFLACServer.Item(
            kind: .album,
            title: record.name,
            subtitle: item.title,
            album: record.name,
            cover: first.cover,
            link: link,
            year: first.releaseDate.flatMap { $0.count >= 4 ? String($0.prefix(4)) : nil },
            duration: nil
        )
    }

    private static func group(_ tracks: [SpotiFLACServer.Tracklist.Track]) -> [(name: String, tracks: [SpotiFLACServer.Tracklist.Track])] {
        var order: [String] = []
        var byName: [String: [SpotiFLACServer.Tracklist.Track]] = [:]
        for track in tracks {
            if byName[track.album] == nil { order.append(track.album) }
            byName[track.album, default: []].append(track)
        }
        return order.map { ($0, byName[$0] ?? []) }
    }

    private static func longDuration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        return minutes >= 60 ? "\(minutes / 60) hr \(minutes % 60) min" : "\(minutes) min"
    }
}

private struct RemoteTrackRow: View {
    let track: SpotiFLACServer.Tracklist.Track
    let number: Int
    let showAlbum: Bool
    let showCover: Bool
    let inLibrary: Bool
    let isSelected: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: toggle) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(isSelected ? Palette.red : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(isSelected ? "Deselect" : "Select")

            Text("\(number)")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .trailing)

            if showCover {
                RemoteCover(url: track.cover)
                    .frame(width: 34, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(track.title)
                        .font(.system(size: 13))
                        .lineLimit(1)
                    if track.explicit {
                        Image(systemName: "e.square.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(track.artist)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if showAlbum {
                Text(track.album)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: 220, alignment: .leading)
            }

            if inLibrary {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .help("Already in the library")
            }

            if let duration = track.duration {
                Text(TrackTime.format(duration))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .trailing)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        // The whole row selects, not just the circle.
        .onTapGesture(perform: toggle)
    }
}
