import SwiftUI
import SwiftData

// Shared dirty flag: EntryDetailView publishes pending edits, RootView reads
// it before switching tabs (the one navigation path this view can't see).
@MainActor @Observable
final class UnsavedChangesGate {
    var hasUnsavedChanges = false
}

// Entry detail: committed date in the top bar (editable in place), the
// committed text below with pencil edits, Save writes the drafts to
// SwiftData, "Go to Page" pushes the page screen, and "View Source Page"
// opens a pinch-zoomable pop-up of the page image. Unsaved edits gate every
// unguarded way out (back, tab switch, Go to Page) with a discard warning;
// only Save touches the model.
struct EntryDetailView: View {
    let entry: JournalEntry
    // Path of the entries stack: "Go to Page" pushes the page onto it, and
    // the bottom bar pops the stack back to the list.
    @Binding var entriesPath: NavigationPath
    @Environment(UnsavedChangesGate.self) private var gate
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    // Drafts live only in @State — SwiftData's mainContext autosaves, so
    // touching the model before Save would flush uncommitted edits.
    @State private var draftText: String
    @State private var draftDate: Date
    @State private var editingDate = false
    @State private var editingText = false
    // Tracks the text editor's keyboard focus so entering edit mode claims
    // the keyboard immediately.
    @FocusState private var textFocused: Bool
    @State private var showPageSheet = false
    // Set when the trash button is tapped; shows the delete confirmation.
    @State private var confirmingDelete = false
    @State private var pendingLeave: PendingLeave?
    @State private var queuedLeave: PendingLeave?

    private enum PendingLeave {
        case back
        case goToPage(JournalPage)
    }

    init(entry: JournalEntry, entriesPath: Binding<NavigationPath>) {
        self.entry = entry
        _entriesPath = entriesPath
        _draftText = State(initialValue: entry.text)
        _draftDate = State(initialValue: entry.date)
    }

    private var isDirty: Bool {
        draftText != entry.text || draftDate != entry.date
    }

    // Defensive only: deleting a page cascades its entries, so a live entry
    // always has at least one page. Multi-page entries open the first page.
    private var targetPage: JournalPage? {
        entry.pages.first
    }

    // The entry text field. Grows only as the text inside it grows; the
    // action row is pinned below the scroll content as a VStack sibling in
    // body. The entry date lives in the top bar (see the principal toolbar
    // item).
    private var fieldStack: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                // One full-width box in BOTH modes: a vertical-axis TextField
                // matches the display Text's metrics, so toggling edit moves
                // neither the border nor its size — it grows only when the
                // text itself gains lines.
                Group {
                    if editingText {
                        TextField("", text: $draftText, axis: .vertical)
                            .font(.title3)
                            .focused($textFocused)
                            .padding(8)
                    } else {
                        Text(entry.text)
                            .font(.title3)
                            .padding(8)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.separator, lineWidth: 1)
                )
                Button {
                    editingText.toggle()
                } label: {
                    Label("Edit Entry", systemImage: "pencil")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
            }

        }
    }

    // Action row, pinned under the scroll view as a VStack sibling in body;
    // keyboard avoidance lifts the whole stack, so the row sits flush above
    // the keyboard.
    private var actionRow: some View {
        HStack {
            Button("View Source Page") {
                showPageSheet = true
            }
            .buttonStyle(.bordered)
            .disabled(targetPage == nil)
            Spacer()
            Button("Save") {
                save()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!isDirty)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                fieldStack
                    .padding()
            }
            actionRow
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 4)
        }
        .toolbar {
            // The system back button can't be intercepted — hide it (this
            // also kills the unguarded iOS edge-swipe) and provide this one;
            // macOS back navigation uses the same button. .navigation is the
            // cross-platform nav-bar-leading placement: .topBarLeading is
            // macOS-unavailable and the old .leading is gone on macOS 27.
            ToolbarItem(placement: .navigation) {
                Button {
                    tryLeave(.back)
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
            }
            ToolbarItem(placement: .principal) {
                // The entry date lives in the title slot: the committed date
                // in display mode, a compact picker while editing (pencil).
                Group {
                    if editingDate {
                        DatePicker("Date", selection: $draftDate, displayedComponents: .date)
                            .labelsHidden()
                    } else {
                        HStack(spacing: 8) {
                            Text(entry.date, style: .date)
                                .font(.headline)
                            Button {
                                editingDate.toggle()
                            } label: {
                                Label("Edit Date", systemImage: "pencil")
                                    .labelStyle(.iconOnly)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button(role: .destructive) {
                    confirmingDelete = true
                } label: {
                    Label("Delete", systemImage: "trash")
                        .labelStyle(.iconOnly)
                }
            }
        }
        .navigationDestination(for: JournalPage.self) { page in
            PageDetailView(page: page)
        }
        .sheet(isPresented: $showPageSheet, onDismiss: {
            if let dest = queuedLeave {
                queuedLeave = nil
                tryLeave(dest)
            }
        }) {
            if let page = targetPage {
                NavigationStack {
                    VStack(spacing: 0) {
                        ZoomablePageImageView(page: page)
                        HStack {
                            Spacer()
                            Button("Go to Page") {
                                queuedLeave = .goToPage(page)
                                showPageSheet = false
                            }
                            .buttonStyle(.borderedProminent)
                            Spacer()
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                    }
                }
                .presentationDragIndicator(.visible)
            }
        }
        .alert(
            "Unsaved Changes",
            isPresented: Binding(
                get: { pendingLeave != nil },
                set: { if !$0 { pendingLeave = nil } }),
            presenting: pendingLeave)
        { leave in
            Button("Cancel", role: .cancel) { }
                .keyboardShortcut(.defaultAction)
            Button("Discard Changes", role: .destructive) {
                discardAndLeave(leave)
            }
        } message: { _ in
            Text("Your changes will be discarded if you leave without saving.")
        }
        .alert(
            "Delete Entry?",
            isPresented: $confirmingDelete)
        {
            Button("Cancel", role: .cancel) { }
                .keyboardShortcut(.defaultAction)
            Button("Delete", role: .destructive) {
                modelContext.delete(entry)
                dismiss()
            }
        } message: {
            Text("This permanently deletes this entry. This cannot be undone.")
        }
        .navigationBarBackButtonHidden(true)
        #if os(iOS)
        // Inline keeps the compact bar: no title is set, the date lives in
        // the content (same reason as PageDetailView).
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onChange(of: isDirty) { _, dirty in
            gate.hasUnsavedChanges = dirty
        }
        .onChange(of: editingText) { _, editing in
            // Inserting the field no longer auto-focuses once a .focused
            // binding is attached — claim focus explicitly so the keyboard is
            // up the moment the pencil is tapped.
            if editing {
                textFocused = true
            }
        }
        .onAppear {
            gate.hasUnsavedChanges = isDirty
        }
        // Also fires when PageDetailView is pushed on top — safe because Go
        // to Page only pushes after the draft was reset (isDirty false).
        .onDisappear {
            gate.hasUnsavedChanges = false
        }
    }

    private func tryLeave(_ dest: PendingLeave) {
        if isDirty {
            pendingLeave = dest
        } else {
            commitLeave(dest)
        }
    }

    private func discardAndLeave(_ dest: PendingLeave) {
        draftText = entry.text
        draftDate = entry.date
        editingDate = false
        editingText = false
        commitLeave(dest)
    }

    private func commitLeave(_ dest: PendingLeave) {
        switch dest {
        case .back:
            dismiss()
        case .goToPage(let page):
            entriesPath.append(page)
        }
    }

    private func save() {
        let wasDirty = isDirty
        entry.text = draftText
        if draftDate != entry.date {
            entry.date = draftDate
        }
        // A saved change of either field is user-confirmed content — a text
        // edit clears the review flag too, not just a date edit.
        if wasDirty {
            entry.needsReview = false
        }
        editingDate = false
        editingText = false
    }
}

// Pop-up page image with pinch zoom (clamped to 1×–8×); the frame grows with
// the zoom so ScrollView pans naturally when zoomed in and can't drift at 1×.
struct ZoomablePageImageView: View {
    let page: JournalPage
    @Environment(\.dismiss) private var dismiss
    @State private var image: CGImage?
    @State private var decodeFailed = false
    @State private var zoom: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1

    var body: some View {
        Group {
            if let cgImage = image {
                zoomableImage(cgImage)
            } else if decodeFailed {
                Text("Preview unavailable")
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Close") {
                    dismiss()
                }
            }
        }
        .task {
            // Decode once, not per render.
            if let decoded = pageThumbnail(from: page.imageData, maxPixelSize: 2400) {
                image = decoded
            } else {
                decodeFailed = true
            }
        }
    }

    private func zoomableImage(_ cgImage: CGImage) -> some View {
        GeometryReader { geo in
            let fit = min(geo.size.width / CGFloat(cgImage.width),
                          geo.size.height / CGFloat(cgImage.height))
            ScrollView([.horizontal, .vertical]) {
                Image(decorative: cgImage, scale: 1)
                    .resizable()
                    .frame(width: CGFloat(cgImage.width) * fit * zoom * pinch,
                           height: CGFloat(cgImage.height) * fit * zoom * pinch)
                    .gesture(
                        MagnifyGesture()
                            .updating($pinch) { value, state, _ in
                                state = value.magnification
                            }
                            .onEnded { value in
                                zoom = min(max(zoom * value.magnification, 1), 8)
                            })
            }
        }
    }
}
