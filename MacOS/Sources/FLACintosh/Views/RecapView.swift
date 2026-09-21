import SwiftUI

/// Your listening, summed up: the songs, artists and records you came back
/// to, how much, and when — built only from what was played in this app,
/// and kept only on this Mac.
struct RecapView: View {
    let history: ListeningHistory
    let library: LibraryStore
    let model: PlaybackModel

    @AppStorage("recapPeriod") private var periodKey = ListeningRecap.Period.year.rawValue
    @State private var shown = false
    @State private var confirmingClear = false
    /// Compact on a phone; never on the Mac, where it is nil.
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var compact: Bool { sizeClass == .compact }
    private var period: ListeningRecap.Period { .init(rawValue: periodKey) ?? .year }

    var body: some View {
        let recap = ListeningRecap(plays: history.plays, period: period)

        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header

                if recap.plays.isEmpty {
                    empty
                } else {
                    hero(recap)
                        .reveal(shown, order: 0)

                    // Side by side in a window; one above the other on a phone.
                    if compact {
                        VStack(spacing: 16) { artistAndFacts(recap) }
                    } else {
                        HStack(alignment: .top, spacing: 16) { artistAndFacts(recap) }
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    topSongs(recap).reveal(shown, order: 3)
                    if !recap.topAlbums.isEmpty {
                        topAlbums(recap).reveal(shown, order: 4)
                    }
                    clock(recap).reveal(shown, order: 5)
                    footer
                }
            }
            #if os(macOS)
            .padding(28)
            #else
            .padding(16)
            #endif
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Recap")
        .onAppear {
            history.load()
            withAnimation(.spring(response: 0.6, dampingFraction: 0.85)) { shown = true }
        }
        .onChange(of: periodKey) {
            shown = false
            withAnimation(.spring(response: 0.6, dampingFraction: 0.85)) { shown = true }
        }
    }

    // MARK: - Sections

    private var header: some View {
        #if os(iOS)
        // One column: title and picker side by side left the title a letter
        // wide on a phone. The navigation bar already says "Recap".
        VStack(alignment: .leading, spacing: 12) {
            Text("What you played in FLACintosh, kept only on this device.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Picker("Period", selection: $periodKey) {
                ForEach(ListeningRecap.Period.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        #else
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Recap")
                    .font(.system(size: 30, weight: .bold))
                Text("What you played in FLACintosh, kept only on this Mac.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Period", selection: $periodKey) {
                ForEach(ListeningRecap.Period.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 300)
        }
        #endif
    }

    private var empty: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform.circle")
                .font(.system(size: 46))
                .foregroundStyle(Palette.red)
            Text(period == .all ? "Nothing played yet" : "Nothing played in this period")
                .font(.system(size: 17, weight: .semibold))
            Text("Your recap builds as you listen. A song counts once you have heard half of it, or four minutes.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 90)
    }

    /// The top artist and the two fact cards, for whichever container the
    /// layout puts them in.
    @ViewBuilder
    private func artistAndFacts(_ recap: ListeningRecap) -> some View {
        if let artist = recap.topArtists.first {
            topArtist(artist, others: Array(recap.topArtists.dropFirst()))
                .reveal(shown, order: 1)
        }
        VStack(spacing: 16) {
            if let kind = recap.listenerKind {
                factCard(symbol: kind.symbol, title: kind.title, detail: kind.detail)
            }
            factCard(
                symbol: "flame.fill",
                title: recap.longestStreak == 1 ? "1 day" : "\(recap.longestStreak) days in a row",
                detail: recap.busiestDay.map { "Your biggest day was \($0.date.formatted(.dateTime.day().month(.wide))), with \($0.minutes) minutes." } ?? ""
            )
        }
        .reveal(shown, order: 2)
    }

    private func hero(_ recap: ListeningRecap) -> some View {
        Group {
            if compact {
                VStack(alignment: .leading, spacing: 18) {
                    heroText(recap)
                    coverFan(recap.topAlbums.compactMap { album(for: $0) })
                        .frame(maxWidth: .infinity)
                }
            } else {
                HStack(alignment: .center, spacing: 24) {
                    heroText(recap)
                    Spacer(minLength: 10)
                    coverFan(recap.topAlbums.compactMap { album(for: $0) })
                }
            }
        }
        .padding(compact ? 20 : 28)
        .frame(maxWidth: .infinity, minHeight: 230, alignment: .leading)
        .background(Palette.brand, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: Palette.red.opacity(0.25), radius: 18, y: 8)
    }

    private func heroText(_ recap: ListeningRecap) -> some View {
        VStack(alignment: .leading, spacing: 6) {
                Text(period == .year ? "Your \(Date.now.formatted(.dateTime.year())) in music" : "Your \(period.title.lowercased()) in music")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                Text((shown ? recap.minutes : 0).formatted())
                    .font(.system(size: 64, weight: .heavy, design: .rounded))
                    .contentTransition(.numericText(value: Double(shown ? recap.minutes : 0)))
                    .animation(.easeOut(duration: 1.1), value: shown)
                    .foregroundStyle(.white)
                Text("minutes listened")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                Text("\(recap.plays.count) plays · \(recap.songCount) songs · \(recap.artistCount) artists")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(.top, 6)
        }
    }

    /// The top records, fanned out like sleeves on a table.
    private func coverFan(_ albums: [LibraryAlbum]) -> some View {
        ZStack {
            ForEach(Array(albums.prefix(3).enumerated().reversed()), id: \.element.id) { index, album in
                AlbumArt(id: album.id, data: album.cover, corner: 10)
                    .frame(width: 140, height: 140)
                    .shadow(color: .black.opacity(0.3), radius: 10, y: 5)
                    .rotationEffect(.degrees(shown ? Double(index - 1) * 9 : 0))
                    .offset(x: shown ? CGFloat(index - 1) * 48 : 0, y: shown ? CGFloat(abs(index - 1)) * 8 : 0)
                    .animation(.spring(response: 0.7, dampingFraction: 0.7).delay(0.15), value: shown)
            }
        }
        .frame(width: 250, height: 180)
    }

    private func topArtist(_ artist: ListeningRecap.Ranked, others: [ListeningRecap.Ranked]) -> some View {
        let cover = library.albums.first { $0.artist == artist.title }
        return VStack(alignment: .leading, spacing: 12) {
            Text("TOP ARTIST")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Palette.red)
            HStack(spacing: 16) {
                AlbumArt(id: cover?.id ?? "none", data: cover?.cover, corner: 48)
                    .frame(width: 96, height: 96)
                VStack(alignment: .leading, spacing: 4) {
                    Text(artist.title)
                        .font(.system(size: 24, weight: .bold))
                        .lineLimit(2)
                    Text("\(artist.plays) plays · \(Self.minutes(artist.seconds))")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }
            if !others.isEmpty {
                Divider()
                ForEach(Array(others.enumerated()), id: \.element.id) { index, other in
                    HStack {
                        Text("\(index + 2)")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(.secondary)
                            .frame(width: 18, alignment: .leading)
                        Text(other.title).font(.system(size: 13)).lineLimit(1)
                        Spacer()
                        Text("\(other.plays)")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func factCard(symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 22))
                .foregroundStyle(Palette.brand)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 17, weight: .bold))
                if !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func topSongs(_ recap: ListeningRecap) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Top Songs").font(.system(size: 20, weight: .bold))
            VStack(spacing: 2) {
                ForEach(Array(recap.topSongs.enumerated()), id: \.element.id) { index, song in
                    RecapSongRow(
                        rank: index + 1,
                        song: song,
                        album: album(for: song),
                        onPlay: { play(song) }
                    )
                }
            }
        }
    }

    private func topAlbums(_ recap: ListeningRecap) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Top Albums").font(.system(size: 20, weight: .bold))
            if compact {
                // Five tiles do not fit across a phone: they scroll instead.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(recap.topAlbums) { ranked in
                            RecapAlbumTile(ranked: ranked, album: album(for: ranked))
                                .frame(width: 140)
                        }
                    }
                }
            } else {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(recap.topAlbums) { ranked in
                        RecapAlbumTile(ranked: ranked, album: album(for: ranked))
                    }
                }
            }
        }
    }

    private func clock(_ recap: ListeningRecap) -> some View {
        let peak = max(recap.hours.max() ?? 1, 1)
        return VStack(alignment: .leading, spacing: 10) {
            Text("When You Listen").font(.system(size: 20, weight: .bold))
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(0 ..< 24, id: \.self) { hour in
                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(recap.hours[hour] == peak ? AnyShapeStyle(Palette.brand) : AnyShapeStyle(Palette.pink.opacity(0.45)))
                            .frame(height: shown ? max(3, 90 * CGFloat(recap.hours[hour]) / CGFloat(peak)) : 3)
                            .animation(.spring(response: 0.6, dampingFraction: 0.8).delay(0.2 + Double(hour) * 0.015), value: shown)
                        Text(hour % 6 == 0 ? "\(hour)" : " ")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .help("\(hour):00 — \(recap.hours[hour]) plays")
                }
            }
            .frame(height: 110, alignment: .bottom)
        }
        .padding(20)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var footer: some View {
        HStack {
            Text("\(history.plays.count) plays recorded in total.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Button("Clear Listening History…", role: .destructive) { confirmingClear = true }
                .controlSize(.small)
        }
        .confirmationDialog("Clear your listening history?", isPresented: $confirmingClear) {
            Button("Clear History", role: .destructive) { history.clear() }
        } message: {
            Text("Every recorded play is deleted from \(ThisDevice.lowercase). The Recap starts again from zero.")
        }
    }

    // MARK: - Library lookups

    private func album(for ranked: ListeningRecap.Ranked) -> LibraryAlbum? {
        let play = ranked.sample
        let candidates = library.albums.filter { $0.title == play.album }
        return candidates.first { $0.artist == play.albumArtist || $0.artist == play.artist } ?? candidates.first
    }

    private func play(_ song: ListeningRecap.Ranked) {
        let sample = song.sample
        if let track = URL(string: sample.url).flatMap(library.track(for:))
            ?? library.songs.first(where: { $0.title == sample.title && $0.artist == sample.artist }) {
            model.play([track], startingAt: 0)
        } else if let url = URL(string: sample.url), url.isFileURL, FileManager.default.fileExists(atPath: url.path) {
            model.openStandalone(url)
        }
    }

    static func minutes(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }
}

private struct RecapAlbumTile: View {
    let ranked: ListeningRecap.Ranked
    let album: LibraryAlbum?

    var body: some View {
        if let album {
            NavigationLink(value: album) { tile }.buttonStyle(.plain)
        } else {
            tile
        }
    }

    private var tile: some View {
        VStack(alignment: .leading, spacing: 6) {
            AlbumArt(id: album?.id ?? "none-\(ranked.key)", data: album?.cover, corner: 8)
                .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
            Text(ranked.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
            Text(ranked.plays == 1 ? "1 play" : "\(ranked.plays) plays")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: 160)
    }
}

private struct RecapSongRow: View {
    let rank: Int
    let song: ListeningRecap.Ranked
    let album: LibraryAlbum?
    let onPlay: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 14) {
            Text("\(rank)")
                .font(.system(size: 22, weight: .heavy, design: .rounded))
                .foregroundStyle(rank == 1 ? AnyShapeStyle(Palette.brand) : AnyShapeStyle(.secondary))
                .frame(width: 30)
            AlbumArt(id: album?.id ?? "none-\(song.key)", data: album?.cover, corner: 5)
                .frame(width: 44, height: 44)
                .overlay {
                    if hovering {
                        Image(systemName: "play.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                            .transition(.opacity)
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                Text(song.subtitle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(song.plays == 1 ? "1 play" : "\(song.plays) plays")
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                Text(RecapView.minutes(song.seconds))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(hovering ? 0.06 : 0), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        #if os(macOS)
        .onTapGesture(count: 2, perform: onPlay)
        .help("Double-click to play")
        #else
        .onTapGesture(perform: onPlay)
        #endif
    }
}

private extension View {
    /// Cards rising into place one after another when the Recap opens.
    func reveal(_ shown: Bool, order: Int) -> some View {
        opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 18)
            .animation(.spring(response: 0.55, dampingFraction: 0.85).delay(Double(order) * 0.07), value: shown)
    }
}
