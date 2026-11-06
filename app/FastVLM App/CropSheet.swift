import SwiftUI

// Free-form crop popup over one draft's working image. The image is
// aspect-fit inside a GeometryReader; the crop rect lives in those container
// coordinates and is converted to pixel coordinates only when the user
// commits. Each corner dot owns its own resize gesture and the rect's
// interior owns a move gesture: corner identity comes from which view is
// touched, never from mapping a touch's start location through wrappers.
// All math uses only the gesture's cumulative translation against a snapshot
// taken at gesture start — never an absolute location in a frame that moves
// during the gesture — which is what keeps the motion smooth and
// deterministic. Committing a rect that covers the whole image is treated as
// a no-op, so no phantom Undo appears.
struct CropSheet: View {
    let draft: PageDraft
    let onApply: (CGImage) -> Void

    @Environment(\.dismiss) private var dismiss

    // Container coordinates.
    @State private var cropRect: CGRect = .zero
    @State private var fittedFrame: CGRect = .zero
    @State private var didSetInitial = false
    // Rect snapshot at drag start; nil while idle. Single snapshot is safe:
    // touches are single, and every gesture clears it on end.
    @State private var gestureStartRect: CGRect?

    static let minSide: CGFloat = 40
    // Invisible touch target per corner dot; visible dot stays 14pt.
    static let handleHitSide: CGFloat = 44

    enum Corner { case topLeft, topRight, bottomLeft, bottomRight }

    private var imageSize: CGSize {
        CGSize(width: draft.working.width, height: draft.working.height)
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                ZStack {
                    imageLayer
                    scrims
                    moveSurface
                    cropBorder
                    handles
                }
                .onChange(of: geo.size, initial: true) { _, newSize in
                    layoutChanged(Self.fittedFrame(imageSize: imageSize, container: newSize))
                }
            }
            .navigationTitle("Crop")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Crop") { applyCrop() }
                }
            }
        }
    }

    // MARK: - Layers

    private var imageLayer: some View {
        Image(decorative: draft.working, scale: 1, orientation: .up)
            .resizable()
            .scaledToFit()
            .frame(width: fittedFrame.width, height: fittedFrame.height)
            .position(x: fittedFrame.midX, y: fittedFrame.midY)
    }

    // Everything outside the crop rect, inside the image frame.
    @ViewBuilder private var scrims: some View {
        scrim(CGRect(x: fittedFrame.minX, y: fittedFrame.minY,
                     width: max(0, cropRect.minX - fittedFrame.minX),
                     height: fittedFrame.height))
        scrim(CGRect(x: cropRect.maxX, y: fittedFrame.minY,
                     width: max(0, fittedFrame.maxX - cropRect.maxX),
                     height: fittedFrame.height))
        scrim(CGRect(x: fittedFrame.minX, y: fittedFrame.minY,
                     width: fittedFrame.width,
                     height: max(0, cropRect.minY - fittedFrame.minY)))
        scrim(CGRect(x: fittedFrame.minX, y: cropRect.maxY,
                     width: fittedFrame.width,
                     height: max(0, fittedFrame.maxY - cropRect.maxY)))
    }

    @ViewBuilder private func scrim(_ rect: CGRect) -> some View {
        if rect.width > 0, rect.height > 0 {
            Rectangle()
                .fill(Color.black.opacity(0.45))
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
        }
    }

    // Interior of the selection drags the whole rect. The frame tracks
    // cropRect, so the view moves under the finger mid-drag; only
    // value.translation is read, which is coordinate-space-independent.
    private var moveSurface: some View {
        Color.clear
            .frame(width: max(0, cropRect.width), height: max(0, cropRect.height))
            .contentShape(Rectangle())
            .position(x: cropRect.midX, y: cropRect.midY)
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let start = gestureStartRect ?? cropRect
                        if gestureStartRect == nil { gestureStartRect = start }
                        cropRect = Self.moved(start, by: value.translation, in: fittedFrame)
                    }
                    .onEnded { _ in gestureStartRect = nil }
            )
    }

    private var cropBorder: some View {
        Rectangle()
            .stroke(Color.white, lineWidth: 2)
            .frame(width: max(0, cropRect.width), height: max(0, cropRect.height))
            .position(x: cropRect.midX, y: cropRect.midY)
    }

    @ViewBuilder private var handles: some View {
        handle(at: CGPoint(x: cropRect.minX, y: cropRect.minY), corner: .topLeft)
        handle(at: CGPoint(x: cropRect.maxX, y: cropRect.minY), corner: .topRight)
        handle(at: CGPoint(x: cropRect.minX, y: cropRect.maxY), corner: .bottomLeft)
        handle(at: CGPoint(x: cropRect.maxX, y: cropRect.maxY), corner: .bottomRight)
    }

    private func handle(at point: CGPoint, corner: Corner) -> some View {
        Color.clear
            .frame(width: Self.handleHitSide, height: Self.handleHitSide)
            .overlay(
                Circle()
                    .fill(Color.white)
                    .overlay(Circle().stroke(Color.black, lineWidth: 1))
                    .frame(width: 14, height: 14)
            )
            .contentShape(Circle())
            .position(point)
            .gesture(resizeGesture(corner))
    }

    private func resizeGesture(_ corner: Corner) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let start = gestureStartRect ?? cropRect
                if gestureStartRect == nil { gestureStartRect = start }
                cropRect = Self.resized(start, corner: corner, by: value.translation,
                                        in: fittedFrame, minSide: Self.minSide)
            }
            .onEnded { _ in gestureStartRect = nil }
    }

    // MARK: - Geometry (pure, harness-tested)

    // Aspect-fit the image in the container, centered.
    static func fittedFrame(imageSize: CGSize, container: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              container.width > 0, container.height > 0
        else { return .zero }
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            origin: CGPoint(x: (container.width - size.width) / 2,
                            y: (container.height - size.height) / 2),
            size: size)
    }

    // The selection starts as a small centered square the user can grab and
    // expand immediately; a full-image start made resize drags feel dead.
    // Clamped down if the fitted frame is smaller than the square.
    static let initialCropSide: CGFloat = 60

    static func initialCropRect(for fitted: CGRect) -> CGRect {
        let side = Swift.min(initialCropSide, fitted.width, fitted.height)
        return CGRect(x: fitted.midX - side / 2, y: fitted.midY - side / 2,
                      width: side, height: side)
    }

    static func moved(_ rect: CGRect, by translation: CGSize, in bounds: CGRect) -> CGRect {
        guard bounds.width >= rect.width, bounds.height >= rect.height else { return rect }
        let origin = CGPoint(
            x: (rect.minX + translation.width).clamped(to: bounds.minX...(bounds.maxX - rect.width)),
            y: (rect.minY + translation.height).clamped(to: bounds.minY...(bounds.maxY - rect.height)))
        return CGRect(origin: origin, size: rect.size)
    }

    // Move the dragged corner by the gesture translation; the opposite corner
    // of the gesture's starting rect stays fixed. The moving edge never
    // crosses the fixed one and the minimum side is honored as far as the
    // bounds allow.
    static func resized(_ start: CGRect, corner: Corner, by translation: CGSize,
                        in bounds: CGRect, minSide: CGFloat) -> CGRect {
        let startCorner: CGPoint
        let fixed: CGPoint
        switch corner {
        case .topLeft:
            startCorner = CGPoint(x: start.minX, y: start.minY)
            fixed = CGPoint(x: start.maxX, y: start.maxY)
        case .topRight:
            startCorner = CGPoint(x: start.maxX, y: start.minY)
            fixed = CGPoint(x: start.minX, y: start.maxY)
        case .bottomLeft:
            startCorner = CGPoint(x: start.minX, y: start.maxY)
            fixed = CGPoint(x: start.maxX, y: start.minY)
        case .bottomRight:
            startCorner = CGPoint(x: start.maxX, y: start.maxY)
            fixed = CGPoint(x: start.minX, y: start.minY)
        }
        let dragged = CGPoint(
            x: (startCorner.x + translation.width).clamped(to: bounds.minX...bounds.maxX),
            y: (startCorner.y + translation.height).clamped(to: bounds.minY...bounds.maxY))
        // The moving edge stays on the side of `fixed` it started on (no flip),
        // keeps ≥ minSide distance where the bounds allow, otherwise tracks the
        // drag exactly.
        func edge(_ draggedV: CGFloat, _ startV: CGFloat, _ fixedV: CGFloat,
                  _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
            startV <= fixedV
                ? Swift.max(lower, Swift.min(draggedV, fixedV - minSide))
                : Swift.min(upper, Swift.max(draggedV, fixedV + minSide))
        }
        let mx = edge(dragged.x, startCorner.x, fixed.x, bounds.minX, bounds.maxX)
        let my = edge(dragged.y, startCorner.y, fixed.y, bounds.minY, bounds.maxY)
        return CGRect(x: Swift.min(fixed.x, mx), y: Swift.min(fixed.y, my),
                      width: abs(mx - fixed.x), height: abs(my - fixed.y))
    }

    // Container coordinates → top-left-origin pixel coordinates, clamped to
    // the image bounds and rounded to whole pixels.
    static func pixelRect(from cropRect: CGRect, fitted: CGRect,
                          imageWidth: Int, imageHeight: Int) -> CGRect {
        guard fitted.width > 0, fitted.height > 0 else { return .zero }
        let scale = CGFloat(imageWidth) / fitted.width
        let rect = CGRect(
            x: (cropRect.minX - fitted.minX) * scale,
            y: (cropRect.minY - fitted.minY) * scale,
            width: cropRect.width * scale,
            height: cropRect.height * scale)
        return rect.intersection(CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight)).integral
    }

    // MARK: - Layout

    private func layoutChanged(_ fitted: CGRect) {
        // Sheet presentation can report a zero-size container transiently;
        // act only on real geometry. Seeding from a zero frame would strand
        // the crop rect at .zero — all handles collapsed at the top-left and
        // every drag a classified no-op (a zero rect contains nothing).
        guard fitted.width > 0, fitted.height > 0 else { return }
        fittedFrame = fitted
        if !didSetInitial {
            cropRect = Self.initialCropRect(for: fitted)
            didSetInitial = true
        } else if let clamped = clampedToFrame {
            // Window resized mid-edit: keep the rect inside the image.
            cropRect = clamped
        }
    }

    private var clampedToFrame: CGRect? {
        let clamped = cropRect.intersection(fittedFrame)
        return clamped.isEmpty ? nil : clamped
    }

    // MARK: - Commit

    private func applyCrop() {
        let clamped = Self.pixelRect(from: cropRect, fitted: fittedFrame,
                                     imageWidth: draft.working.width,
                                     imageHeight: draft.working.height)
        let bounds = CGRect(x: 0, y: 0, width: draft.working.width, height: draft.working.height)
        if clamped.equalTo(bounds) {
            // Full-image selection: nothing to crop, don't mark the draft edited.
            dismiss()
            return
        }
        if let cropped = PageImageOps.cropped(draft.working, to: clamped) {
            onApply(cropped)
        }
        dismiss()
    }
}

extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        // Swift.-qualified: inside a CGFloat extension, bare min/max would
        // resolve to CGFloat's static members.
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
