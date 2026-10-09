import SwiftUI

@main
struct OwnAudioSubsonicApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task { await model.load() }
        }
        .onChange(of: scenePhase) { _, phase in
            // Audio keeps playing in the background, so this is a save, not a pause.
            if phase == .background { model.engine.saveProgressForTeardown() }
        }
    }
}
