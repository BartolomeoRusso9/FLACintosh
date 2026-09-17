import SwiftUI

/// Adding a Navidrome or Jellyfin server.
struct ServerSetup: View {
    let library: LibraryStore
    let onDone: () -> Void

    @State private var kind: MusicServer.Kind = .subsonic
    @State private var name = ""
    @State private var address = ""
    @State private var username = ""
    @State private var password = ""
    @State private var testing = false
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add a Server")
                .font(.system(size: 18, weight: .bold))

            Picker("Kind", selection: $kind) {
                ForEach(MusicServer.Kind.allCases, id: \.self) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .pickerStyle(.segmented)

            Form {
                TextField("Name", text: $name, prompt: Text("Home server"))
                TextField("Address", text: $address, prompt: Text("http://192.168.1.10:4533"))
                TextField("Username", text: $username)
                SecureField("Password", text: $password)
            }
            .formStyle(.grouped)

            if let problem {
                Text(problem)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Tracks are fetched whole before they play, so this is worth
            // saying before someone points the app at a server over 4G.
            Text("Tracks are downloaded to a cache before playing — SFBAudioEngine reads files, not streams.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Cancel", action: onDone)
                Spacer()
                Button(testing ? "Connecting…" : "Connect") { connect() }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.red)
                    .disabled(testing || address.isEmpty || username.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 460)
    }

    /// Credentials are checked before they are saved: a server row that
    /// silently fails on selection is worse than a refusal here.
    private func connect() {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespaces)),
              url.scheme != nil
        else {
            problem = "That address needs a scheme — http:// or https://"
            return
        }

        testing = true
        problem = nil

        let server = MusicServer(
            kind: kind,
            name: name.isEmpty ? (url.host ?? "Server") : name,
            address: url,
            username: username.trimmingCharacters(in: .whitespaces)
        )
        let password = password

        Task {
            do {
                switch kind {
                case .subsonic:
                    try await SubsonicClient(server: server, password: password).ping()
                case .jellyfin:
                    try await JellyfinClient(server: server, password: password).ping()
                }
                library.add(server, password: password)
                testing = false
                onDone()
            } catch {
                testing = false
                problem = error.localizedDescription
            }
        }
    }
}
