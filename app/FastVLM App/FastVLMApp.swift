import SwiftUI

@main
struct JournalApp: App {
    @State private var transcriptionQueue = TranscriptionQueue()

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(for: [JournalPage.self, JournalEntry.self])
        .environment(transcriptionQueue)
    }
}
