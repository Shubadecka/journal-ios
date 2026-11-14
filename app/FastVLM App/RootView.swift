import SwiftUI

enum AppTab: Hashable { case entries, pages, settings }

enum NewPageSheet: Identifiable {
    case importPhotos, takePhoto
    var id: Self { self }
}

// App shell: pinned transcription banner above the tab content, bottom bar
// below. One NavigationStack per tab — .searchable and PageDetailView's
// .navigationDestination each need their own stack.
struct RootView: View {
    @State private var selectedTab: AppTab = .entries
    @State private var newSheet: NewPageSheet?
    // EntryDetailView publishes pending edits here; a tab switch with the
    // flag set asks for confirmation first (pendingTab drives the alert).
    @State private var unsavedGate = UnsavedChangesGate()
    @State private var pendingTab: AppTab?
    // Per-tab navigation stacks, owned here so the bottom bar can pop a tab
    // back to its root screen.
    @State private var entriesPath = NavigationPath()
    @State private var pagesPath = NavigationPath()

    var body: some View {
        VStack(spacing: 0) {
            // Zero-height when the queue is idle (banner's body is empty).
            TranscriptionBanner()
            Group {
                switch selectedTab {
                case .entries:  NavigationStack(path: $entriesPath) { EntryListView(entriesPath: $entriesPath) }
                case .pages:    NavigationStack(path: $pagesPath) { PageView(pagesPath: $pagesPath) }
                case .settings: NavigationStack { SettingsView() }
                }
            }
            // Regular layout child, not a bottom safeAreaInset: on iOS 27 the
            // inset's expanded safe area doesn't reach pushed NavigationStack
            // content, so a pushed screen's own bottom row (EntryDetailView's
            // "View Source Page") laid out under this bar and silently
            // vanished. As a plain VStack child the bar bounds the tab
            // content directly.
            BottomBar(selectedTab: $selectedTab, newSheet: $newSheet) {
                selectTab($0)
            }
            // The shell bar must not dodge the keyboard: when the keyboard
            // shows, the bar stays at the screen bottom and gets covered,
            // instead of floating above it.
            .ignoresSafeArea(.keyboard, edges: .bottom)
        }
        .environment(unsavedGate)
        .sheet(item: $newSheet) { sheet in
            Group {
                switch sheet {
                case .importPhotos: ImportView()
                case .takePhoto:    CaptureView()
                }
            }
            // Visible grabber: swiping down is the sheet's close affordance.
            .presentationDragIndicator(.visible)
        }
        .alert(
            "Unsaved Changes",
            isPresented: Binding(
                get: { pendingTab != nil },
                set: { if !$0 { pendingTab = nil } }),
            presenting: pendingTab)
        { tab in
            Button("Cancel", role: .cancel) { }
                .keyboardShortcut(.defaultAction)
            // Leaving (or popping) with edits destroys the draft state —
            // clearing the gate is enough.
            Button("Discard Changes", role: .destructive) {
                unsavedGate.hasUnsavedChanges = false
                performGo(tab)
            }
        } message: { _ in
            Text("Your changes will be discarded if you leave without saving.")
        }
    }

    private func selectTab(_ tab: AppTab) {
        if unsavedGate.hasUnsavedChanges {
            pendingTab = tab
        } else {
            performGo(tab)
        }
    }

    // Bottom-bar destination: a different tab switches; the current tab pops
    // back to its root screen (e.g. EntryDetailView → the entries list).
    private func performGo(_ tab: AppTab) {
        if tab == selectedTab {
            switch tab {
            case .entries: entriesPath = NavigationPath()
            case .pages: pagesPath = NavigationPath()
            case .settings: break
            }
        } else {
            selectedTab = tab
        }
    }
}

struct BottomBar: View {
    @Binding var selectedTab: AppTab
    @Binding var newSheet: NewPageSheet?
    // Routed through RootView so a pending unsaved-changes state can hold
    // the switch (plusButton needs no guard: the New sheet overlays the
    // detail view without destroying it).
    let requestTab: (AppTab) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                tabButton(.entries, icon: "book.closed", label: "Entries")
                tabButton(.pages, icon: "photo.on.rectangle.angled", label: "Pages")
                plusButton
                tabButton(.settings, icon: "gearshape", label: "Settings")
            }
            .padding(.vertical, 8)
        }
        .background(.regularMaterial, ignoresSafeAreaEdges: .bottom)
    }

    private func tabButton(_ tab: AppTab, icon: String, label: LocalizedStringKey) -> some View {
        Button {
            requestTab(tab)
        } label: {
            VStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.title3)
                Text(label)
                    .font(.caption2)
            }
            .frame(maxWidth: .infinity)
            .foregroundStyle(selectedTab == tab ? Color.accentColor : Color.secondary)
        }
    }

    private var plusButton: some View {
        Menu {
            Button("Import photo(s)", systemImage: "photo.on.rectangle") {
                newSheet = .importPhotos
            }
            // UIImagePickerController needs real camera hardware and the UIKit
            // camera screen — unavailable on macOS, which has library-import
            // only (same gating as CaptureView).
            #if canImport(UIKit)
            Button("Take photo(s)", systemImage: "camera") {
                newSheet = .takePhoto
            }
            #endif
        } label: {
            // Matches the tab buttons: gray while idle like inactive tabs,
            // accent-colored only while a new-page sheet is open.
            VStack(spacing: 2) {
                Image(systemName: "plus")
                    .font(.title3.bold())
                Text("New")
                    .font(.caption2)
            }
            .foregroundStyle(newSheet == nil ? Color.secondary : Color.accentColor)
            .frame(maxWidth: .infinity)
        }
    }
}
