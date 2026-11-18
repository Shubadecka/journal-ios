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
    // Non-nil while the list is drilled in from a page detail ("View
    // Entries"): shows only that page's entries, with the clear chip above
    // the search bar.
    @Binding var pageFilter: JournalPage?

    var filteredEntries: [JournalEntry] {
        // Page drill-in filter (from PageDetailView) composes with search text.
        // Sort matches the @Query's date-reverse ordering.
        let base = if let pageFilter {
            pageFilter.entries.sorted { $0.date > $1.date }
        } else {
            entries
        }
        if searchText.isEmpty { return base }
        return base.filter { $0.text.localizedStandardContains(searchText) }
    }

    // Small dismiss affordance shown above the search bar while the list is
    // filtered to one page's entries.
    private var clearFilterChip: some View {
        Button {
            pageFilter = nil
        } label: {
            Label("Clear Filter", systemImage: "xmark.circle.fill")
                .font(.footnote.weight(.semibold))
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
    }

    #if os(iOS)
    // True while the search field has the keyboard; the checkmark in the
    // accessory bar above the keyboard writes false to dismiss it.
    @FocusState private var searchFocused: Bool

    // The list-integrated search header, pinned above the list at all times
    // (no hide-on-scroll: the show/hide toggling was buggy, and a search
    // field that never vanishes needs no scroll bookkeeping). Replaces
    // .searchable's field, whose nav-bar drawer hides on downward scroll but
    // doesn't re-reveal until the list is back at the top.
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
        .background(Color(.systemGray5), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal)
        .padding(.vertical, 8)
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
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 8) {
                if pageFilter != nil {
                    clearFilterChip
                        .padding(.top, 8)
                }
                searchHeader
            }
        }
        // Blue checkmark inside the system accessory bar above the keyboard
        // (the strip the keyboard reserves for input accessories — the "black
        // bar"): tapping it dismisses the keyboard. ToolbarItemGroup with
        // .keyboard placement is the API that renders INTO that strip; a
        // bottom safeAreaInset can only sit above it.
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button {
                    searchFocused = false
                } label: {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.blue)
                }
            }
        }
        #else
        .searchable(text: $searchText)
        .safeAreaInset(edge: .top, spacing: 0) {
            if pageFilter != nil {
                clearFilterChip
                    .padding(.vertical, 8)
            }
        }
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
