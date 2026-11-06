import SwiftUI

struct CaptureView: View {
    // Closing is the sheet's swipe-down grabber (RootView presents it visible).
    @State private var drafts: [PageDraft] = []
    @State private var showCamera = false

    // UIImagePickerController needs real camera hardware and the UIKit
    // camera screen — unavailable on macOS, which has library-import only.
    private var cameraAvailable: Bool {
        #if canImport(UIKit)
        UIImagePickerController.isSourceTypeAvailable(.camera)
        #else
        false
        #endif
    }

    var body: some View {
        VStack(spacing: 20) {
            PageReviewView(drafts: $drafts)

            if cameraAvailable {
                Button {
                    showCamera = true
                } label: {
                    Label("Take photo(s)", systemImage: "camera")
                }
            }
        }
        .navigationTitle("New Page")
        // Each confirmed capture APPENDS a page photo, so the user can
        // photograph several pages before transcribing them all at once.
        #if canImport(UIKit)
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { imageData in
                // A failed decode is skipped, same as a failed load in the
                // import flow.
                if let draft = PageDraft(originalData: imageData) {
                    drafts.append(draft)
                }
            }
        }
        #endif
    }
}