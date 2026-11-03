import SwiftUI
#if !canImport(UIKit)
import ImageIO
#endif

// Inline banner pinned above every screen (via .safeAreaInset at the app
// root). Collapsed: one status line. Tap to expand per-job rows.
struct TranscriptionBanner: View {
    @Environment(TranscriptionQueue.self) private var queue
    @State private var expanded = false

    var body: some View {
        if !queue.jobs.isEmpty {
            VStack(spacing: 0) {
                header
                if expanded {
                    ForEach(queue.jobs) { job in
                        jobRow(job)
                    }
                }
            }
            .background(.regularMaterial)
        }
    }
    
    private var statusMessage: String {
        let pending = queue.jobs.filter { !$0.isDone && !$0.isFailed }.count
        let failed = queue.jobs.filter { $0.isFailed }.count
        var parts: [String] = []
        if pending > 0 { parts.append("\(pending) queued") }
        if failed > 0 { parts.append("\(failed) failed") }
        return parts.isEmpty ? "Done" : parts.joined(separator: " · ")
    }

    private var header: some View {
        Button {
            withAnimation { expanded.toggle() }
        } label: {
            HStack(spacing: 8) {
                if let active = queue.jobs.first(where: { $0.isActive }) {
                    ProgressView()
                        .controlSize(.small)
                    let position = queue.jobs.prefix(while: { $0.id != active.id }).count + 1
                    Text("Transcribing page \(position) of \(queue.jobs.count)…")
                } else {
                    let failed = queue.jobs.filter { $0.isFailed }.count
                    Image(systemName: failed > 0 ? "exclamationmark.triangle" : (statusMessage == "Done"
                    ? "checkmark.circle" : "clock"))
                        Text(statusMessage)
                }
                Spacer()
                Image(systemName: expanded ? "chevron.down" : "chevron.up")
                    .font(.caption2)
            }
            .font(.footnote)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .foregroundStyle(.primary)
        }
    }

    @ViewBuilder
    private func jobRow(_ job: TranscriptionJob) -> some View {
        HStack(spacing: 10) {
            #if canImport(UIKit)
            if let uiImage = UIImage(data: job.imageData) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 36, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.secondary)
                    .frame(width: 36, height: 36)
            }
            #else
            if let thumbnail = Self.thumbnail(job.imageData) {
                Image(decorative: thumbnail, scale: 2)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 36, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.secondary)
                    .frame(width: 36, height: 36)
            }
            #endif

            Text(job.firstEntryDate, style: .date)

            Spacer()

            switch job.phase {
            case .queued:
                Button {
                    withAnimation { queue.cancelQueued(job.id) }
                } label: {
                    Image(systemName: "xmark")
                }
            case .transcribing, .segmenting:
                ProgressView()
                    .controlSize(.small)
            case .done:
                Image(systemName: "checkmark")
                    .foregroundStyle(.green)
            case .failed(let message):
                Text(message)
                    .lineLimit(1)
                    .foregroundStyle(.red)
                Button {
                    withAnimation { queue.dismissJob(job.id) }
                } label: {
                    Image(systemName: "xmark")
                }
            }
        }
        .font(.footnote)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    #if !canImport(UIKit)
    // Orientation-transformed thumbnail for the macOS banner row.
    private static func thumbnail(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(
                  source, 0,
                  [kCGImageSourceCreateThumbnailFromImageAlways: true,
                   kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
        else { return nil }
        return cgImage
    }
    #endif
}
