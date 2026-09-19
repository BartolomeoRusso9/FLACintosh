import SwiftUI

/// Where the music plays: this Mac, or any Google Cast device on the network
/// — a Chromecast, a TV with Google TV, a Nest speaker, a speaker group.
struct CastButton: View {
    let model: PlaybackModel
    var tint: Color = .secondary
    var activeTint: Color = Palette.red
    var size: CGFloat = 15

    @State private var showing = false

    var body: some View {
        let cast = model.cast
        Button { showing.toggle() } label: {
            CastGlyph(connecting: isConnecting)
                .foregroundStyle(cast.isActive ? activeTint : tint)
                .frame(width: size + 3, height: size)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(cast.activeDevice.map { "Casting to \($0.name)" } ?? "Google Cast")
        .popover(isPresented: $showing, arrowEdge: .top) {
            // The popover is drawn in the system's appearance, not the one
            // Now Playing sets for itself: inheriting its dark scheme put
            // white text on a light popover.
            CastPicker(model: model) { showing = false }
                .environment(\.colorScheme, Self.systemScheme)
        }
        .onAppear { model.wireCast() }
    }

    private static var systemScheme: ColorScheme {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
    }

    private var isConnecting: Bool {
        if case .connecting = model.cast.state { return true }
        return false
    }
}

private struct CastPicker: View {
    let model: PlaybackModel
    let dismiss: () -> Void

    var body: some View {
        let cast = model.cast
        VStack(alignment: .leading, spacing: 2) {
            Text("Play On")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.bottom, 4)

            row(symbol: "laptopcomputer", title: "This Mac", detail: nil, selected: !cast.isActive, busy: false) {
                model.stopCasting()
                dismiss()
            }

            if cast.devices.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking for Cast devices…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            } else {
                Divider().padding(.vertical, 4)
                ForEach(cast.devices) { device in
                    let active = cast.activeDevice?.id == device.id
                    let connecting: Bool = {
                        if case .connecting(let pending) = cast.state { return pending.id == device.id }
                        return false
                    }()
                    row(symbol: device.symbol, title: device.name,
                        detail: connecting ? "Connecting…" : device.model,
                        selected: active && !connecting, busy: connecting) {
                        model.startCasting(to: device)
                    }
                }
            }
        }
        .padding(8)
        .frame(width: 260)
    }

    private func row(
        symbol: String,
        title: String,
        detail: String?,
        selected: Bool,
        busy: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 14))
                    .frame(width: 22)
                    .foregroundStyle(selected ? Palette.red : .primary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13))
                    if let detail {
                        Text(detail).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 6)
                if busy {
                    ProgressView().controlSize(.small)
                } else if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.red)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(CastRowStyle())
    }
}

private struct CastRowStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.12 : (hovering ? 0.07 : 0)))
            )
            .onHover { hovering = $0 }
    }
}

/// The Cast mark: a screen with waves coming off its corner. SF Symbols has
/// no Cast glyph, and a generic "TV" would not say which kind of casting.
struct CastGlyph: View {
    var connecting = false

    var body: some View {
        if connecting {
            TimelineView(.periodic(from: .now, by: 0.4)) { context in
                let step = Int(context.date.timeIntervalSinceReferenceDate / 0.4) % 4
                CastShape(waves: step).stroke(style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            }
        } else {
            CastShape(waves: 3).stroke(style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
        }
    }
}

private struct CastShape: Shape {
    /// How many of the waves to draw, for the connecting animation.
    var waves: Int

    func path(in rect: CGRect) -> Path {
        // Drawn on a 24 × 20 grid, then scaled to fit.
        let scale = min(rect.width / 24, rect.height / 20)
        let origin = CGPoint(x: rect.midX - 12 * scale, y: rect.midY - 10 * scale)
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: origin.x + x * scale, y: origin.y + y * scale) }

        var path = Path()
        path.move(to: p(2, 6))
        path.addLine(to: p(2, 3))
        path.addQuadCurve(to: p(4, 1), control: p(2, 1))
        path.addLine(to: p(20, 1))
        path.addQuadCurve(to: p(22, 3), control: p(22, 1))
        path.addLine(to: p(22, 17))
        path.addQuadCurve(to: p(20, 19), control: p(22, 19))
        path.addLine(to: p(13, 19))

        let corner = p(2, 19)
        for (index, radius) in [4.5, 9.0].enumerated() where waves > index + 1 {
            path.move(to: p(2, 19 - radius))
            path.addArc(center: corner, radius: radius * scale, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        }
        if waves > 0 {
            path.move(to: p(2, 17))
            path.addArc(center: corner, radius: 2 * scale, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        }
        return path
    }
}
