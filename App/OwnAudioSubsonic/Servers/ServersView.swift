import SubsonicKit
import SwiftUI

/// Every configured server: pick the one to browse, check, rename or remove.
struct ServersView: View {
    @Environment(AppModel.self) private var model
    @State private var isAdding = false
    @State private var renaming: ServerRecord?
    @State private var newName = ""
    @State private var statuses: [UUID: ConnectionStatus] = [:]
    @State private var checking: Set<UUID> = []
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                ForEach(model.servers) { server in
                    row(server)
                }
            } footer: {
                Text("The library shows the selected server. Music from any server can stay in the queue.")
            }

            Section {
                Button {
                    isAdding = true
                } label: {
                    Label("Add Server", systemImage: "plus")
                }
                .accessibilityIdentifier("servers.add")
            }
        }
        .navigationTitle("Servers")
        .sheet(isPresented: $isAdding) {
            NavigationStack { AddServerView() }
        }
        .alert("Rename Server", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Save") {
                guard let server = renaming else { return }
                let name = newName.trimmingCharacters(in: .whitespaces)
                renaming = nil
                guard !name.isEmpty else { return }
                Task { try? await model.renameServer(id: server.id, to: name) }
            }
        }
        .alert("Couldn't Remove Server", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func row(_ server: ServerRecord) -> some View {
        Button {
            Haptics.selection()
            model.selectServer(id: server.id)
        } label: {
            HStack(spacing: Theme.Spacing.md) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(server.displayName).foregroundStyle(.primary)
                    Text("\(server.credentials.username) · \(server.credentials.host.absoluteString)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    statusText(server.id)
                }
                Spacer()
                if server.id == model.activeServerId {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .accessibilityLabel("Selected")
                }
            }
        }
        .accessibilityIdentifier("servers.row.\(server.displayName)")
        .swipeActions {
            Button(role: .destructive) {
                remove(server)
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
        .contextMenu {
            Button {
                check(server)
            } label: {
                Label("Check Connection", systemImage: "antenna.radiowaves.left.and.right")
            }
            Button {
                newName = server.displayName
                renaming = server
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Button(role: .destructive) {
                remove(server)
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private func statusText(_ id: UUID) -> some View {
        if checking.contains(id) {
            Text("Checking…").font(.caption).foregroundStyle(.secondary)
        } else if let status = statuses[id] {
            switch status {
            case .ok: Label("Connected", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
            case .rejected: Label("Sign-in rejected", systemImage: "xmark.circle.fill").font(.caption).foregroundStyle(.red)
            case .unreachable: Label("Unreachable", systemImage: "wifi.exclamationmark").font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func check(_ server: ServerRecord) {
        checking.insert(server.id)
        Task {
            statuses[server.id] = await model.checkConnection(id: server.id)
            checking.remove(server.id)
        }
    }

    private func remove(_ server: ServerRecord) {
        Task {
            do {
                try await model.removeServer(id: server.id)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
