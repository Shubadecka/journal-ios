import SwiftUI
import SwiftData

// Verification screen shared by ImportView and CaptureView — the tail of
// those sheets, so camera capture can keep appending photos while the sheet
// stays open and the photo picker can be re-opened. One photo per page; the
// pages fill the sheet between the page-edit buttons (top) and the
// action buttons (bottom) and are swiped horizontally; the selected page
// offers Rotate/Crop/Remove, plus Undo (disabled until edited). Edits live in
// memory only — originals are enqueued untouched unless the draft was edited,
// and nothing is persisted or enqueued until Transcribe is tapped. Removing
// a photo needs no confirmation: nothing exists outside this in-memory list
// (the picked/captured originals are untouched on disk), and re-picking
// replaces the list wholesale anyway.
struct PageReviewView<Accessory: View>: View {
    @Binding var drafts: [PageDraft]
    @Environment(\.modelContext) private var modelContext // DB session
    @Environment(\.dismiss) private var dismiss // Pop this screen
    @Environment(TranscriptionQueue.self) private var queue // Background transcription queue

    @State private var cropTarget: PageDraft?
    // Which page is showing; tagged per draft id so edits and appends never
    // re-index the selection.
    @State private var selectedDraftID: PageDraft.ID?

    // Host-provided control placed at the leading edge of the bottom action
    // row — e.g. ImportView's re-open-the-picker button. Hosts without one
    // take the EmptyView convenience init at the bottom of this file.
    private var accessory: () -> Accessory

    init(drafts: Binding<[PageDraft]>, accessory: @escaping () -> Accessory) {
        self._drafts = drafts
        self.accessory = accessory
    }

    // The page currently showing in the pager; drives the top-bar edit buttons.
    private var selectedDraft: Binding<PageDraft>? {
        guard let selectedDraftID,
              let index = drafts.firstIndex(where: { $0.id == selectedDraftID })
        else { return nil }
        return $drafts[index]
    }

    var body: some View {
        VStack(spacing: 12) {
            // Closing: on iOS the visible swipe-down grabber is the
            // affordance (RootView sets .presentationDragIndicator(.visible));
            // macOS has no grabber, so it keeps an explicit Cancel top-right.
            #if os(macOS)
            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding([.top, .horizontal], 12)
            #endif

            if let draft = selectedDraft {
                HStack(spacing: 16) {
                    Button {
                        // Repeated taps compose (4× = back to start).
                        var updated = draft.wrappedValue
                        if let rotated = PageImageOps.rotated90CW(updated.working) {
                            updated.working = rotated
                            updated.isEdited = true
                            draft.wrappedValue = updated
                        }
                    } label: {
                        Label("Rotate", systemImage: "rotate.right")
                    }

                    Button {
                        // Struct copy is fine — CGImage is a
                        // reference type, so sheet-internal
                        // edits stay isolated until apply.
                        cropTarget = draft.wrappedValue
                    } label: {
                        Label("Crop", systemImage: "crop")
                    }

                    Button(role: .destructive) {
                        removeDraft(draft.wrappedValue)
                    } label: {
                        Label("Remove", systemImage: "trash")
                    }

                    Button {
                        // Re-decode from the original bytes
                        // instead of caching a second
                        // CGImage per draft. A decode
                        // failure is a no-op, never a crash.
                        // Member-wise on purpose: a fresh PageDraft
                        // gets a new id, and the pager keys on id.
                        var updated = draft.wrappedValue
                        if let original = PageDraft(originalData: updated.originalData) {
                            updated.working = original.working
                            updated.isEdited = false
                            draft.wrappedValue = updated
                        }
                    } label: {
                        Label("Undo", systemImage: "arrow.uturn.backward")
                    }
                    // Always present; greyed out until the page was edited.
                    .disabled(!draft.wrappedValue.isEdited)
                }
                .padding(.top, 16)
            }

            if drafts.isEmpty {
                Rectangle()
                    .fill(.secondary)
                    .overlay(Text("No photos yet"))
                    .frame(maxHeight: .infinity)
            } else {
                // One photo per page, swiped horizontally with native
                // page-snap scrolling. TabView's .page style is unavailable
                // on macOS, so paging is scroll-based: each page is exactly
                // the viewport wide, and the scroll position binding IS the
                // selection — swipes update it, Remove sets it programmatically.
                ScrollView(.horizontal) {
                    HStack(spacing: 0) {
                        ForEach($drafts) { $draft in
                            // Upright by construction (EXIF baked in at
                            // decode), so no orientation handling here.
                            Image(decorative: draft.working, scale: 1, orientation: .up)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .padding(.vertical, 8)
                                .containerRelativeFrame(.horizontal)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollPosition(id: $selectedDraftID)
                .scrollTargetBehavior(.paging)
                .scrollIndicators(.never)
                .frame(maxHeight: .infinity)
                .onChange(of: drafts.count, initial: true) { _, _ in
                    // Net for every list change other than Remove (which
                    // lands on the neighbor itself): keep the selection
                    // pointing at a real photo.
                    if !drafts.contains(where: { $0.id == selectedDraftID }) {
                        selectedDraftID = drafts.first?.id
                    }
                }
            }

            // Swipe affordance: which page is showing out of how many.
            if drafts.count > 1,
               let selected = selectedDraftID,
               let index = drafts.firstIndex(where: { $0.id == selected }) {
                Text("\(index + 1) / \(drafts.count)")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                accessory()
                Spacer()
                Button("Transcribe All") {
                    // Enqueue one job per photo and close immediately —
                    // the user is never blocked waiting on the model. The date
                    // picker was dropped from this screen: undated entries infer
                    // today at save time and keep their needsReview flag.
                    guard !drafts.isEmpty else { return }
                    for draft in drafts {
                        // Edited drafts encode once, here; the fallback keeps a
                        // near-impossible encode failure from dropping a photo.
                        let data = draft.isEdited
                            ? (PageImageOps.jpegData(from: draft.working) ?? draft.originalData)
                            : draft.originalData
                        queue.enqueue(
                            imageData: data,
                            fallbackDate: Date.now,
                            modelContext: modelContext)
                    }
                    dismiss()
                }
                .disabled(drafts.isEmpty)
                .buttonStyle(.borderedProminent)
            }
            .padding([.horizontal, .bottom], 12)
        }
        .sheet(item: $cropTarget) { draft in
            CropSheet(draft: draft) { cropped in
                if let index = drafts.firstIndex(where: { $0.id == draft.id }) {
                    drafts[index].working = cropped
                    drafts[index].isEdited = true
                }
            }
        }
    }

    private func removeDraft(_ draft: PageDraft) {
        guard let index = drafts.firstIndex(where: { $0.id == draft.id }) else { return }
        drafts.remove(at: index)
        // Land on the photo that took this one's place, or on the new last.
        withAnimation {
            selectedDraftID = drafts.isEmpty ? nil : drafts[min(index, drafts.count - 1)].id
        }
    }
}

extension PageReviewView where Accessory == EmptyView {
    // For hosts with no leading action-row control (CaptureView).
    init(drafts: Binding<[PageDraft]>) {
        self.init(drafts: drafts, accessory: { EmptyView() })
    }
}
