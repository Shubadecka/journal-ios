import SwiftUI
import PhotosUI

struct ImportView: View {
    // Closing is the sheet's swipe-down grabber (RootView presents it visible).
    @State private var pickedItems: [PhotosPickerItem] = []
    @State private var drafts: [PageDraft] = []

    var body: some View {
        PageReviewView(drafts: $drafts) {
            PhotosPicker(selection: $pickedItems,
                         maxSelectionCount: 10,
                         matching: .images) {
                Label("Import Additional Photo(s)", systemImage: "photo.on.rectangle")
            }
        }
        .navigationTitle("New Page")
        .onChange(of: pickedItems) {
            Task { @MainActor in
                var loaded: [PageDraft] = []
                for item in pickedItems {
                    // A failed load or decode is skipped; the Transcribe
                    // button stays disabled while nothing loaded.
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let draft = PageDraft(originalData: data) {
                        loaded.append(draft)
                    }
                }
                drafts = loaded
            }
        }
    }
}