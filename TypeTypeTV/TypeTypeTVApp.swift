import SwiftUI

@main
struct TypeTypeTVApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

struct RootView: View {
    @AppStorage("typetype.instanceOrigin") private var instanceOrigin = ""

    var body: some View {
        if instanceOrigin.isEmpty {
            ServerSetupView { instanceOrigin = $0 }
        } else {
            BrowseView(instanceOrigin: instanceOrigin) { instanceOrigin = "" }
        }
    }
}
