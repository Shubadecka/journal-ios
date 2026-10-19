import SwiftUI

@main
struct JournalApp: App {
    @State private var transcriptionQueue = TranscriptionQueue()

    var body: some Scene {
        WindowGroup {
            EntryListView()
                .safeAreaInset(edge: .top) {
                    TranscriptionBanner()
                }
        }
        .modelContainer(for: [JournalPage.self, JournalEntry.self])
        .environment(transcriptionQueue)
    }
}
