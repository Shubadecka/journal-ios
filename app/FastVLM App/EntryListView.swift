import SwiftUI
import SwiftData

struct EntryListView: View {
    @Query(sort: \JournalEntry.date, order: .reverse) var entries: [JournalEntry]
    @Environment(\.modelContext) private var modelContext
    @State private var searchText = ""
    // The entry whose trash button was tapped; non-nil shows the dialog.
    @State private var pendingDelete: JournalEntry?

    var filteredEntries: [JournalEntry] {
        if searchText.isEmpty {
            return entries
        } else {
            return entries.filter { $0.text.localizedStandardContains(searchText) }
        }
    }

    var body: some View {
        List(filteredEntries) { entry in
            HStack {
                VStack(alignment: .leading) {
                    Text(entry.date, style: .date)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(entry.text)
                        .lineLimit(3)
                }
                // Red border marks entries whose date was inferred, not parsed
                // from the transcription — the user should review those.
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(entry.needsReview ? Color.red : Color.clear, lineWidth: 2)
                )
                .padding(.vertical, 2)

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
        .searchable(text: $searchText)
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
    }
}
