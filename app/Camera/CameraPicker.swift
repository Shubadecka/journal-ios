import SwiftUI
import UIKit

// Bridges the UIKit camera screen into SwiftUI. The system screen provides
// the shutter, flash, and first-run permission prompt for free.
struct CameraPicker: UIViewControllerRepresentable {
    // Called with JPEG bytes once the user confirms a photo.
    let onImage: (Data) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onImage: onImage)
    }

    // UIKit reports results through delegate callbacks; the Coordinator is
    // the object SwiftUI keeps alive to receive them.
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onImage: (Data) -> Void

        init(onImage: @escaping (Data) -> Void) {
            self.onImage = onImage
        }

        // "Use Photo" tapped.
        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            picker.dismiss(animated: true)
            guard let image = info[.originalImage] as? UIImage,
                  let jpeg = image.jpegData(compressionQuality: 0.9) else { return }
            onImage(jpeg)
        }

        // "Cancel" tapped — nothing to deliver.
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }
    }
}