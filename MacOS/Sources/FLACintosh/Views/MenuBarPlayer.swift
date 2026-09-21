#if os(macOS)
import AppKit
import SwiftUI

/// The player in the menu bar: what is on, the line being sung, and enough
/// transport to never open the window.
struct MenuBarPlayer: View {
    @Bindable var model: PlaybackModel

    @Environment(\.openWindow) private var openWindow
    /// The panel stays alive while closed; nothing that follows the clock
    /// should keep redrawing inside it then.
    @State private var visible = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                AlbumArt(id: model.artworkID, data: model.artwork?.data, corner: 8)
                    .frame(width: 64, height: 64)
                    .shadow(color: .black.opacity(0.2), radius: 6, y: 3)

                VStack(alignment: .leading, spacing: 3) {
                    Text(model.track?.title ?? "Not Playing")
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    if let track = model.track {
                        Text([track.artist, track.album].filter { !$0.isEmpty }.joined(separator: " — "))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if let device = model.cast.activeDevice {
                        Label(device.name, systemImage: device.symbol)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Palette.red)
                    }
                }
                Spacer(minLength: 0)
            }

            if visible {
                MenuBarLyricLine(model: model)
                MenuBarScrubber(model: model)
            }

            HStack {
                Button { model.isShuffling.toggle() } label: {
                    Image(systemName: "shuffle")
                        .foregroundStyle(model.isShuffling ? Palette.red : .secondary)
                }
                Spacer()
                Button { model.previous() } label: { Image(systemName: "backward.fill") }
                Button { model.togglePlayPause() } label: {
                    Image(systemName: model.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(Palette.red)
                        .contentTransition(.symbolEffect(.replace))
                }
                .padding(.horizontal, 14)
                Button { model.advance(by: 1) } label: { Image(systemName: "forward.fill") }
                Spacer()
                Button { model.repeatMode = model.repeatMode.next } label: {
                    Image(systemName: model.repeatMode.symbol)
                        .foregroundStyle(model.repeatMode == .off ? .secondary : Palette.red)
                }
            }
            .font(.system(size: 15))
            .buttonStyle(.plain)
            .disabled(model.track == nil)

            HStack(spacing: 8) {
                Image(systemName: "speaker.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Slider(value: $model.volume, in: 0 ... 1)
                    .tint(Palette.red)
                    .controlSize(.small)
                Image(systemName: "speaker.wave.3.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack {
                Button("Open FLACintosh") {
                    openWindow(id: AppRoute.mainWindow)
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                Button("Equalizer") {
                    openWindow(id: "equalizer")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Button {
                    NSApp.terminate(nil)
                } label: {
                    Image(systemName: "power")
                }
                .help("Quit FLACintosh")
            }
            .buttonStyle(.borderless)
            .font(.system(size: 12))
        }
        .padding(16)
        .frame(width: 320)
        .onAppear { visible = true }
        .onDisappear { visible = false }
    }
}

/// The line being sung, when the song has timed lyrics. A view of its own:
/// it follows the lyric line, which changes a few times a minute.
private struct MenuBarLyricLine: View {
    let model: PlaybackModel

    var body: some View {
        if let lyrics = model.lyrics, let index = model.lyricLineIndex, lyrics.lines.indices.contains(index) {
            Text(lyrics.lines[index].text.trimmingCharacters(in: .whitespaces))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Palette.brand)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: 0.25), value: index)
        }
    }
}

/// Follows the interface clock, so it is the only part redrawn on each tick.
private struct MenuBarScrubber: View {
    let model: PlaybackModel

    var body: some View {
        VStack(spacing: 3) {
            Scrubber(elapsed: model.displayTime, duration: model.track?.duration ?? 0, height: 4) { model.seek(to: $0) }
                .frame(height: 10)
            HStack {
                Text(TransportClock.string(model.displayTime))
                Spacer()
                Text("-" + TransportClock.string(max(0, (model.track?.duration ?? 0) - model.displayTime)))
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.secondary)
        }
    }
}
#endif
