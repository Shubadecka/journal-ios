import SwiftUI
import SwiftData
import ImageIO

// Orientation-transformed page image decode; works on every platform.
// Callers render a placeholder when this returns nil — no error handling.
func pageThumbnail(from data: Data, maxPixelSize: CGFloat) -> CGImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let cgImage = CGImageSourceCreateThumbnailAtIndex(
              source, 0,
              [kCGImageSourceCreateThumbnailFromImageAlways: true,
               kCGImageSourceCreateThumbnailWithTransform: true,
               kCGImageSourceThumbnailMaxPixelSize: maxPixelSize] as CFDictionary)
    else { return nil }
    return cgImage
}

// Browsable list of captured pages. Page state is derived from the model —
// no status enum: an active/queued job for the page means "Transcribing…",
// a set transcriptionError means "Failed", empty text means "Pending".
struct PageView: View {
    @Environment(TranscriptionQueue.self) private var queue
    @Query(sort: \JournalPage.createdAt, order: .reverse) private var pages: [JournalPage]
    @State private var selectedPage: JournalPage?

    var body: some View {
        List {
            ForEach(pages) { page in
                row(for: page)
            }
        }
        .navigationDestination(item: $selectedPage) { page in
            PageDetailView(page: page)
        }
        .navigationTitle("Pages")
    }

    @ViewBuilder
    private func row(for page: JournalPage) -> some View {
        let isRunning = queue.jobs.contains {
            $0.existingPage?.persistentModelID == page.persistentModelID
                && ($0.phase == .queued || $0.isActive)
        }
        HStack(spacing: 12) {
            thumbnail(for: page)
            VStack(alignment: .leading, spacing: 4) {
                Text(page.firstEntryDate, style: .date)
                Text(statusText(for: page, isRunning: isRunning))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isRunning {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { selectedPage = page }
    }

    private func thumbnail(for page: JournalPage) -> some View {
        Group {
            if let cgImage = pageThumbnail(from: page.imageData, maxPixelSize: 160) {
                Image(decorative: cgImage, scale: 1)
                    .resizable()
                    .scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.secondary)
            }
        }
        .frame(width: 60, height: 80)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        // Red border marks pages whose transcription failed — same technique
        // as the needsReview rows in EntryListView.
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(page.transcriptionError != nil ? Color.red : Color.clear,
                        lineWidth: 2)
        )
    }

    private func statusText(for page: JournalPage, isRunning: Bool) -> String {
        if isRunning { return "Transcribing…" }
        if page.transcriptionError != nil { return "Failed" }
        if page.fullTranscription.isEmpty { return "Pending" }
        return "\(page.entries.count) entries"
    }
}
