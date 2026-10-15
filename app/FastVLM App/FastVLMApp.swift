//
// For licensing see accompanying LICENSE file.
// Copyright (C) 2025 Apple Inc. All Rights Reserved.
//

import SwiftUI

@main
struct FastVLMApp: App {
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
