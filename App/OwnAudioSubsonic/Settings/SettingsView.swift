import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    ServersView()
                } label: {
                    LabeledContent("Servers", value: model.activeServer?.displayName ?? "")
                }
                .accessibilityIdentifier("settings.servers")
            }

            CrossfadeSettings(settings: model.playbackSettings)

            Section {
                Toggle("Report Plays to the Server", isOn: Binding(
                    get: { model.scrobblingEnabled },
                    set: { model.scrobblingEnabled = $0 }
                ))
                .accessibilityIdentifier("settings.scrobble")
            } footer: {
                Text("Shows what's playing and counts a song once you've heard half of it, or four minutes. The server can pass this on to Last.fm or ListenBrainz if you've set that up there.")
            }

            Section("About") {
                LabeledContent("Version", value: version)
                Link(destination: URL(string: "https://github.com/own-audio/subsonic-ios")!) {
                    Label("Source Code", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                Link(destination: URL(string: "https://www.mozilla.org/MPL/2.0/")!) {
                    Label("License: MPL 2.0", systemImage: "doc.text")
                }
                Link(destination: URL(string: "https://www.own.audio/")!) {
                    Label("Made by own.audio", systemImage: "heart")
                }
            }
        }
        .navigationTitle("Settings")
    }
}
