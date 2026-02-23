import SwiftUI

@main
struct BeamApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Beam") {
            MainView()
                .environment(model)
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 420, height: 560)
    }
}
