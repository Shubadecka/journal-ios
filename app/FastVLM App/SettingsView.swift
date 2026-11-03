import SwiftUI
import SwiftData
import FoundationModels

struct SettingsView: View {
    @Query private var pages: [JournalPage]
    @Query private var entries: [JournalEntry]

    // Same gate TranscriptionService enforces before every pass.
    private var engineAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    var body: some View {
        Form {
            Section("Transcription engine") {
                LabeledContent("Apple Intelligence") {
                    Text(engineAvailable ? "Available" : "Unavailable")
                        .foregroundStyle(engineAvailable ? Color.secondary : Color.red)
                }
                Text("All transcription runs on-device; nothing leaves your device.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Library") {
                LabeledContent("Pages", value: "\(pages.count)")
                LabeledContent("Entries", value: "\(entries.count)")
                LabeledContent("Flagged for review",
                               value: "\(entries.filter(\.needsReview).count)")
            }

            Section("Version") {
                LabeledContent("Journal", value: appVersion)
            }

            Section("About") {
                Text("""
                The FastVLM/LLaVA code retained in the repository is vendored \
                under the Apache-2.0 / Apple research license and is not used \
                by the app. The shipping transcription engine is Apple \
                Intelligence, running entirely on-device.
                """)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(nil)
            }
        }
        .navigationTitle("Settings")
    }
}
