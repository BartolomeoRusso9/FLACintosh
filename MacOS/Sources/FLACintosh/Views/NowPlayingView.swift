import SwiftUI

/// The full-window player: the record on the left, the words or the queue on
/// the right.
///
/// Apple Music's shape, and for its reason — a sleeve that large and lyrics
/// that tall do not stack, and the queue is the only other thing worth
/// looking at while a record is on. The two buttons in the bottom corner are
/// a switch between those two, never both at once.
///
/// Dark whatever the system appearance is: white lyrics over a sleeve's own
/// colours only work on a dark ground. The library behind it stays light or
/// dark with the system, the same split Apple Music makes — which is exactly
/// why the darkness has to stop at this view's own subtree.
struct NowPlayingView: View {
    @Bindable var model: PlaybackModel
    let onClose: () -> Void
    /// Close Now Playing and open the artist's or the record's page — nil
    /// when the library has no page for it (a file opened on its own).
    var onShowArtist: (() -> Void)? = nil
    var onShowAlbum: (() -> Void)? = nil

    /// What the right-hand column is showing.
    private enum Panel { case lyrics, queue }

    @State private var panel: Panel = .lyrics
    @Environment(PlaylistStore.self) private var playlists: PlaylistStore?
    @Namespace private var panelSwitchSpace
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var phonePage: PhonePage = PhonePage.startup
    #endif

    var body: some View {
        #if os(iOS)
        if sizeClass == .compact { phoneBody } else { desktopBody }
        #else
        desktopBody
        #endif
    }

    private var desktopBody: some View {
        ZStack {
            NowPlayingStage(palette: model.artwork?.palette ?? [])

            HStack(alignment: .top, spacing: 36) {
                record
                sidePanel
            }
            // Measured off Apple Music at a comparable window size rather
            // than guessed: the sleeve sits about a seventh of the width in
            // from the edge, and the transport keeps a deep skirt under it.
            // Flush left with 34 points below, the column read as if it had
            // slid off the corner of the window.
            .padding(.leading, 118)
            .padding(.trailing, 46)
            .padding(.top, 84)
            .padding(.bottom, 72)
        }
        // The window's own buttons are at the top left, so the app's start
        // after them.
        .overlay(alignment: .topLeading) { windowControls }
        .overlay(alignment: .topTrailing) { volume }
        .overlay(alignment: .bottomTrailing) { panelSwitch }
        // `.environment`, never `.preferredColorScheme`: the latter sets the
        // *window's* appearance, and the window outlives this screen. Closing
        // Now Playing left the whole app dark while the library kept drawing
        // its light colours — black sidebar, white-on-white shelves.
        .environment(\.colorScheme, .dark)
        // To the window's real edges. Inside the safe area the top capsules
        // were pushed down by the titlebar inset that this screen hides
        // anyway, so they sat a good fifty points below Apple Music's.
        .ignoresSafeArea()
    }

    // MARK: - Phone: one column

    #if os(iOS)
    /// A phone has room for one thing at a time: the record, its words, or
    /// what plays next. The two-column layout above is the Mac's and the
    /// iPad's.
    private enum PhonePage: String {
        case player, lyrics, queue

        /// Always the record, except in a debug build started with
        /// `-phonePage lyrics`: a simulator cannot tap, and this is how a
        /// screenshot reaches the other pages.
        static var startup: PhonePage {
            #if DEBUG
            if let name = UserDefaults.standard.string(forKey: "phonePage"), let page = PhonePage(rawValue: name) {
                return page
            }
            #endif
            return .player
        }
    }

    private var phoneBody: some View {
        ZStack {
            NowPlayingStage(palette: model.artwork?.palette ?? [])

            VStack(spacing: 0) {
                phoneTopBar

                switch phonePage {
                case .player:
                    phonePlayer
                case .lyrics:
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 12) {
                            AlbumArt(id: model.artworkID, data: model.artwork?.data, corner: 6,
                                     placeholder: AnyShapeStyle(Color.black.opacity(0.58)))
                                .frame(width: 44, height: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.track?.title ?? "Not playing")
                                    .font(.system(size: 15, weight: .semibold))
                                    .lineLimit(1)
                                if let artist = model.track?.artist, !artist.isEmpty {
                                    Text(artist)
                                        .font(.system(size: 13))
                                        .foregroundStyle(Palette.white.opacity(0.6))
                                        .lineLimit(1)
                                }
                            }
                            .foregroundStyle(Palette.white)
                        }
                        if let lyrics = model.lyrics {
                            LyricsView(lyrics: lyrics, model: model)
                        } else {
                            noLyrics
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                case .queue:
                    queuePanel
                        .padding(.horizontal, 20)
                        .padding(.top, 12)
                }

                phonePageSwitch
                    .padding(.top, 8)
                    .padding(.bottom, 4)
            }
        }
        .environment(\.colorScheme, .dark)
    }

    /// Back down to the library, and where the sound goes. Inside the safe
    /// area: the Dynamic Island and the clock are up there.
    private var phoneTopBar: some View {
        HStack(spacing: 10) {
            Button(action: onClose) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.white)
                    .frame(width: 48, height: 38)
                    .contentShape(Capsule())
            }
            .background(.white.opacity(0.14), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.14)))

            Spacer()

            HStack(spacing: 18) {
                AirPlayButton(tint: .whiteAlpha(0.85))
                    .frame(width: 24, height: 22)
                CastButton(model: model, tint: Palette.white.opacity(0.85), activeTint: Palette.pink, size: 17)
                EqualizerButton()
            }
            .padding(.horizontal, 16)
            .frame(height: 38)
            .background(.white.opacity(0.14), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.14)))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }

    private var phonePlayer: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 6)

            sleeve
                // The sleeve settles back on pause, as it does on the Mac.
                .scaleEffect(model.isPlaying || model.track == nil ? 1 : 0.88)
                .shadow(
                    color: .black.opacity(model.isPlaying ? 0.35 : 0.22),
                    radius: model.isPlaying ? 22 : 12,
                    y: model.isPlaying ? 12 : 6
                )
                .animation(.spring(response: 0.45, dampingFraction: 0.72), value: model.isPlaying)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 28)

            Spacer(minLength: 14)

            title
                .padding(.horizontal, 28)

            scrubber
                .padding(.horizontal, 28)
                .padding(.top, 18)

            phoneTransport
                .padding(.horizontal, 22)
                .padding(.top, 8)

            HStack(spacing: 10) {
                Image(systemName: "speaker.fill").font(.system(size: 11))
                Slider(value: $model.volume, in: 0 ... 1)
                    .tint(Palette.white.opacity(0.9))
                Image(systemName: "speaker.wave.3.fill").font(.system(size: 11))
            }
            .foregroundStyle(Palette.white.opacity(0.7))
            .padding(.horizontal, 28)
            .padding(.top, 10)

            Spacer(minLength: 6)
        }
    }

    /// The Mac's transport at a size a thumb can hit: every button is a
    /// forty-four point target.
    private var phoneTransport: some View {
        HStack(spacing: 0) {
            Button { model.isShuffling.toggle() } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 18))
                    .foregroundStyle(model.isShuffling ? Palette.pink : Palette.white.opacity(0.6))
                    .symbolEffect(.bounce, value: model.isShuffling)
                    .frame(width: 44, height: 44)
            }
            Spacer(minLength: 0)
            Button { model.previous() } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 26))
                    .frame(width: 52, height: 52)
            }
            Spacer(minLength: 0)
            Button { model.togglePlayPause() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 38))
                    .frame(width: 64, height: 56)
                    .contentTransition(.symbolEffect(.replace.downUp))
            }
            Spacer(minLength: 0)
            Button { model.advance(by: 1) } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 26))
                    .frame(width: 52, height: 52)
            }
            Spacer(minLength: 0)
            Button { model.repeatMode = model.repeatMode.next } label: {
                Image(systemName: model.repeatMode.symbol)
                    .font(.system(size: 18))
                    .foregroundStyle(model.repeatMode == .off ? Palette.white.opacity(0.6) : Palette.pink)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 44, height: 44)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(Palette.white)
        .disabled(model.track == nil)
    }

    /// The record, its words, or what plays next: one at a time.
    private var phonePageSwitch: some View {
        HStack(spacing: 2) {
            phonePageButton(.player, symbol: "music.note", label: "Now Playing")
            phonePageButton(.lyrics, symbol: "quote.bubble", label: "Lyrics")
            phonePageButton(.queue, symbol: "list.bullet", label: "Playing next")
        }
        .padding(3)
        .background(.white.opacity(0.14), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.14)))
    }

    private func phonePageButton(_ page: PhonePage, symbol: String, label: String) -> some View {
        let isOn = phonePage == page
        return Button {
            withAnimation(.snappy(duration: 0.25)) { phonePage = page }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(isOn ? Palette.white : Palette.white.opacity(0.6))
                .frame(width: 64, height: 40)
                .background {
                    if isOn {
                        Capsule()
                            .fill(Palette.white.opacity(0.22))
                            .matchedGeometryEffect(id: "phonePageHighlight", in: panelSwitchSpace)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
    #endif

    // MARK: - Left: the record

    /// Space under the sleeve for the title, badges, scrubber and transport,
    /// with their gaps. The sleeve takes what is left, up to the column's
    /// width.
    private static let belowSleeve: CGFloat = 250

    private var record: some View {
        GeometryReader { geometry in
            // As large as the column allows. A fixed 232 was a stamp in a
            // tall window, a quarter of the height beside lyrics filling the
            // rest; now it grows with the window and only gives way when the
            // window is too short to fit it above the transport.
            let side = max(160, min(geometry.size.width, geometry.size.height - Self.belowSleeve))

            VStack(alignment: .leading, spacing: 0) {
                sleeve
                    .frame(width: side, height: side)
                    // Apple Music's pause: the sleeve settles back a little
                    // and its shadow tightens, and springs forward on play.
                    .scaleEffect(model.isPlaying || model.track == nil ? 1 : 0.88)
                    .shadow(
                        color: .black.opacity(model.isPlaying ? 0.35 : 0.22),
                        radius: model.isPlaying ? 22 : 12,
                        y: model.isPlaying ? 12 : 6
                    )
                    .animation(.spring(response: 0.45, dampingFraction: 0.72), value: model.isPlaying)
                    // Centred on the column: the sleeve and the progress bar
                    // under it are the same record seen twice, so they share
                    // an axis.
                    .frame(maxWidth: .infinity)

                Spacer(minLength: 24)

                title

                scrubber
                    .padding(.top, 26)

                transport
                    .padding(.top, 18)
            }
        }
        // Capped rather than filling the column: at the full width the
        // progress bar ran most of the way across the window, which put the
        // shuffle and repeat buttons an awkward distance apart.
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    /// The cover, or — when the track has one beside it — its canvas, moving
    /// in the same square.
    private var sleeve: some View {
        AlbumArt(
            id: model.artworkID,
            data: model.artwork?.data,
            corner: 14,
            // Nearly black. At 0.28 over the empty stage's grey the square
            // came out mid-grey, a shade off its own background; Apple
            // Music's placeholder is much darker than the ground it sits on,
            // which is what makes it read as a sleeve.
            placeholder: AnyShapeStyle(Color.black.opacity(0.58))
        )
        .overlay {
            if let canvas = model.canvas {
                CanvasView(url: canvas, isPlaying: model.isPlaying)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.4), value: model.canvas)
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(model.track?.title ?? "Not playing")
                .font(.system(size: 21, weight: .bold))
                .foregroundStyle(Palette.white)
                .lineLimit(2)
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: 0.3), value: model.track?.title)

            // Artist and record as two links, the way Apple Music's are:
            // each opens its page in the library.
            HStack(spacing: 0) {
                if let artist = model.track?.artist, !artist.isEmpty {
                    TitleLink(text: artist, action: onShowArtist)
                }
                if let artist = model.track?.artist, !artist.isEmpty,
                   let album = model.track?.album, !album.isEmpty {
                    Text(" — ")
                }
                if let album = model.track?.album, !album.isEmpty {
                    TitleLink(text: album, action: onShowAlbum)
                }
            }
            .font(.system(size: 13))
            .foregroundStyle(Palette.white.opacity(0.6))
            .lineLimit(1)

            BadgeRow {
                // Which copy is playing, when the same song is both here and
                // on a server.
                if let origin = model.currentTrack?.source {
                    SourceBadge(source: origin)
                }
                if let device = model.cast.activeDevice {
                    Label("Playing on \(device.name)", systemImage: device.symbol)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(Palette.white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Palette.pink.opacity(0.35), in: Capsule())
                }
                if let summary = model.track?.formatSummary, !summary.isEmpty {
                    Text(summary)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(Palette.white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Palette.brand, in: Capsule())
                        .help("Read from the decoder, not guessed from the file extension")
                }
                if let source = model.lyricsSource {
                    Text(source)
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.white.opacity(0.45))
                        .help("Where these lyrics came from")
                }
                if let error = model.lastError {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.pink)
                        .lineLimit(2)
                }
            }
            .padding(.top, 3)
        }
    }

    /// A view of its own rather than a property of this one: it reads the
    /// interface clock, and whatever reads that redraws thirty times a
    /// second. As a property it made the whole screen — sleeve, lyrics and
    /// all — rebuild on every tick.
    private var scrubber: some View {
        NowPlayingScrubber(model: model)
    }

    /// The row spans the scrubber, not just the middle of it: shuffle lands
    /// under the elapsed time and repeat under the time remaining, which is
    /// what puts the two modes at the corners of the same rectangle the
    /// progress bar draws.
    private var transport: some View {
        HStack(spacing: 0) {
            Button { model.isShuffling.toggle() } label: {
                Image(systemName: "shuffle")
                    .foregroundStyle(model.isShuffling ? Palette.pink : Palette.white.opacity(0.6))
                    .symbolEffect(.bounce, value: model.isShuffling)
            }

            Spacer(minLength: 20)

            HStack(spacing: 30) {
                Button { model.previous() } label: { Image(systemName: "backward.fill") }
                Button { model.togglePlayPause() } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 26))
                        .frame(width: 32)
                        .contentTransition(.symbolEffect(.replace.downUp))
                }
                Button { model.advance(by: 1) } label: { Image(systemName: "forward.fill") }
            }

            Spacer(minLength: 20)

            Button { model.repeatMode = model.repeatMode.next } label: {
                Image(systemName: model.repeatMode.symbol)
                    .foregroundStyle(model.repeatMode == .off ? Palette.white.opacity(0.6) : Palette.pink)
                    .contentTransition(.symbolEffect(.replace))
            }
        }
        .frame(maxWidth: .infinity)
        .font(.system(size: 17))
        .buttonStyle(.plain)
        .foregroundStyle(Palette.white)
        .disabled(model.track == nil)
    }

    // MARK: - Right: words or queue

    @ViewBuilder
    private var sidePanel: some View {
        switch panel {
        case .lyrics:
            if let lyrics = model.lyrics {
                LyricsView(lyrics: lyrics, model: model)
            } else {
                noLyrics
            }
        case .queue:
            queuePanel
        }
    }

    private var noLyrics: some View {
        VStack(spacing: 14) {
            Text(model.track == nil
                ? "Play a track to see its lyrics here."
                : "No lyrics for this track")
                .font(.system(size: 13))
                .foregroundStyle(Palette.white.opacity(0.6))
                .multilineTextAlignment(.center)

            if model.track != nil {
                findLyrics
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The file has no words in it and no `.lrc` beside it — so go and ask.
    /// What comes back is written next to the file, which is where the app
    /// looks first anyway.
    @ViewBuilder
    private var findLyrics: some View {
        switch model.lyricsSearch {
        case .searching:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Looking…")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.white.opacity(0.6))
            }
        case .failed(let reason):
            VStack(spacing: 8) {
                Text(reason)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.white.opacity(0.5))
                    .multilineTextAlignment(.center)
                Button("Try again") { model.findLyrics() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.pink)
            }
        case .idle:
            Button { model.findLyrics() } label: {
                Label("Find Lyrics", systemImage: "sparkle.magnifyingglass")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .background(Palette.brand, in: Capsule())
            }
            .buttonStyle(.plain)
            .help("Apple's catalogue first — it is the only one that times syllables — then LRCLIB")
        }
    }

    private var queuePanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 16) {
                Toggle(isOn: $model.autoPlay) {
                    Label("AutoPlay", systemImage: "infinity")
                }
                .toggleStyle(PanelPill())
                .help("Keep playing from the library when the queue runs out")

                Toggle(isOn: $model.crossfade) {
                    Label("Crossfade", systemImage: "arrow.triangle.swap")
                }
                .toggleStyle(PanelPill())
                .help("Start the next track \(Int(PlaybackModel.crossfadeDuration)) seconds early and cross the two over")
            }
            .padding(.bottom, 26)

            HStack(alignment: .firstTextBaseline) {
                Text("Playing Next")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Palette.white)

                Spacer()

                if let playlists, !model.queue.isEmpty {
                    Button("Save as Playlist") {
                        playlists.create(with: model.queue)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.red)
                    .help("Make a playlist of everything in the queue")
                }

                Button("Clear") { model.clearQueue() }
                    .buttonStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(model.upNext.isEmpty ? Palette.red.opacity(0.4) : Palette.red)
                    .disabled(model.upNext.isEmpty)
                    .help("Drop everything after the current track")
            }
            .padding(.bottom, 9)

            Rectangle()
                .fill(Palette.white.opacity(0.25))
                .frame(height: 1)

            QueueList(model: model)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Corners

    /// Back to the library, in a capsule clear of the traffic lights.
    private var windowControls: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .foregroundStyle(Palette.white)
                .frame(width: 34, height: 28)
        }
        .keyboardShortcut(.escape, modifiers: [])
        .help("Back to the library")
        .font(.system(size: 13, weight: .semibold))
        .buttonStyle(.plain)
        .padding(3)
        .background(.white.opacity(0.14), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.14)))
        // Clear of the window's own buttons, which this screen does not hide.
        .padding(.leading, 92)
        .padding(.top, 13)
    }

    private var volume: some View {
        HStack(spacing: 9) {
            Slider(value: $model.volume, in: 0 ... 1)
                .frame(width: 116)
                .tint(Palette.white.opacity(0.9))
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 12))
                .foregroundStyle(Palette.white.opacity(0.8))
            // Where the sound goes, next to how loud it is — Apple Music's
            // place for it.
            AirPlayButton(tint: .whiteAlpha(0.85))
                .frame(width: 22, height: 18)
                .help("AirPlay")
            CastButton(model: model, tint: Palette.white.opacity(0.85), activeTint: Palette.pink, size: 15)
            EqualizerButton()
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 6)
        .background(.white.opacity(0.14), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.14)))
        .padding(.trailing, 22)
        .padding(.top, 13)
    }

    /// Words or queue. A switch, so the one you are looking at is lit and
    /// the other is not — two independent toggles here would allow a state
    /// where the column shows nothing.
    private var panelSwitch: some View {
        HStack(spacing: 2) {
            panelButton(.lyrics, symbol: "quote.bubble", help: "Lyrics")
            panelButton(.queue, symbol: "list.bullet", help: "Playing next")
        }
        .font(.system(size: 13, weight: .semibold))
        .buttonStyle(.plain)
        .padding(3)
        .background(.white.opacity(0.14), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.14)))
        .padding(.trailing, 22)
        .padding(.bottom, 22)
    }

    private func panelButton(_ which: Panel, symbol: String, help: String) -> some View {
        let isOn = panel == which
        return Button {
            withAnimation(.snappy(duration: 0.25)) { panel = which }
        } label: {
            Image(systemName: symbol)
                .foregroundStyle(isOn ? Palette.white : Palette.white.opacity(0.6))
                .frame(width: 34, height: 28)
                .background {
                    // One highlight that slides between the two, rather than
                    // two that blink.
                    if isOn {
                        Capsule()
                            .fill(Palette.white.opacity(0.22))
                            .matchedGeometryEffect(id: "panelHighlight", in: panelSwitchSpace)
                    }
                }
        }
        .help(help)
    }
}

/// The small labels under the title: where the song is from, where it is
/// playing, what format it is in.
///
/// One row in a window, where they all fit. On a phone they do not — the
/// source, the Cast device and the format are each a capsule wider than a
/// third of the screen — and in a row that will not wrap they were squeezed
/// to a word wide and broken a letter at a time. There they flow onto the
/// next line instead.
private struct BadgeRow<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        if sizeClass == .compact {
            FlowLayout(spacing: 8) { content }
        } else {
            HStack(spacing: 8) { content }
        }
    }
}

/// Views placed left to right, each at the size it wants, and on to a new
/// line when the next one would not fit.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let limit = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: limit, height: nil))
            if x > 0, x + size.width > limit {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: widest, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// The capsule the panel's two switches are drawn as.
///
/// A `Toggle` rather than a `Button` because that is what they are — the
/// checkbox is just wearing a pill. Off it is a dim capsule; on it lights
/// up, the same way Apple Music's do.
private struct PanelPill: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            configuration.label
                .font(.system(size: 13))
                .labelStyle(.titleAndIcon)
                .foregroundStyle(configuration.isOn ? Palette.white : Palette.white.opacity(0.55))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(
                    Capsule().fill(.white.opacity(configuration.isOn ? 0.24 : 0.12))
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// The scrubber and the times either side of it — the only part of Now
/// Playing that follows the clock.
private struct NowPlayingScrubber: View {
    let model: PlaybackModel

    var body: some View {
        VStack(spacing: 6) {
            Scrubber(
                elapsed: model.displayTime,
                duration: model.track?.duration ?? 0,
                tint: AnyShapeStyle(Palette.brand),
                track: Color.white.opacity(0.18)
            ) { model.seek(to: $0) }

            HStack {
                Text(TransportClock.string(model.displayTime))
                Spacer()
                // Counting down, the way every player does it: what is left
                // is the question you actually have.
                Text("-\(TransportClock.string(max(0, (model.track?.duration ?? 0) - model.displayTime)))")
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(Palette.white.opacity(0.5))
            .monospacedDigit()
        }
    }
}

/// A word under the title that opens a page: plain until the pointer is on
/// it, then underlined and brighter — and plain text when there is nothing
/// to open.
private struct TitleLink: View {
    let text: String
    let action: (() -> Void)?

    @State private var hovering = false

    var body: some View {
        if let action {
            Button(action: action) {
                Text(text)
                    .underline(hovering)
                    .foregroundStyle(Palette.white.opacity(hovering ? 0.95 : 0.6))
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help("Show \(text)")
        } else {
            Text(text)
        }
    }
}

/// Opens the equalizer from the volume capsule.
private struct EqualizerButton: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openEqualizer) private var openEqualizer

    var body: some View {
        Button {
            if let openEqualizer { openEqualizer() } else { openWindow(id: "equalizer") }
        } label: {
            Image(systemName: "slider.vertical.3")
                .font(.system(size: 13))
                .foregroundStyle(Palette.white.opacity(0.85))
        }
        .buttonStyle(.plain)
        .help("Equalizer")
    }
}
