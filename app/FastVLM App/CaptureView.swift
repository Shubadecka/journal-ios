import SwiftUI

struct CaptureView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var pageImages: [Data] = []
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
            TranscribeForm(pageImages: $pageImages)

            if cameraAvailable {
                Button {
                    showCamera = true
                } label: {
                    Label("Take photo(s)", systemImage: "camera")
                }
            }
        }
        .navigationTitle("New Page")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
        // Each confirmed capture APPENDS a page photo, so the user can
        // photograph several pages before transcribing them all at once.
        #if canImport(UIKit)
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { imageData in
                pageImages.append(imageData)
            }
        }
        #endif
    }
}