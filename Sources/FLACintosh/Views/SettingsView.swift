import SwiftUI

/// ⌘, — currently one thing worth setting, and it is the one that can fill
/// a disk.
struct SettingsView: View {
    @State private var limited = RemoteCache.limit > 0
    @State private var gigabytes = Double(RemoteCache.limit) / 1_073_741_824
    @State private var usage: Int64 = 0
    @State private var emptying = false

    private static let formatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 1
        formatter.minimum = 0.1
        formatter.maximum = 2000
        return formatter
    }()

    var body: some View {
        Form {
            Section {
                Toggle("Limit the cache", isOn: $limited)
                    .onChange(of: limited) { _, on in
                        RemoteCache.limit = on ? bytes : 0
                        if on { RemoteCache.enforceLimit() }
                        refresh()
                    }

                // `LabeledContent` rather than an `HStack`: in a Form the
                // stack hands the whole width to the controls and the label
                // wraps to one letter per line.
                LabeledContent("Maximum") {
                    HStack(spacing: 6) {
                        TextField("", value: $gigabytes, formatter: Self.formatter)
                            .labelsHidden()
                            .frame(width: 62)
                            .multilineTextAlignment(.trailing)
                            .onSubmit(apply)
                        Text("GB")
                            .foregroundStyle(.secondary)
                        Stepper("") {
                            gigabytes += 1
                            apply()
                        } onDecrement: {
                            gigabytes = max(0.1, gigabytes - 1)
                            apply()
                        }
                        .labelsHidden()
                    }
                }
                .disabled(!limited)

                LabeledContent("In use") {
                    HStack(spacing: 8) {
                        Text(Self.size(usage))
                            .monospacedDigit()
                        if limited, bytes > 0 {
                            ProgressView(value: min(1, Double(usage) / Double(bytes)))
                                .frame(width: 90)
                                .tint(Double(usage) / Double(bytes) > 0.9 ? Palette.red : Palette.pink)
                        }
                    }
                }

                Button(emptying ? "Emptying…" : "Empty Cache Now") {
                    emptying = true
                    RemoteCache.empty()
                    refresh()
                    emptying = false
                }
                .disabled(usage == 0)
            } header: {
                Text("Server track cache")
            } footer: {
                // Worth saying why the cache exists at all, or a 2 GB folder
                // of audio looks like a bug.
                Text("""
                Tracks from Navidrome and Jellyfin stream. What is kept is the \
                part of each file with its tags, lyrics and cover — usually a \
                megabyte or two — plus whole tracks in formats that cannot \
                stream. The least recently played are dropped first. A local \
                folder library uses none of this.
                """)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear(perform: refresh)
    }

    private var bytes: Int64 {
        Int64(max(0.1, gigabytes) * 1_073_741_824)
    }

    private func apply() {
        guard limited else { return }
        RemoteCache.limit = bytes
        RemoteCache.enforceLimit()
        refresh()
    }

    private func refresh() {
        usage = RemoteCache.size()
    }

    static func size(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        // Off by default, and it renders an empty cache as "Zero KB".
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: bytes)
    }
}
