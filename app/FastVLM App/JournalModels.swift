import Foundation
import SwiftData

@Model
class JournalPage {
    // Unique id for the page
    @Attribute(.unique) 
    var id: UUID

    // Page data
    var imageData: Data
    var firstEntryDate: Date
    var fullTranscription: String
    var createdAt: Date
    var updatedAt: Date

    // One page has many entries, so this is an inverse relationship
    @Relationship(deleteRule: .cascade, inverse: \JournalEntry.pages)
    var entries: [JournalEntry] = []

    init(imageData: Data, firstEntryDate: Date) {
        self.id = UUID()
        self.imageData = imageData
        self.firstEntryDate = firstEntryDate
        self.fullTranscription = ""
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}

@Model
class JournalEntry {
    // Unique id for the entry
    @Attribute(.unique)
    var id: UUID
    var text: String  // Extracted by the model from the image
    var date: Date  // Date of the entry
    var orderInPage: Int  // Order in the page, 0-indexed
    // True when the date was inferred (not explicitly parsed from the model
    // output) — these entries get a red border in the list so the user can
    // review and fix the date whenever they want.
    var needsReview: Bool
    var pages: [JournalPage] = []  // One entry can be in multiple pages

    init(text: String, date: Date, orderInPage: Int, needsReview: Bool = false) {
        self.id = UUID()
        self.text = text
        self.date = date
        self.orderInPage = orderInPage
        self.needsReview = needsReview
    }
}
