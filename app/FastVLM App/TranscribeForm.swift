import SwiftUI
import SwiftData
#if canImport(UIKit)
import UIKit
#else
import ImageIO
#endif

// Shared tail of both new-page screens: photo preview, first-entry date,
// and the Transcribe hand-off. Owned by ImportView and CaptureView, which
// supply the photos through the binding.
struct TranscribeForm: View {
    @Binding var pageImages: [Data]
    @Environment(\.modelContext) private var modelContext // DB session
    @Environment(\.dismiss) private var dismiss // Pop this screen
    @Environment(TranscriptionQueue.self) private var queue // Background transcription queue

    @State private var firstEntryDate = Date()

    var body: some View {
        VStack(spacing: 20) {
            if pageImages.isEmpty {
                Rectangle()
                    .fill(.secondary)
                    .frame(height: 170)
                    .overlay(Text("No photos yet"))
            } else if pageImages.count == 1, let preview = previewImage(pageImages[0]) {
                preview
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 400)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(pageImages.indices, id: \.self) { index in
                            if let preview = previewImage(pageImages[index]) {
                                preview
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 120, height: 160)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }
                }
                .frame(height: 170)
            }

            DatePicker("Date of first entry", selection: $firstEntryDate,
                       displayedComponents: .date)

            Button("Transcribe") {
                // Enqueue one job per photo and close immediately —
                // the user is never blocked waiting on the model.
                guard !pageImages.isEmpty else { return }
                for imageData in pageImages {
                    queue.enqueue(
                        imageData: imageData,
                        firstEntryDate: firstEntryDate,
                        modelContext: modelContext)
                }
                dismiss()
            }
            .disabled(pageImages.isEmpty)
        }
    }

    // Decoded preview. UIKit platforms decode UIImage directly (orientation
    // applied at render); macOS falls back to ImageIO with the EXIF
    // orientation baked in so previews don't appear rotated.
    private func previewImage(_ data: Data) -> Image? {
        #if canImport(UIKit)
        guard let uiImage = UIImage(data: data) else { return nil }
        return Image(uiImage: uiImage)
        #else
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(
                  source, 0,
                  [kCGImageSourceCreateThumbnailFromImageAlways: true,
                   kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
        else { return nil }
        return Image(decorative: cgImage, scale: 1, orientation: .up)
        #endif
    }
}