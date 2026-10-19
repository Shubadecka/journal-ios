import SwiftUI
import SwiftData
import UIKit

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
            } else if pageImages.count == 1,
                      let uiImage = UIImage(data: pageImages[0]) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 400)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(pageImages.indices, id: \.self) { index in
                            if let uiImage = UIImage(data: pageImages[index]) {
                                Image(uiImage: uiImage)
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
}