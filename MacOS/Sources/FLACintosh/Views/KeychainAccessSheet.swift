import SwiftUI

/// What the Keychain prompt is, said before macOS shows it.
///
/// Left alone, a copy of the app the keychain has not seen gets a system
/// dialog at launch asking for a password, with nothing to say whose or why.
/// This comes first, in the app's own words, and the dialog only appears
/// after "Continue".
struct KeychainAccessSheet: View {
    let library: LibraryStore
    let request: LibraryStore.KeychainRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: "key.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Palette.red)
                    .frame(width: 46, height: 46)
                    .background(Palette.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))

                VStack(alignment: .leading, spacing: 3) {
                    Text("Allow access to your saved password")
                        .font(.system(size: 17, weight: .bold))
                    Text(names)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            Text("The password for \(names) is kept in your Mac's Keychain, not inside FLACintosh. macOS hands it only to the exact copy of the app that used it last — and this copy is new, or has been updated since. So before FLACintosh can sign in, macOS will ask you once.")
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                step(1, "macOS shows a window asking for **your Mac's login password** — the one that unlocks this Mac, not the server's.")
                step(2, "Choose **Always Allow**, so it does not ask again until the next update.")
            }

            Label(
                "FLACintosh reads only this password, and only to sign in to the server. It is not copied or sent anywhere else.",
                systemImage: "lock.shield"
            )
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Not Now") { library.postponeKeychainAccess() }
                    .keyboardShortcut(.cancelAction)
                Button("Continue") { library.allowKeychainAccess() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.red)
            }
        }
        .padding(24)
        .frame(width: 470)
    }

    private var names: String {
        let list = request.sources.map { "“\(library.name(of: $0))”" }
        return ListFormatter.localizedString(byJoining: list)
    }

    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Palette.red))
            Text(text)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Home's reminder for servers left unread because of the Keychain.
struct KeychainNotice: View {
    let library: LibraryStore

    var body: some View {
        let waiting = library.sourcesAwaitingKeychain
        if !waiting.isEmpty {
            let names = ListFormatter.localizedString(byJoining: waiting.map { library.name(of: $0) })
            let refused = waiting.contains { library.state(of: $0).keychainDenied }

            HStack(spacing: 12) {
                Image(systemName: "key.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(Palette.red)

                VStack(alignment: .leading, spacing: 2) {
                    Text(refused
                        ? "macOS did not hand over the password for \(names)"
                        : "\(names) is waiting for permission to use its saved password")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Its songs are not loaded until FLACintosh can read the server password kept in your Keychain.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                Button(refused ? "Try Again…" : "Allow Access…") {
                    library.reviewKeychainAccess()
                }
                .buttonStyle(.borderedProminent)
                .tint(Palette.red)
            }
            .padding(14)
            .background(Palette.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}
