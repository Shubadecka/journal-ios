import Foundation
import CoreImage
import MLXLMCommon

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

@MainActor
@Observable
class TranscriptionService {
    private let model: FastVLMModel

    init(model: FastVLMModel) {
        self.model = model
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
        let prompts = try loadPrompts()
        let userInput = UserInput(
            prompt: .text(prompts.transcription),
            images: [.ciImage(image)],
        )
        // model.generate is async, so we need await
        let task = await model.generate(userInput)
        _ = await task.result
        return model.output
    }

    // Segment a page transcription into entries
    func segmentPageTranscription(_ transcription: String, pageDate: Date) async throws -> [ParsedEntry] {
        let prompts = try loadPrompts()
        let filledPrompt = prompts.segmentation
            .replacingOccurrences(of: "{transcription}", with: transcription)
        
        let userInput = UserInput(prompt: .text(filledPrompt),
        images: [])
        let task = await model.generate(userInput)
        _ = await task.result

        // If the output starts with "Failed:", throw an error
        if model.output.starts(with: "Failed:") {
            throw NSError(
                domain: "JournalApp", 
                code: 4, 
                userInfo: [NSLocalizedDescriptionKey: model.output]
                )
        }
        return try parseEntries(from: model.output, pageDate: pageDate)
    }

    // Parse entries from a page transcription
    func parseEntries(from output: String, pageDate: Date) throws -> [ParsedEntry] {
        guard let start = output.firstIndex(of: "["),
            let end = output.lastIndex(of: "]"),
            start < end else {
                throw NSError(
                    domain: "JournalApp", 
                    code: 3, 
                    userInfo: [NSLocalizedDescriptionKey: "Failed to find JSON in output"]
                    )
            }
        let jsonData = output[start..<end].data(using: .utf8)
        guard let jsonData = jsonData else {
            throw NSError(domain: "JournalApp", code: 1, userInfo: [NSLocalizedDescriptionKey: "JSON Decoding failed"])
        }

        let decoder = JSONDecoder()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)  // dates are date-only, UTC makes sense
        formatter.locale = Locale(identifier: "en_US_POSIX")
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let dateString = try container.decode(String.self)
            guard let date = formatter.date(from: dateString) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Expected yyyy-MM-dd, got: \(dateString)")
            }
            return date
        }
        let entries: [ParsedEntryRaw] = try decoder.decode([ParsedEntryRaw].self, from: jsonData)
        
        let parsedEntries: [ParsedEntry] = try inferDates(from: entries, pageDate: pageDate)
        return parsedEntries
    }

    // Infer dates from the order of entries and the page data
    func inferDates(from entries: [ParsedEntryRaw], pageDate: Date) throws -> [ParsedEntry] {
        let sortedEntries: [ParsedEntryRaw] = entries.sorted { $0.orderInPage < $1.orderInPage }
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
