import SwiftUI

/// The equalizer window: ten bands, the presets, and the loudness settings
/// that sit next to it — ReplayGain and its preamp.
struct EqualizerView: View {
    @Bindable var effects: AudioEffects

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Toggle("Equalizer", isOn: $effects.equalizerOn)
                    .toggleStyle(.switch)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Picker("Preset", selection: Binding(
                    get: { effects.presetName ?? "Manual" },
                    set: { if $0 != "Manual" { effects.apply(preset: $0) } }
                )) {
                    if effects.presetName == nil {
                        Text("Manual").tag("Manual")
                    }
                    ForEach(AudioEffects.presets, id: \.name) { preset in
                        Text(preset.name).tag(preset.name)
                    }
                }
                .frame(width: 200)
            }

            HStack(alignment: .top, spacing: 0) {
                // The scale down the left edge.
                VStack {
                    Text("+12 dB")
                    Spacer()
                    Text("0 dB")
                    Spacer()
                    Text("−12 dB")
                }
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 180, alignment: .trailing)
                .padding(.trailing, 6)

                ForEach(AudioEffects.frequencies.indices, id: \.self) { band in
                    VStack(spacing: 6) {
                        VerticalSlider(
                            value: Binding(
                                get: { effects.gains[band] },
                                set: { effects.setGain(($0 * 2).rounded() / 2, band: band) }
                            ),
                            range: AudioEffects.gainRange
                        )
                        .frame(width: 26, height: 180)
                        Text(AudioEffects.bandLabels[band])
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .opacity(effects.equalizerOn ? 1 : 0.45)
            .disabled(!effects.equalizerOn)

            Divider()

            // Side by side where there is room for it, stacked where there is
            // not: the window is 620 wide, a phone is not.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 20) {
                    replayGainPicker
                    preampControl
                }
                VStack(alignment: .leading, spacing: 12) {
                    replayGainPicker
                    preampControl
                }
            }
            .font(.system(size: 12))

            Text("The equalizer and ReplayGain apply to everything played on \(ThisDevice.lowercase), from a folder or a server. Cast devices play the file themselves, so they are not affected.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(22)
        #if os(macOS)
        .frame(width: 620)
        #endif
    }

    private var replayGainPicker: some View {
        Picker("ReplayGain", selection: $effects.replayGain) {
            ForEach(AudioEffects.ReplayGainMode.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .frame(width: 260)
        .help("Evens out loudness between songs using the ReplayGain tags in your files")
    }

    private var preampControl: some View {
        HStack(spacing: 6) {
            Text("Preamp")
            Slider(value: $effects.replayGainPreamp, in: -6 ... 6, step: 0.5)
                .frame(width: 110)
            Text(String(format: "%+.1f dB", effects.replayGainPreamp))
                .font(.system(size: 11, design: .monospaced))
                .frame(width: 58, alignment: .leading)
        }
        .disabled(effects.replayGain == .off)
        .opacity(effects.replayGain == .off ? 0.45 : 1)
    }
}

/// A slider standing up, the way an equalizer's are.
private struct VerticalSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            let fraction = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
            let y = height * (1 - fraction)
            ZStack(alignment: .top) {
                Capsule()
                    .fill(Color.primary.opacity(0.12))
                    .frame(width: 4)
                    .frame(maxWidth: .infinity)
                // The fill runs from the 0 dB line to the knob.
                Capsule()
                    .fill(Palette.brand)
                    .frame(width: 4, height: abs(y - height / 2))
                    .offset(y: min(y, height / 2))
                    .frame(maxWidth: .infinity)
                Rectangle()
                    .fill(Color.primary.opacity(0.25))
                    .frame(width: 14, height: 1)
                    .offset(y: height / 2)
                    .frame(maxWidth: .infinity)
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                    .frame(width: 16, height: 16)
                    .offset(y: y - 8)
                    .frame(maxWidth: .infinity)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let clamped = min(max(drag.location.y, 0), height)
                        value = range.upperBound - (clamped / height) * (range.upperBound - range.lowerBound)
                    }
            )
            .onTapGesture(count: 2) { value = 0 }
            .help(String(format: "%+.1f dB — double-click to reset", value))
        }
    }
}
