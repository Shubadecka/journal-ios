import Foundation
import CoreImage
import FoundationModels

struct ParsedEntry {
    var entry: String
    var date: Date
    var orderInPage: Int
    // True when the date was inferred (raw date was nil) — the queue saves
    // this as JournalEntry.needsReview so the entry gets a red border.
    var needsReview: Bool = false
}

struct ParsedEntryRaw: Codable {
    var entry: String
    var date: Date?
    var orderInPage: Int
}

// Guided-generation shape for the segmentation pass. The wrapper struct
// exists because top-level array generation is the less-documented API
// shape; a collection inside one @Generable struct is the canonical pattern.
@Generable
struct SegmentedEntry {
    @Guide(description: "The entry date in YYYY-MM-DD format, or an empty string if the entry has no date.")
    var date: String

    @Guide(description: "The journal entry text, copied verbatim from the transcription.")
    var entry: String

    @Guide(description: "1-indexed position of the entry on the page.")
    var orderInPage: Int
}

@Generable
struct SegmentedPage {
    @Guide(description: "The journal entries, in page order.")
    var entries: [SegmentedEntry]
}

@MainActor
@Observable
class TranscriptionService {
    init() {}

    // Apple Intelligence must be available before any session work.
    private func ensureAppleIntelligence() throws {
        guard case .available = SystemLanguageModel.default.availability else {
            throw NSError(domain: "JournalApp", code: 2, userInfo: [
                NSLocalizedDescriptionKey:
                    "Apple Intelligence is unavailable: \(SystemLanguageModel.default.availability)",
            ])
        }
    }

    // Load prompts from the prompts.txt file
    func loadPrompts() throws -> (transcription: String, segmentation: String) {
        guard let url = Bundle.main.url(forResource: "prompts", withExtension: "txt") else {
            throw NSError(
                domain: "JournalApp",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "prompts.txt not found in bundle"])
        }
        let contents = try String(contentsOf: url, encoding: .utf8)
        // Splitting on BOTH headers yields three components:
        // [0] = anything before the first header (should be empty),
        // [1] = transcription prompt, [2] = segmentation prompt.
        let header1 = "=== TRANSCRIPTION PROMPT ==="
        let header2 = "=== ENTRY SEGMENTATION PROMPT ==="
        guard let r1 = contents.firstRange(of: header1),
              let r2 = contents.firstRange(of: header2),
              r1.upperBound <= r2.lowerBound else {
            throw NSError(domain: "JournalApp", code: 1, userInfo: [NSLocalizedDescriptionKey: "prompts.txt not separating cleanly"])
        }
        let _ = contents[..<r1.lowerBound]
        let transcriptionPrompt = String(contents[r1.upperBound..<r2.lowerBound])
        let segmentationPrompt = String(contents[r2.upperBound...])
        return (transcription: transcriptionPrompt, segmentation: segmentationPrompt)
    }

    // Transcribe a page image
    func transcribePage(_ image: CIImage) async throws -> String {
        try ensureAppleIntelligence()
        let prompts = try loadPrompts()
        // One session per call: no shared transcript, no context growth
        // across pages.
        let session = LanguageModelSession()
        let response = try await session.respond {
            prompts.transcription
            Attachment(image)
        }
        return response.content
    }

    // Segment a page transcription into entries
    func segmentPageTranscription(_ transcription: String, pageDate: Date) async throws -> [ParsedEntry] {
        try ensureAppleIntelligence()
        let prompts = try loadPrompts()
        let filledPrompt = prompts.segmentation
            .replacingOccurrences(of: "{transcription}", with: transcription)

        let session = LanguageModelSession()
        let response = try await session.respond(
            to: filledPrompt,
            generating: SegmentedPage.self)

        let raws: [ParsedEntryRaw] = response.content.entries.map { segment in
            ParsedEntryRaw(
                entry: segment.entry,
                date: Self.parseDate(segment.date),
                orderInPage: segment.orderInPage)
        }
        return try inferDates(from: raws, pageDate: pageDate)
    }

    // Parse a guided-generation date string ("YYYY-MM-DD", "null", or "")
    // into a Date; anything unparseable becomes nil.
    private static func parseDate(_ value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.lowercased() != "null" else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)  // dates are date-only, UTC makes sense
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.date(from: trimmed)
    }

    // The page's date: the first date the segmentation actually detected,
    // in page order (needsReview marks entries whose date was inferred, not
    // detected). Falls back when the page has no detected date at all —
    // new pages get the enqueue fallback, re-runs keep their previous date.
    static func pageDate(from entries: [ParsedEntry], fallback: Date) -> Date {
        entries.first(where: { !$0.needsReview })?.date ?? fallback
    }

    // Infer dates from the order of entries and the page data
    func inferDates(from entries: [ParsedEntryRaw], pageDate: Date) throws -> [ParsedEntry] {
        // Sort by orderInPage, breaking ties by source position — the model
        // occasionally emits duplicate orderInPage values, and an ambiguous
        // sort could reorder same-ranked entries and mis-infer dates.
        let sortedEntries: [ParsedEntryRaw] = entries.enumerated()
            .sorted { ($0.element.orderInPage, $0.offset) < ($1.element.orderInPage, $1.offset) }
            .map(\.element)
        var parsedEntries: [ParsedEntry] = []
        var date: Date
        for (index, entry) in sortedEntries.enumerated() {
            // Set the date from the entry if it exists, otherwise infer it from the previous entry or the page date
            if let entryDate: Date = entry.date {
                date = entryDate
            } else {
                if index == 0 {
                    date = pageDate
                } else {
                    let previousEntry = parsedEntries[index - 1]
                    date = previousEntry.date.addingTimeInterval(86400)
                }
            }
            // Add the entry to the parsed entries now that we have unwrapped the date
            parsedEntries.append(
                ParsedEntry(
                    entry: entry.entry,
                    date: date,
                    orderInPage: entry.orderInPage,
                    needsReview: entry.date == nil
                    )
                )
            }
        return parsedEntries
    }
}
