import SwiftUI

/// Address, username, password; checked against the server before anything is saved. Used as
/// the first screen and from Settings.
struct AddServerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    /// The first-run screen has nothing to cancel back to.
    var isOnboarding = false

    @State private var address = ""
    @State private var username = ""
    @State private var password = ""
    @State private var name = ""
    @State private var isConnecting = false
    @State private var errorMessage: String?
    @FocusState private var focus: Field?

    private enum Field { case address, username, password, name }

    private var canConnect: Bool {
        !address.trimmingCharacters(in: .whitespaces).isEmpty && !username.isEmpty && !password.isEmpty && !isConnecting
    }

    var body: some View {
        Form {
            if isOnboarding {
                Section {
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        Image(systemName: "music.note.house")
                            .font(.system(size: 44))
                            .foregroundStyle(.tint)
                        Text("Connect your music server")
                            .font(.title2.bold())
                        Text("Navidrome, Gonic, Airsonic, LMS, Ampache or any other Subsonic-compatible server.")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, Theme.Spacing.sm)
                }
                .listRowBackground(Color.clear)
            }

            Section {
                TextField("Address", text: $address, prompt: Text("music.example.com or 192.168.1.10:4533"))
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .address)
                    .submitLabel(.next)
                    .onSubmit { focus = .username }
                    .accessibilityIdentifier("addServer.address")
                TextField("Username", text: $username)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .username)
                    .submitLabel(.next)
                    .onSubmit { focus = .password }
                    .accessibilityIdentifier("addServer.username")
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .focused($focus, equals: .password)
                    .submitLabel(.go)
                    .onSubmit { if canConnect { connect() } }
                    .accessibilityIdentifier("addServer.password")
            } footer: {
                Text("Without http:// or https://, http is used. The password stays in this phone's Keychain and is never sent to the server, only a one-time token made from it.")
            }

            Section {
                TextField("Name (optional)", text: $name)
                    .focused($focus, equals: .name)
                    .accessibilityIdentifier("addServer.name")
            }

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("addServer.error")
                }
            }

            Section {
                Button {
                    connect()
                } label: {
                    HStack {
                        Spacer()
                        if isConnecting {
                            ProgressView()
                        } else {
                            Text("Connect").bold()
                        }
                        Spacer()
                    }
                }
                .disabled(!canConnect)
                .accessibilityIdentifier("addServer.connect")
            }
        }
        .navigationTitle(isOnboarding ? "" : "Add Server")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !isOnboarding {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .onAppear { if address.isEmpty { focus = .address } }
    }

    private func connect() {
        focus = nil
        isConnecting = true
        errorMessage = nil
        Task {
            do {
                try await model.addServer(address: address, username: username, password: password, name: name)
                Haptics.impact(.medium)
                if !isOnboarding { dismiss() }
            } catch {
                errorMessage = error.localizedDescription
            }
            isConnecting = false
        }
    }
}
