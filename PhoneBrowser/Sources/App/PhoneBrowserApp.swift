import SwiftUI

@main
struct PhoneBrowserApp: App {
    @State private var model = PhoneBrowserModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
    }
}
