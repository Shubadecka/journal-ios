import Foundation
import CoreGraphics
import ImageIO
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

// One pending page photo in the verification screen (PageReviewView).
// `originalData` keeps the exactly-as-captured/uploaded bytes and is never
// mutated or overwritten; `working` is the upright decoded image that
// Rotate/Crop act on. JPEG encoding happens exactly once, at Transcribe time,
// and only for drafts that were actually edited — unedited drafts enqueue
// their original bytes bit-identical.
struct PageDraft: Identifiable {
    let id = UUID()
    let originalData: Data
    var working: CGImage
    var isEdited: Bool

    // Failable: a photo whose bytes won't decode is skipped by the caller
    // (same skip-failed-load behavior the import flow has always had).
    init?(originalData: Data) {
        self.originalData = originalData

        // Decode upright: baking the EXIF orientation into the pixels makes
        // every later op (rotate/crop) pure pixel math, so re-encoded JPEGs
        // need no EXIF. maxPixelSize = max pixel dimension forces full-size
        // output — an unqualified thumbnail call may downscale.
        guard let source = CGImageSourceCreateWithData(originalData as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let pixelWidth = properties[kCGImagePropertyPixelWidth] as? Int,
              let pixelHeight = properties[kCGImagePropertyPixelHeight] as? Int,
              pixelWidth > 0, pixelHeight > 0,
              let cgImage = CGImageSourceCreateThumbnailAtIndex(
                  source, 0,
                  [kCGImageSourceCreateThumbnailFromImageAlways: true,
                   kCGImageSourceCreateThumbnailWithTransform: true,
                   kCGImageSourceThumbnailMaxPixelSize: max(pixelWidth, pixelHeight)] as CFDictionary)
        else { return nil }
        self.working = cgImage
        self.isEdited = false
    }
}

// Lossless pixel operations on `PageDraft.working`. All CoreGraphics/ImageIO —
// no UIKit-only geometry — so the macOS target keeps working.
enum PageImageOps {
    // Rotate 90° clockwise: dest size is (height, width) of the source. The
    // translate/rotate maps the source top-left corner to the dest top-right
    // (clockwise). Drawing into an sRGB context converts any source
    // colorspace/alpha (CMYK/grayscale sources can't back an alpha bitmap
    // context of their own colorspace); the JPEG encoder flattens the
    // resulting alpha.
    static func rotated90CW(_ image: CGImage) -> CGImage? {
        guard let ctx = CGContext(
            data: nil,
            width: image.height,
            height: image.width,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(image.width))
        ctx.rotate(by: -.pi / 2)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage()
    }

    // Crop to a pixel rect in top-left-origin coordinates (the convention
    // CGImage.cropping(to:) expects). Clamped to the image bounds and rounded
    // to whole pixels; an empty result fails so the caller can ignore it.
    static func cropped(_ image: CGImage, to pixelRect: CGRect) -> CGImage? {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let rect = pixelRect.intersection(bounds).integral
        guard !rect.isEmpty, rect.width >= 1, rect.height >= 1 else { return nil }
        return image.cropping(to: rect)
    }

    // The single encode point for edited drafts. Quality 0.9: page photos are
    // re-read by a VLM, so fidelity beats file size.
    static func jpegData(from image: CGImage) -> Data? {
        #if canImport(UIKit)
        UIImage(cgImage: image).jpegData(compressionQuality: 0.9)
        #else
        NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [:])
        #endif
    }
}
