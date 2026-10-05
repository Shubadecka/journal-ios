import Foundation
import CoreImage
import SwiftData

enum JobPhase {
    case queued, transcribing, segmenting
    case done
    case failed(String)
}

struct TranscriptionJob: Identifiable {
    let id = UUID()
    let imageData: Data
    let firstEntryDate: Date
    var phase: JobPhase
    var parsedEntries: [ParsedEntry]?
}

// @MainActor keeps SwiftData access and @Observable updates on the main
// thread — the heavy inference still runs on the GPU inside MLX, so this
// doesn't block the UI while a job is generating.
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
        service = TranscriptionService(model: FastVLMModel())
    }

    func enqueue(imageData: Data, firstEntryDate: Date, modelContext: ModelContext) {
        jobs.append(TranscriptionJob(
            imageData: imageData, firstEntryDate: firstEntryDate, phase: .queued))
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
            let firstEntryDate = jobs[index].firstEntryDate

            guard let image = CIImage(data: jobs[index].imageData) else {
                setPhase(.failed("Could not read image data"), for: id)
                continue
            }

            do {
                setPhase(.transcribing, for: id)
                let transcription = try await service.transcribePage(image)

                setPhase(.segmenting, for: id)
                let entries = try await service.segmentPageTranscription(
                    transcription, pageDate: firstEntryDate)

                // Auto-save to SwiftData. The queue is @MainActor, so
                // modelContext is safe to use here.
                let page = JournalPage(
                    imageData: jobs[index].imageData, firstEntryDate: firstEntryDate)
                page.fullTranscription = transcription
                modelContext.insert(page)
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
