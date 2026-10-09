import SwiftUI
import SwiftData

struct EntryListView: View {
    @Query(sort: \JournalEntry.date, order: .reverse) var entries: [JournalEntry]
    @State private var searchText = ""

    var filteredEntries: [JournalEntry] {
        if searchText.isEmpty {
            return entries
        } else {
            return entries.filter { $0.text.localizedStandardContains(searchText) }
        }
    }

    var body: some View {
        NavigationStack {
            List(filteredEntries) { entry in
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
            }
            .searchable(text: $searchText)
            .navigationTitle("Journal Entries")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink {
                        CaptureView()
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
    }
}