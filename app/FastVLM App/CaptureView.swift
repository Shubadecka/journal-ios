import SwiftUI
import PhotosUI
import SwiftData

struct CaptureView: View {
    @Environment(\.modelContext) private var modelContext // DB Session
    @Environment(\.dismiss) private var dismiss // Close this screen
    @Environment(TranscriptionQueue.self) private var queue // Background transcription queue

    @State private var capturedImage: Data?
    @State private var firstEntryDate = Date()
    @State private var photosPickerItem: PhotosPickerItem?

    var body: some View {
        VStack(spacing: 20) {
            if let imageData = capturedImage,
                let uiImage = UIImage(data: imageData) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 400)
            } else {
                Rectangle()
                    .fill(.secondary)
                    .frame(height: 400)
                    .overlay(Text("Capture or import a photo"))
            }

            DatePicker("Date of first entry", selection:
            $firstEntryDate, displayedComponents: .date)

            PhotosPicker(selection: $photosPickerItem,
            matching: .images) {
                Label("Import from Photos", systemImage: "photo.on.rectangle")
            }

            Button("Transcribe") {
                // Enqueue for background transcription and close immediately —
                // the user is never blocked waiting on the model.
                guard let imageData = capturedImage else { return }
                queue.enqueue(
                    imageData: imageData,
                    firstEntryDate: firstEntryDate,
                    modelContext: modelContext)
                dismiss()
            }
            .disabled(capturedImage == nil)
        }
        .navigationTitle("New Page")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
        // Load the picked photo's bytes into capturedImage. loadTransferable
        // is async, so we get a Task-style handler; Task { @MainActor } hops
        // the result back onto the main actor where @State can be mutated.
        .onChange(of: photosPickerItem) {
            Task { @MainActor in
                guard let photosPickerItem else { return }
                do {
                    capturedImage = try await photosPickerItem.loadTransferable(
                        type: Data.self)
                } catch {
                    capturedImage = nil
                }
            }
        }
    }
}
