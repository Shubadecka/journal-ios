import SwiftUI
import PhotosUI

struct ImportView: View {
    @State private var pickedItems: [PhotosPickerItem] = []
    @State private var pageImages: [Data] = []

    var body: some View {
        VStack(spacing: 20) {
            TranscribeForm(pageImages: $pageImages)

            PhotosPicker(selection: $pickedItems,
                         maxSelectionCount: 10,
                         matching: .images) {
                Label("Import photo(s)", systemImage: "photo.on.rectangle")
            }
        }
        .navigationTitle("New Page")
        .onChange(of: pickedItems) {
            Task { @MainActor in
                var images: [Data] = []
                for item in pickedItems {
                    // A failed load is skipped; the Transcribe button stays
                    // disabled while nothing loaded.
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        images.append(data)
                    }
                }
                pageImages = images
            }
        }
    }
}