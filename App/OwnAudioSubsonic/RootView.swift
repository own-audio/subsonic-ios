import PlayerEngine
import SubsonicKit
import SwiftUI

/// Placeholder until server setup (P3) and browsing (P4) land.
struct RootView: View {
    var body: some View {
        ContentUnavailableView(
            "No server yet",
            systemImage: "music.note.house",
            description: Text("Connect a Navidrome, Gonic or other Subsonic server to start listening.")
        )
    }
}

#Preview {
    RootView()
}
