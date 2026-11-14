import SwiftUI
import SwiftData

struct EntryListView: View {
    @Query(sort: \JournalEntry.date, order: .reverse) var entries: [JournalEntry]
    @Environment(\.modelContext) private var modelContext
    @State private var searchText = ""
    // The entry whose trash button was tapped; non-nil shows the dialog.
    @State private var pendingDelete: JournalEntry?
    // Navigation stack of the Entries tab: rows push onto it, and the bottom
    // bar pops it back to this list.
    @Binding var entriesPath: NavigationPath

    var filteredEntries: [JournalEntry] {
        if searchText.isEmpty {
            return entries
        } else {
            return entries.filter { $0.text.localizedStandardContains(searchText) }
        }
    }

    #if os(iOS)
    // Search header visibility: hidden once the list scrolls down, restored
    // by ANY upward scroll. Suppressed while the field is focused or a query
    // is active, so scrolling never hides an in-progress search.
    @State private var searchVisible = true
    @FocusState private var searchFocused: Bool
    // The List's top inset settles right after each appear with upward offset
    // steps that look like downward scrolls; hides stay suppressed until it
    // settles (~1s).
    @State private var scrollSettled = false

    // The list-integrated search header. Replaces .searchable's field, whose
    // nav-bar drawer hides on downward scroll but doesn't re-reveal until the
    // list is back at the top.
    private var searchHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search", text: $searchText)
                .focused($searchFocused)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var searchHeaderInset: some View {
        VStack(spacing: 0) {
            if searchVisible {
                searchHeader
                    .transition(.opacity)
            }
        }
        .animation(.snappy(duration: 0.25), value: searchVisible)
    }

    private func updateSearchVisibility(newValue: CGFloat, oldValue: CGFloat) {
        guard abs(newValue - oldValue) > 1 else { return }
        if newValue < oldValue {
            searchVisible = true
        } else if scrollSettled, !searchFocused, searchText.isEmpty {
            searchVisible = false
        }
    }
    #endif

    var body: some View {
        List(filteredEntries) { entry in
            HStack {
                Button {
                    entriesPath.append(entry)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(entry.date, style: .date)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            // Red badge marks entries whose date was inferred, not
                            // parsed from the transcription — review those.
                            if entry.needsReview {
                                Text("Needs Review")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(.red))
                            }
                        }
                        Text(entry.text)
                            .lineLimit(5)
                    }
                    .padding(.vertical, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer()

                Button(role: .destructive) {
                    pendingDelete = entry
                } label: {
                    Label("Delete", systemImage: "trash")
                        .labelStyle(.iconOnly)
                }
                // List-row gotcha: without a borderless style the whole row
                // would trigger the button on iOS.
                .buttonStyle(.borderless)
            }
        }
        #if os(iOS)
        // Raw contentOffset: SwiftUI does not compensate it when a
        // safeAreaInset resizes, so header show/hide never feeds back into
        // this logic — only real content scrolls reach it.
        .onScrollGeometryChange(for: CGFloat.self) { geo in
            geo.contentOffset.y
        } action: { oldValue, newValue in
            updateSearchVisibility(newValue: newValue, oldValue: oldValue)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            searchHeaderInset
        }
        .task {
            scrollSettled = false
            try? await Task.sleep(for: .seconds(1))
            scrollSettled = true
        }
        #else
        .searchable(text: $searchText)
        #endif
        .navigationDestination(for: JournalEntry.self) { entry in
            EntryDetailView(entry: entry, entriesPath: $entriesPath)
        }
        .alert(
            "Delete Entry?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete)
        { entry in
            Button("Cancel", role: .cancel) { }
                .keyboardShortcut(.defaultAction)
            Button("Delete", role: .destructive) {
                modelContext.delete(entry)
            }
        } message: { entry in
            Text("This permanently deletes this entry. This cannot be undone.")
        }
        .navigationTitle("Journal Entries")
        #if os(iOS)
        // Compact centered bar title: the large-title mode reserves a big
        // empty block between the bar and the content.
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
