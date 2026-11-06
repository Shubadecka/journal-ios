import SwiftUI
import SwiftData

// Full-page view: the page image, the transcription error when the last run
// failed, and the Re-transcribe entry point.
struct PageDetailView: View {
    let page: JournalPage
    @Environment(TranscriptionQueue.self) private var queue
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var showDelete = false
    @State private var showRetranscribeWarning = false

    // A queued/running job for this page disables Re-transcribe — re-running
    // twice would race the in-flight update.
    private var hasQueuedOrActiveJob: Bool {
        queue.jobs.contains {
            $0.existingPage?.persistentModelID == page.persistentModelID
                && ($0.phase == .queued || $0.isActive)
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let cgImage = pageThumbnail(from: page.imageData, maxPixelSize: 1600) {
                    Image(decorative: cgImage, scale: 1)
                        .resizable()
                        .scaledToFit()
                } else {
                    Text("Preview unavailable")
                        .foregroundStyle(.secondary)
                }

                if let error = page.transcriptionError {
                    Text(error)
                        .foregroundStyle(.red)
                } else if page.fullTranscription.isEmpty && !hasQueuedOrActiveJob {
                    // Saved without text and nothing running: the queue was
                    // interrupted (e.g. app killed mid-job) — re-run to fill it.
                    Text("Transcription pending or interrupted.")
                        .foregroundStyle(.secondary)
                }

                Button("Re-transcribe") {
                    showRetranscribeWarning = true
                }
                .disabled(hasQueuedOrActiveJob)
            }
            .padding()
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(role: .destructive) {
                    showDelete = true
                } label: {
                    Label("Delete Page", systemImage: "trash")
                }
                // Deleting mid-job would leave the drain loop writing into a
                // deleted model — same guard as Re-transcribe.
                .disabled(hasQueuedOrActiveJob)
                .tint(.red)
            }
        }
        .alert("Delete Page?", isPresented: $showDelete) {
            // The .cascade delete rule on JournalPage.entries removes every
            // entry associated with this page — no manual loop needed.
            Button("Cancel", role: .cancel) { }
                .keyboardShortcut(.defaultAction)
            Button("Delete Page", role: .destructive) {
                modelContext.delete(page)
                dismiss()
            }
        } message: {
            Text("This permanently deletes this page and all \(page.entries.count) entries associated with it. This cannot be undone.")
        }
        .alert("Re-transcribe Page?", isPresented: $showRetranscribeWarning) {
            Button("Cancel", role: .cancel) { }
                .keyboardShortcut(.defaultAction)
            Button("Re-transcribe", role: .destructive) {
                queue.retranscribe(page: page, modelContext: modelContext)
            }
        } message: {
            Text("All entries for this page will be deleted and recreated in the process.")
        }
        .navigationTitle(Text(page.firstEntryDate, style: .date))
        #if os(iOS)
        // Inline keeps the compact bar: the large-title mode reserves a big
        // empty block above the date.
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
