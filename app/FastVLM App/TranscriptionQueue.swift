import Foundation
import CoreImage
import SwiftData

enum JobPhase: Equatable {
    case queued, transcribing, segmenting
    case done
    case failed(String)
}

struct TranscriptionJob: Identifiable {
    let id = UUID()
    let imageData: Data
    // Anchors undated-entry inference; never becomes the page date — that
    // comes from the first date the segmentation detects. Today for new
    // jobs, the page's current date for re-runs.
    let fallbackDate: Date
    var phase: JobPhase
    // Set ⇒ drain updates this page instead of inserting a new one
    // (re-transcription of an existing page).
    var existingPage: JournalPage?
}

// @MainActor keeps SwiftData access and @Observable updates on the main
// thread — the heavy inference still runs on the GPU inside Apple
// Intelligence, so this doesn't block the UI while a job is generating.
@MainActor
@Observable
class TranscriptionQueue {
    var jobs: [TranscriptionJob] = []

    // ⚠️ IN-MEMORY ONLY — READ BEFORE RELYING ON THIS:
    // Force-quitting the app, iOS reclaiming memory, or the app being
    // suspended mid-job DELETES ALL IN-PROGRESS IMAGES AND TEXT. Nothing
    // is persisted until a job finishes and auto-saves its entries to
    // SwiftData. Accepted tradeoff: simplicity over resume support.

    private let service: TranscriptionService
    private var drainTask: Task<Void, Never>?

    init() {
        service = TranscriptionService()
    }

    func enqueue(imageData: Data, fallbackDate: Date, modelContext: ModelContext) {
        jobs.append(TranscriptionJob(
            imageData: imageData, fallbackDate: fallbackDate, phase: .queued))
        startDrainingIfNeeded(modelContext: modelContext)
    }

    // Re-run transcription for an existing page. The drain loop updates that
    // page in place (new text + entries, old exclusive entries removed) — no
    // second copy of the page is created.
    func retranscribe(page: JournalPage, modelContext: ModelContext) {
        jobs.append(TranscriptionJob(
            imageData: page.imageData,
            fallbackDate: page.firstEntryDate,
            phase: .queued,
            existingPage: page))
        startDrainingIfNeeded(modelContext: modelContext)
    }

    func cancelQueued(_ id: UUID) {
        // Removes .queued jobs only. The ACTIVE job cannot be cancelled —
        // it runs to completion.
        jobs.removeAll { $0.id == id && $0.phase == .queued }
    }

    func dismissJob(_ id: UUID) {
        // Manual removal of .done/.failed rows from the banner.
        jobs.removeAll { $0.id == id }
    }

    // Done jobs flash briefly in the banner, then drop off.
    private func scheduleRemoval(_ id: UUID) {
        Task {
            try? await Task.sleep(for: .seconds(2))
            jobs.removeAll { $0.id == id }
        }
    }

    private func startDrainingIfNeeded(modelContext: ModelContext) {
        guard drainTask == nil else { return }
        drainTask = Task { await drain(modelContext: modelContext) }
    }

    private func drain(modelContext: ModelContext) async {
        defer { drainTask = nil }

        while let index = jobs.firstIndex(where: { $0.phase == .queued }) {
            let id = jobs[index].id
            let fallbackDate = jobs[index].fallbackDate

            // Resolve/create the page BEFORE transcribing so PageView rows
            // bind spinners to existingPage uniformly — a page row exists
            // while its job runs, even if transcription later fails.
            let page: JournalPage
            if let existing = jobs[index].existingPage {
                page = existing
            } else {
                page = JournalPage(
                    imageData: jobs[index].imageData, firstEntryDate: fallbackDate)
                modelContext.insert(page)
                jobs[index].existingPage = page
            }

            do {
                guard let image = CIImage(data: page.imageData,
                                          options: [.applyOrientationProperty: true]) else {
                    throw NSError(domain: "JournalApp", code: 5,
                        userInfo: [NSLocalizedDescriptionKey: "Could not read image data"])
                }

                setPhase(.transcribing, for: id)
                let transcription = try await service.transcribePage(image)

                setPhase(.segmenting, for: id)
                let entries = try await service.segmentPageTranscription(
                    transcription, pageDate: fallbackDate)

                // A successful run replaces this page's text: drop the page's
                // stale exclusive entries first (entries shared with other
                // pages survive, link included — stale page-side text is
                // accepted), then update the page. For a fresh page the
                // snapshot is empty, so this is a no-op — one uniform path.
                let staleEntries = page.entries
                for entry in staleEntries where entry.pages.count == 1 {
                    modelContext.delete(entry)
                }
                page.fullTranscription = transcription
                page.transcriptionError = nil

                // The page's date is the first date the segmentation actually
                // detected, in page order — today never becomes the page date.
                // A page with no detected date at all keeps the placeholder
                // until a re-run detects one.
                page.firstEntryDate = TranscriptionService.pageDate(
                    from: entries, fallback: fallbackDate)

                // Auto-save to SwiftData. The queue is @MainActor, so
                // modelContext is safe to use here.
                for entry in entries {
                    let journalEntry = JournalEntry(
                        text: entry.entry,
                        date: entry.date,
                        orderInPage: entry.orderInPage,
                        needsReview: entry.needsReview)
                    journalEntry.pages.append(page)
                    modelContext.insert(journalEntry)
                }

                setPhase(.done, for: id)
                scheduleRemoval(id)
            } catch {
                // Keep the page (with its old entries on a failed re-run) and
                // record why it failed — PageView/PageDetailView surface this.
                page.transcriptionError = error.localizedDescription
                setPhase(.failed(error.localizedDescription), for: id)
            }
        }
    }

    private func setPhase(_ phase: JobPhase, for id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].phase = phase
    }
}

extension TranscriptionJob {
    var isActive: Bool {
        if case .transcribing = phase { return true }
        if case .segmenting = phase { return true }
        return false
    }

    var isDone: Bool {
        if case .done = phase { return true }
        return false
    }

    var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }
}
