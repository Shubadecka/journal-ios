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

    var body: some View {
        VStack(spacing: 0) {
            // Zero-height when the queue is idle (banner's body is empty).
            TranscriptionBanner()
            Group {
                switch selectedTab {
                case .entries:  NavigationStack { EntryListView() }
                case .pages:    NavigationStack { PageView() }
                case .settings: NavigationStack { SettingsView() }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            BottomBar(selectedTab: $selectedTab, newSheet: $newSheet)
        }
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
    }
}

struct BottomBar: View {
    @Binding var selectedTab: AppTab
    @Binding var newSheet: NewPageSheet?

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
        .background(.regularMaterial)
    }

    private func tabButton(_ tab: AppTab, icon: String, label: LocalizedStringKey) -> some View {
        Button {
            selectedTab = tab
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
