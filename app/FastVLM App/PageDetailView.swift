import SwiftUI
import SwiftData

// Full-page view: the page image, the transcription error when the last run
// failed, and the Re-transcribe entry point.
struct PageDetailView: View {
    let page: JournalPage
    @Environment(TranscriptionQueue.self) private var queue
    @Environment(\.modelContext) private var modelContext

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
                    queue.retranscribe(page: page, modelContext: modelContext)
                }
                .disabled(hasQueuedOrActiveJob)
            }
            .padding()
        }
        .navigationTitle(Text(page.firstEntryDate, style: .date))
    }
}
