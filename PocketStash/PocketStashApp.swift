import SwiftUI
import SwiftData

@main
struct PocketStashApp: App {
    private let container: ModelContainer

    init() {
        do {
            container = try ModelContainer(
                for: VideoScene.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: false)
            )
        } catch {
            container = try! ModelContainer(
                for: VideoScene.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)
            )
        }
        HistoryStore.shared.container = container
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(container)
    }
}
