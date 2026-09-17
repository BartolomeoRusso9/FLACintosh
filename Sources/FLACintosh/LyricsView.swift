import SwiftUI
import SyncedLyrics

/// The reason this project exists: lyrics that light up one syllable at a
/// time, from a local file.
///
/// The effect is not "colour the current word". Each syllable fills across
/// its own duration, so the light travels *through* a long word, and the
/// lines around the current one recede rather than disappear. That
/// continuous fill is what the eye reads as following the voice.
///
/// Only the line being sung is on a per-frame clock. Everything else moves
/// when the current line changes, which is a few times a minute — putting
/// the whole list on the display's clock is what locked the interface up.
struct LyricsView: View {
    let lyrics: TimedLyrics
    let model: PlaybackModel

    /// Whether the list keeps the sung line centred. Scrolling by hand to
    /// read ahead or back turns it off — a list that yanked itself back to
    /// the current line mid-read would make reading impossible — and the
    /// button that appears turns it back on.
    @State private var following = true

    /// Followed from the model, which publishes it only when the line
    /// changes. Worked out here from `displayTime`, this view — and every
    /// line in it — was rebuilt thirty times a second for an answer that
    /// changes a few times a minute, and that work stalled the sweep.
    private var activeIndex: Int? { model.lyricLineIndex }

    var body: some View {
        // The width comes from what the column is actually given, read with
        // a GeometryReader. `containerRelativeFrame` resolved against a wider
        // container than this column, so the lyrics asked for more room than
        // there was and pushed the sleeve and transport out of the window.
        GeometryReader { geometry in
            scroller(width: geometry.size.width)
        }
    }

    private func scroller(width: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                // Not lazy. A lazy stack only knows the heights of the lines
                // it has built, so scrolling to one further down aims at an
                // estimate and corrects itself mid-animation — a visible
                // hitch at every line change. A song's lyrics are a few dozen
                // lines, and an idle line costs nothing to keep.
                VStack(alignment: .leading, spacing: 22) {
                    // Breathing room so the first and last lines can still
                    // settle in the middle of the view.
                    Color.clear.frame(height: 120)
                    ForEach(Array(lyrics.lines.enumerated()), id: \.element.id) { index, line in
                        LyricLineView(
                            line: line,
                            distance: activeIndex.map { index - $0 },
                            clock: model
                        )
                        // The list is rebuilt when the current line changes;
                        // this is what stops that rebuild from redrawing the
                        // lines it did not touch.
                        .equatable()
                        .id(line.id)
                        .contentShape(Rectangle())
                        // Choosing a line is choosing to follow from there.
                        .onTapGesture {
                            model.seek(to: line.start)
                            withAnimation(.easeOut(duration: 0.2)) { following = true }
                        }
                    }
                    Color.clear.frame(height: 260)
                }
                .padding(.horizontal, 36)
                // Without a definite width the flow is measured against an
                // unspecified one, lays every syllable on one row, and long
                // lines run off the right edge instead of wrapping.
                .frame(width: width, alignment: .leading)
            }
            // Only a hand on the trackpad or wheel lets go of the line:
            // `.animating` is the list's own scroll to the next line, and
            // must not count as the reader wandering off.
            .onScrollPhaseChange { _, phase in
                if phase == .interacting, following {
                    withAnimation(.easeOut(duration: 0.2)) { following = false }
                }
            }
            .onChange(of: activeIndex) { _, _ in
                guard following else { return }
                centre(proxy)
            }
            .overlay(alignment: .bottom) {
                if !following, activeIndex != nil {
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) { following = true }
                        centre(proxy)
                    } label: {
                        Label("Back to Current Line", systemImage: "text.line.first.and.arrowtriangle.forward")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Palette.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(.white.opacity(0.18), in: Capsule())
                            .overlay(Capsule().strokeBorder(.white.opacity(0.2)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
    }

    private func centre(_ proxy: ScrollViewProxy) {
        guard let index = activeIndex, lyrics.lines.indices.contains(index) else { return }
        withAnimation(.spring(response: 0.55, dampingFraction: 0.85)) {
            proxy.scrollTo(lyrics.lines[index].id, anchor: .center)
        }
    }
}

private struct LyricLineView: View, Equatable {
    let line: LyricLine
    /// Lines from the active one: 0 is current, negative is past.
    let distance: Int?
    /// Read per frame, but only while this line is the active one.
    let clock: PlaybackModel

    private var isActive: Bool { distance == 0 }
    private var isSung: Bool { (distance ?? 0) < 0 }

    /// Nothing here depends on the clock unless the line is active, so a
    /// line that is neither current nor newly passed can be left alone.
    static func == (lhs: LyricLineView, rhs: LyricLineView) -> Bool {
        lhs.distance == rhs.distance && lhs.clock === rhs.clock && lhs.line == rhs.line
    }

    /// Sung lines dim but stay legible; lines still to come fade further the
    /// further off they are, and blur slightly — that depth is most of what
    /// makes the current line read as current.
    ///
    /// The numbers are higher than they would be on a white page: over the
    /// album's own colours a line at 0.28 is nearly gone.
    private var dimming: Double {
        guard let distance else { return 0.4 }
        if distance == 0 { return 1 }
        if distance < 0 { return 0.32 }
        return max(0.16, 0.55 - Double(distance) * 0.1)
    }


    var body: some View {
        Group {
            if isActive {
                // The one thing on screen that genuinely needs every frame.
                // Paused with the audio, so a stopped player costs nothing.
                // Capped at 60 frames a second. On a ProMotion display the
                // uncapped clock asked for 120, redrawing every syllable's
                // gradient masks twice as often for motion no eye separates.
                TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !clock.isPlaying)) { _ in
                    syllables(at: clock.currentTime)
                }
            } else {
                syllables(at: nil)
            }
        }
        .font(.system(size: 30, weight: .bold, design: .rounded))
        .opacity(dimming)
        // No blur on the lines around the current one. It looked right, but
        // a blur is a filter the GPU recomputes on every frame the window is
        // redrawn — and the sung line redraws it sixty times a second, so the
        // Mac ran hot for an effect dimming already gives most of.
        .scaleEffect(isActive ? 1 : 0.94, anchor: .leading)
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: isActive)
    }

    /// What the flow lays out.
    ///
    /// A line with word timing, as it came. A line without — plain LRC,
    /// which the parser keeps as one syllable spanning the whole line — cut
    /// into words first. Left whole it could not wrap: a long line measured
    /// wider than the column and dragged Now Playing out of the window.
    private var pieces: [Syllable] {
        guard !line.hasWordTiming, let only = line.syllables.first else { return line.syllables }
        return Self.words(of: only)
    }

    /// One syllable as its words, each keeping its trailing space, with the
    /// line's time shared out by letters.
    ///
    /// The shares are a guess — plain LRC says when a line starts, nothing
    /// about its words — so the sweep is also capped at a speaking pace. A
    /// line's end is the next line's start, and before an instrumental break
    /// that would stretch four words across twenty seconds.
    static func words(of syllable: Syllable) -> [Syllable] {
        var words: [String] = []
        var current = ""
        for character in syllable.text {
            // A new word starts at a letter after a space — and only once the
            // word so far has a letter of its own: plain LRC often has a
            // space after the timestamp, and it belongs to the first word.
            if !character.isWhitespace, current.last?.isWhitespace == true,
               current.contains(where: { !$0.isWhitespace }) {
                words.append(current)
                current = ""
            }
            current.append(character)
        }
        if !current.isEmpty { words.append(current) }
        guard words.count > 1 else { return [syllable] }

        let weights = words.map { max(1, $0.filter { !$0.isWhitespace }.count) }
        let letters = weights.reduce(0, +)
        let span = min(syllable.end - syllable.start, max(1, Double(letters) * 0.1))

        var pieces: [Syllable] = []
        var done = 0
        for (word, weight) in zip(words, weights) {
            let start = syllable.start + span * Double(done) / Double(letters)
            done += weight
            let end = syllable.start + span * Double(done) / Double(letters)
            pieces.append(Syllable(start: start, end: end, text: word))
        }
        return pieces
    }

    /// `nil` means "not the active line": the sweep is settled at either end
    /// and no clock is consulted.
    private func syllables(at time: TimeInterval?) -> some View {
        SyllableFlow(lineSpacing: 2) {
            ForEach(Array(pieces.enumerated()), id: \.offset) { _, syllable in
                SyllableText(
                    syllable: syllable,
                    progress: time.map { syllable.progress(at: $0) } ?? (isSung ? 1 : 0),
                    emphasise: time != nil
                )
            }
        }
    }
}

private struct SyllableText: View {
    let syllable: Syllable
    let progress: Double
    let emphasise: Bool

    /// The soft edge of the sweep. A hard cut looks like a progress bar; a
    /// short gradient looks like light moving across the letters.
    private static let feather = 0.12
    /// How much of the syllable the pink→red glow rides across. Wider than
    /// the feather on purpose: the white edge is where the voice *is*, and
    /// the colour is the light it drags behind it.
    private static let glow = 0.4

    /// The feather has to close up at both ends. Held at a constant width it
    /// leaves the first tenth of every syllable lit before the voice has
    /// reached it — every line came up with its opening word already sung.
    private var feather: Double {
        min(Self.feather, min(progress, 1 - progress))
    }

    var body: some View {
        // Only the syllable being sung needs its masks. One not reached yet
        // or already sung is a single plain Text — three layers with gradient
        // masks for every syllable of the line, every frame, is what the
        // sweep used to cost.
        if progress <= 0 {
            Text(syllable.text)
                .foregroundStyle(Palette.lyricPending)
                .animation(.spring(response: 0.32, dampingFraction: 0.62), value: progress > 0)
        } else if progress >= 1 {
            Text(syllable.text)
                .foregroundStyle(Palette.white)
        } else {
            sweeping
        }
    }

    private var sweeping: some View {
        Text(syllable.text)
            .foregroundStyle(Palette.lyricPending)
            // What has been sung: white, crisp, the thing you actually read.
            .overlay(alignment: .leading) {
                if progress > 0 {
                    Text(syllable.text)
                        .foregroundStyle(Palette.white)
                        .mask(alignment: .leading) {
                            LinearGradient(
                                stops: [
                                    .init(color: .black, location: 0),
                                    .init(color: .black, location: progress - feather),
                                    .init(color: .clear, location: progress + feather),
                                    .init(color: .clear, location: 1),
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        }
                }
            }
            // The brand, used as light rather than as paint: a pink→red band
            // travelling on the front of the sweep, gone the moment the
            // syllable is done. Colouring the whole word instead would be
            // unreadable at thirty points and would say nothing about time.
            .overlay(alignment: .leading) {
                if emphasise, progress > 0, progress < 1 {
                    Text(syllable.text)
                        .foregroundStyle(Palette.brand)
                        .mask(alignment: .leading) {
                            LinearGradient(
                                stops: [
                                    .init(color: .clear, location: 0),
                                    .init(
                                        color: .clear,
                                        location: max(0, progress - Self.glow)
                                    ),
                                    .init(color: .black, location: progress),
                                    .init(
                                        color: .clear,
                                        location: min(1, progress + Self.glow * 0.5)
                                    ),
                                    .init(color: .clear, location: 1),
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        }
                }
            }
            // A syllable lifts as it is sung and settles back. Small on
            // purpose: at this size anything more reads as a bounce.
            .scaleEffect(emphasise && progress > 0 && progress < 1 ? 1.045 : 1)
            .offset(y: emphasise && progress > 0 && progress < 1 ? -1.5 : 0)
            .animation(.spring(response: 0.32, dampingFraction: 0.62), value: progress > 0)
    }
}
