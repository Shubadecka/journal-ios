import SwiftUI
import UIKit

struct CaptureView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var pageImages: [Data] = []
    @State private var showCamera = false

    // UIImagePickerController needs real camera hardware — false in the
    // simulator and on visionOS, where only the library-import path exists.
    private var cameraAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
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
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { imageData in
                pageImages.append(imageData)
            }
        }
    }
}