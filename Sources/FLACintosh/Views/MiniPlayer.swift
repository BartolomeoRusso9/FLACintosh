import SwiftUI

/// The bar under the library: what is playing, and enough transport not to
/// have to go anywhere.
///
/// Deliberately slim. It is a strip along the bottom of a window whose real
/// content is the shelves above it — every point it takes is a point of
/// album grid. Clicking it raises Now Playing over the same window, which is
/// where the large sleeve, the words and the queue live.
struct MiniPlayer: View {
    @Bindable var model: PlaybackModel
    let onOpenNowPlaying: () -> Void

    @State private var hoveringCentre = false

    var body: some View {
        HStack(spacing: 14) {
            controls
            Spacer(minLength: 10)
            nowPlaying
            Spacer(minLength: 10)
            trailing
        }
        // A capsule, not a rounded rectangle: the corner radius is half the
        // height, which is what makes the ends read as round rather than
        // merely softened.
        //
        // The horizontal padding is generous for the same reason — inside a
        // capsule the first and last controls sit where the shape is already
        // curving away, and a shuffle icon tucked into that curve looks
        // clipped even when it is not.
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator.opacity(0.6)))
        .shadow(color: .black.opacity(0.14), radius: 12, y: 4)
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private var controls: some View {
        HStack(spacing: 11) {
            Button { model.isShuffling.toggle() } label: {
                Image(systemName: "shuffle")
                    .foregroundStyle(model.isShuffling ? Palette.red : .secondary)
            }
            .help("Shuffle")

            Button { model.previous() } label: {
                Image(systemName: "backward.fill")
            }
            Button { model.togglePlayPause() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 18))
                    .frame(width: 20)
            }
            Button { model.advance(by: 1) } label: {
                Image(systemName: "forward.fill")
            }

            Button { model.repeatMode = model.repeatMode.next } label: {
                Image(systemName: model.repeatMode.symbol)
                    .foregroundStyle(model.repeatMode == .off ? .secondary : Palette.red)
            }
            .help("Repeat")
        }
        .font(.system(size: 12))
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .disabled(model.track == nil)
        .opacity(model.track == nil ? 0.4 : 1)
    }

    @ViewBuilder
    private var nowPlaying: some View {
        // Nothing on: the middle of the bar stays empty rather than showing a
        // panel whose whole content is the word for silence. The space is
        // still reserved, so the controls either side do not shuffle about
        // when a record starts.
        if model.track == nil, !model.isBuffering {
            empty
        } else {
            lcd
        }
    }

    /// The empty middle, which is still a target.
    ///
    /// Blank, the bar gives no sign that its centre does anything — so the
    /// way in appears under the pointer and nowhere else. The button is there
    /// the whole time; only the glyph fades.
    private var empty: some View {
        Button(action: onOpenNowPlaying) {
            Image(systemName: "arrow.up.forward.square")
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
                .opacity(hoveringCentre ? 1 : 0)
                .frame(width: 340, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hoveringCentre = $0 }
        .animation(.easeOut(duration: 0.12), value: hoveringCentre)
        .help("Open Now Playing")
    }

    private var lcd: some View {
        HStack(spacing: 8) {
            AlbumArt(id: model.artworkID, data: model.artwork?.data, corner: 3)
                .frame(width: 26, height: 26)

            VStack(spacing: 1) {
                // The title wins over the buffering note: a stream is named
                // before it is audible, and saying what is coming is more
                // useful than saying that something is.
                (Text(model.track?.title
                    ?? (model.isBuffering ? "Fetching from the server…" : "Not playing"))
                    + Text(model.cast.activeDevice.map { "  ·  \($0.name)" } ?? "")
                    .foregroundColor(Palette.red))
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)

                MiniScrubber(model: model)
                    .frame(height: 6)
            }
            .frame(maxWidth: .infinity)

            MiniElapsed(model: model)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .frame(width: 340)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .contentShape(Rectangle())
        // The artist and album are one click away on Now Playing, which is a
        // better home for them than a second line squeezed in here.
        .help(model.track.map { "\($0.artist) — \($0.album)" } ?? "")
        .onTapGesture(perform: onOpenNowPlaying)
    }

    private var trailing: some View {
        HStack(spacing: 11) {
            Button(action: onOpenNowPlaying) {
                Image(systemName: "quote.bubble")
                    .foregroundStyle(model.lyrics == nil ? .secondary : Palette.red)
            }
            .help(model.lyrics == nil ? "No lyrics for this track" : "Lyrics")

            HStack(spacing: 5) {
                Image(systemName: "speaker.fill").font(.system(size: 8))
                Slider(value: $model.volume, in: 0 ... 1)
                    .frame(width: 60)
                    .tint(Palette.pink)
            }
            .foregroundStyle(.secondary)

            AirPlayButton(tint: .secondaryLabelColor)
                .frame(width: 20, height: 16)
                .help("AirPlay")

            CastButton(model: model, size: 13)
        }
        .font(.system(size: 12))
        .buttonStyle(.plain)
    }
}

enum TransportClock {
    static func string(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// The two pieces of the bar that follow the interface clock, as views of
// their own: read inline, the clock made the whole bar — sleeve, title,
// every button — redraw thirty times a second, under the whole library.

private struct MiniScrubber: View {
    let model: PlaybackModel

    var body: some View {
        Scrubber(
            elapsed: model.displayTime,
            duration: model.track?.duration ?? 0,
            height: 2
        ) { model.seek(to: $0) }
    }
}

private struct MiniElapsed: View {
    let model: PlaybackModel

    var body: some View {
        Text(TransportClock.string(model.displayTime))
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.secondary)
            .monospacedDigit()
    }
}
