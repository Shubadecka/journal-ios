# Implementation Plan: Journal Transcription App

## What we're building

An iOS/macOS app that transcribes handwritten journal pages using FastVLM (an
on-device Vision-Language Model), then separates the transcription into
individual entries that you can search and browse later. Everything runs
on-device — no server, no data leaves the device.

This is a fork of Apple's FastVLM demo app. The existing demo is a live-camera
VLM chat. We're repurposing its model-loading and inference plumbing into a
capture → transcribe → segment → review → save → search workflow.

---

## The data model

Think of this like defining ORM models in SQLAlchemy or Django. SwiftData
(Apple's modern persistence framework) lets you decorate a class with `@Model`
and it automatically creates the database table, handles inserts/queries, and
syncs with SwiftUI views.

Create a new file: `app/FastVLM App/JournalModels.swift`

```swift
import Foundation
import SwiftData

// Like a SQLAlchemy model. @Model tells SwiftData to persist instances.
// "class" not "struct" — SwiftData requires reference types (more on that below).

@Model
class JournalPage {
    @Attribute(.unique) var id: UUID
    var imageData: Data          // the captured/uploaded photo, stored as binary
    var firstEntryDate: Date     // user annotates this when uploading
    var fullTranscription: String  // raw VLM output for the whole page
    var createdAt: Date

    // One page has many entries. Inverse relationship.
    @Relationship(deleteRule: .cascade, inverse: \JournalEntry.pages)
    var entries: [JournalEntry] = []

    init(imageData: Data, firstEntryDate: Date) {
        self.id = UUID()
        self.imageData = imageData
        self.firstEntryDate = firstEntryDate
        self.fullTranscription = ""
        self.createdAt = Date()
    }
}

@Model
class JournalEntry {
    @Attribute(.unique) var id: UUID
    var text: String
    var date: Date               // extracted from the text by the model,
                                 // falls back to the page's firstEntryDate
    var orderInPage: Int         // position within the source page (0, 1, 2...)

    // Many-to-many: an entry can span multiple pages (continues onto next page).
    // This is how we link entries back to their source page(s).
    var pages: [JournalPage] = []

    init(text: String, date: Date, orderInPage: Int) {
        self.id = UUID()
        self.text = text
        self.date = date
        self.orderInPage = orderInPage
    }
}
```

### Why `class` not `struct`?

Swift has two main ways to define a type:
- **`struct`** (value type) — like a Python tuple or a JS primitive. When you
  assign it to a new variable, it's *copied*. Most SwiftUI views are structs.
- **`class`** (reference type) — like a Python object or a JS object. When you
  assign it, you pass a *reference* to the same instance. SwiftData models must
  be classes because the database needs to track a single canonical instance.

### Setting up the database container

In `app/FastVLM App/FastVLMApp.swift`, you tell the app about the models:

```swift
@main
struct FastVLMApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        // This is like telling SQLAlchemy's create_all() which tables to manage.
        // modelContainer creates/opens a SQLite database under the hood.
        .modelContainer(for: [JournalPage.self, JournalEntry.self])
    }
}
```

One line, and every view in the app can now read/write `JournalPage` and
`JournalEntry` objects.

---

## The transcription pipeline

The core flow is two model calls per page:

```
Page image ──Call 1──▶ full transcription ──Call 2──▶ separated entries + dates
   (image→text)                               (text→text)
```

### How the existing model code works

`app/FastVLM App/FastVLMModel.swift` already has the inference plumbing. The key
method is:

```swift
public func generate(_ userInput: UserInput) async -> Task<Void, Never>
```

`UserInput` is a type from the MLX library that bundles a prompt string and
optional images. The current demo always passes an image. For our flow:
- **Call 1** (transcription): pass the page image + the transcription prompt.
- **Call 2** (segmentation): pass *no image*, just the segmentation prompt with
  the transcription text injected. This is a text-only LLM call.

> **Gotcha to test:** The VLM may expect an image token in every prompt. Whether
> a text-only `UserInput(images: [])` works cleanly needs to be confirmed by
> running it. If it doesn't, we can pass a dummy 1×1 image as a workaround.

### The prompts

Both prompts live in `app/FastVLM App/prompts.txt` (already created) so you can
edit them without touching code. The file has two sections:

**Transcription prompt** — sent to the VLM with the page image:
```
Transcribe all handwritten text on this journal page exactly as written...
```

**Segmentation prompt** — sent to the VLM with the transcription text only. It
contains a `{transcription}` placeholder that code fills in, and instructs the
model to output entries with dates in a parseable format:
```
DATE: 2025-07-14
Today I went to the park and...
---
DATE: none
Woke up early, couldn't sleep...
```

> **Xcode gotcha:** For the app to read `prompts.txt` at runtime, it must be in
> the app's bundle. In Xcode, select the `FastVLM App` target → Build Phases →
> Copy Bundle Resources, and add `prompts.txt`. If you skip this,
> `Bundle.main.url(forResource: "prompts", withExtension: "txt")` returns `nil`.

### Creating the transcription service

New file: `app/FastVLM App/TranscriptionService.swift`

This wraps the two-call flow and parses the output. Think of it like a service
layer in a Python/JS backend — it orchestrates the model calls and returns
structured data.

```swift
import Foundation
import CoreImage

// A simple struct to hold parsed entries before they're saved to SwiftData.
// "struct" here because it's a lightweight value passed around, not persisted.
struct ParsedEntry {
    var text: String
    var date: Date?              // nil means "none" → fall back to page date
    var orderInPage: Int
}

@Observable
class TranscriptionService {
    private let model: FastVLMModel

    init(model: FastVLMModel) {
        self.model = model
    }

    // Load prompts from the bundled prompts.txt file.
    // Think: reading a config file at runtime instead of hardcoding strings.
    func loadPrompts() throws -> (transcription: String, segmentation: String) {
        guard let url = Bundle.main.url(forResource: "prompts", withExtension: "txt") else {
            throw NSError(domain: "JournalApp", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "prompts.txt not found in bundle"])
        }
        let content = try String(contentsOf: url, encoding: .utf8)
        // Split on "=== ... ===" headers to separate the two prompts.
        // (Exact parsing logic here — split by the section headers)
        // ...
        return (transcriptionPrompt, segmentationPrompt)
    }

    // Step 1: image → full transcription text
    func transcribe(image: CIImage) async throws -> String {
        let prompts = try loadPrompts()
        let userInput = UserInput(
            prompt: .text(prompts.transcription),
            images: [.ciImage(image)]
        )
        // model.generate is async and streams tokens into model.output.
        // We await its completion, then read model.output.
        let task = await model.generate(userInput)
        _ = await task.result
        return model.output
    }

    // Step 2: transcription text → separated entries with dates
    func segment(transcription: String, pageDate: Date) async throws -> [ParsedEntry] {
        let prompts = try loadPrompts()
        // Replace the {transcription} placeholder with the actual text.
        // Like Python's prompt.replace("{transcription}", transcription)
        let filledPrompt = prompts.segmentation
            .replacingOccurrences(of: "{transcription}", with: transcription)

        let userInput = UserInput(prompt: .text(filledPrompt), images: [])
        let task = await model.generate(userInput)
        _ = await task.result

        return parseEntries(from: model.output, fallbackDate: pageDate)
    }

    // Parse the model's output format:
    //   DATE: 2025-07-14
    //   entry text here
    //   ---
    //   DATE: none
    //   next entry
    func parseEntries(from output: String, fallbackDate: Date) -> [ParsedEntry] {
        // Split on "---" lines, extract DATE: line from each chunk.
        // This is plain string processing — same logic you'd write in Python.
        // ...
    }
}
```

### Swift async/await — for a Python/JS developer

If you've used `async/await` in Python or JS, Swift's version is nearly
identical:

```python
# Python                          # Swift
async def transcribe(image):      func transcribe(image: CIImage) async throws -> String
    result = await model.run()        let result = await model.generate(input)
    return result                    return result
```

```javascript
// JavaScript                      // Swift
const result = await model.run()   let result = await model.generate(input)
```

`Task { }` is like launching a background Promise — it runs the async code
without blocking the UI. The existing `FastVLMModel.generate` already uses this
pattern.

---

## UI screens

The current `ContentView.swift` is a live-camera chat. We need to restructure
it into a multi-screen app. Here's the screen map:

```
App
├── EntryListView        ← main screen: browse + search entries (replaces ContentView's role)
│   ├── CaptureButton    ← opens CaptureView
│   └── SearchBar        ← filters entries by text
├── CaptureView          ← photo capture + date picker
│   └── (on completion) → TranscriptionView
├── TranscriptionView    ← shows progress: "Transcribing..." → "Segmenting..."
│   └── (on completion) → ReviewView
└── ReviewView           ← parsed entries with editable dates, merge buttons
    └── (on save) → back to EntryListView
```

### Screen 1: EntryListView (main browse/search)

New file: `app/FastVLM App/EntryListView.swift`

```swift
import SwiftUI
import SwiftData

struct EntryListView: View {
    // @Query is like a reactive database query. It auto-updates the view
    // whenever entries are added/modified/deleted. Think of it as a live
    // SELECT that re-runs when the database changes.
    @Query(sort: \JournalEntry.date, order: .reverse) var entries: [JournalEntry]

    @State private var searchText = ""

    // Computed property — like a Python @property. Recalculated each render.
    var filteredEntries: [JournalEntry] {
        if searchText.isEmpty {
            return entries
        }
        // localizedStandardContains = case-insensitive, locale-aware substring match.
        // Like Python: searchText.lower() in entry.text.lower()
        return entries.filter { $0.text.localizedStandardContains(searchText) }
    }

    var body: some View {
        NavigationStack {
            List(filteredEntries) { entry in
                VStack(alignment: .leading) {
                    Text(entry.date, style: .date)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(entry.text)
                        .lineLimit(3)       // preview, tap to expand
                }
            }
            .searchable(text: $searchText)   // adds a search bar
            .navigationTitle("Journal")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    // NavigationLink pushes a new screen, like a router in a JS SPA.
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
```

### Screen 2: CaptureView (photo + date)

New file: `app/FastVLM App/CaptureView.swift`

This screen captures or imports a photo and lets the user pick the first entry's
date. It reuses the existing `CameraController` for live camera, and adds a
`PhotosPicker` (Apple's built-in photo picker) for importing existing photos.

```swift
import SwiftUI
import PhotosUI     // for PhotosPicker
import SwiftData

struct CaptureView: View {
    @Environment(\.modelContext) private var modelContext  // like a DB session
    @Environment(\.dismiss) private var dismiss            // close this screen

    @State private var capturedImage: Data?
    @State private var firstEntryDate = Date()

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                // Photo preview or placeholder
                if let imageData = capturedImage,
                   let uiImage = UIImage(data: imageData) {  // UIImage on iOS
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 400)
                } else {
                    Rectangle()
                        .fill(.secondary)
                        .frame(height: 400)
                        .overlay(Text("Capture or import a photo"))
                }

                // Date picker — native SwiftUI component
                DatePicker("Date of first entry", selection: $firstEntryDate,
                           displayedComponents: .date)

                // Import from photo library
                PhotosPicker(selection: $photosPickerItem, matching: .images) {
                    Label("Import from Photos", systemImage: "photo.on.rectangle")
                }

                Button("Transcribe") {
                    // Navigate to TranscriptionView with the captured image + date
                    // The JournalPage is created and saved here or in TranscriptionView.
                }
                .disabled(capturedImage == nil)
            }
            .navigationTitle("New Page")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
```

> **Platform difference:** `UIImage` is iOS-only. On macOS you'd use `NSImage`.
> Use `#if os(iOS)` / `#elseif os(macOS)` — the existing code already does this
> in `VideoFrameView.swift` and `InfoView.swift`.

### Screen 3: TranscriptionView (progress)

New file: `app/FastVLM App/TranscriptionView.swift`

Shows progress while the two model calls run. This is mostly a loading screen
with status text.

```swift
struct TranscriptionView: View {
    let imageData: Data
    let firstEntryDate: Date

    @State private var status = "Loading model..."
    @State private var parsedEntries: [ParsedEntry]?
    @State private var error: String?

    var body: some View {
        VStack(spacing: 20) {
            if let parsedEntries {
                // Done — show the review screen
                ReviewView(entries: parsedEntries, firstEntryDate: firstEntryDate)
            } else if let error {
                Text(error).foregroundStyle(.red)
            } else {
                ProgressView()
                Text(status)
            }
        }
        .task {
            // This runs when the view appears — like useEffect in React.
            // The two model calls go here:
            // 1. transcribe(image) → full text
            // 2. segment(text) → parsed entries
            // Update `status` and `parsedEntries` as you go.
        }
    }
}
```

### Screen 4: ReviewView (the manual merge decision)

New file: `app/FastVLM App/ReviewView.swift`

This is where the user reviews the segmented entries before saving. They can:
- Edit each entry's date (override the model's extraction)
- Edit entry text (fix transcription errors)
- Merge two entries into one (for cross-page continuation)

```swift
struct ReviewView: View {
    @State var entries: [ParsedEntry]
    let firstEntryDate: Date

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(entries.indices, id: \.self) { index in
                    VStack(alignment: .leading) {
                        // Editable date — DatePicker inline
                        DatePicker("Date", selection: Binding(
                            get: { entries[index].date ?? firstEntryDate },
                            set: { entries[index].date = $0 }
                        ), displayedComponents: .date)

                        // Editable text — TextEditor inline
                        TextEditor(text: Binding(
                            get: { entries[index].text },
                            set: { entries[index].text = $0 }
                        ))
                        .frame(minHeight: 60)
                    }

                    // Merge button (except for last entry)
                    if index < entries.count - 1 {
                        Button("Merge with next ↓") {
                            entries[index].text += "\n" + entries[index + 1].text
                            entries.remove(at: index + 1)
                        }
                    }
                }
            }
            .navigationTitle("Review Entries")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Save") {
                        saveEntries()
                        dismiss()
                    }
                }
            }
        }
    }

    func saveEntries() {
        // Create the JournalPage, then create JournalEntry objects linked to it.
        // modelContext.insert() is like a DB session.add() in SQLAlchemy.
        // SwiftData auto-saves — no explicit commit needed in most cases.
    }
}
```

### Wiring it all together

Update `app/FastVLM App/FastVLMApp.swift` to use `EntryListView` as the root:

```swift
@main
struct FastVLMApp: App {
    var body: some Scene {
        WindowGroup {
            EntryListView()    // was: ContentView()
        }
        .modelContainer(for: [JournalPage.self, JournalEntry.self])
    }
}
```

The existing `ContentView.swift` (live camera chat) stays in the project as a
reference but is no longer the entry point. You can keep it for debugging the
model, or remove it later.

---

## Implementation order

Work top-down through these steps. Each step builds on the previous one, and
each is independently testable.

### Step 1: SwiftData models + container (no UI, no model)

- Create `app/FastVLM App/JournalModels.swift` with `JournalPage` and
  `JournalEntry` (code above).
- Add `.modelContainer(for:)` to `FastVLMApp.swift`.
- **Test:** Build the app. It should compile and launch with an empty database.
  No UI changes yet — just confirm it runs.

### Step 2: EntryListView (read-only browse, no entries yet)

- Create `app/FastVLM App/EntryListView.swift`.
- Set it as the root view in `FastVLMApp.swift`.
- **Test:** Build and run. You should see an empty list with a search bar and
  a "+" button. The "+" button doesn't go anywhere yet.

### Step 3: TranscriptionService (model calls, no UI)

- Create `app/FastVLM App/TranscriptionService.swift`.
- Add `prompts.txt` to Copy Bundle Resources in Xcode.
- **Test:** Hardcode a test image path, call `transcribe` and `segment`,
  print the result. You can do this in a temporary button on EntryListView:
  `print(await service.transcribe(image: testImage))`.

### Step 4: CaptureView (photo + date input)

- Create `app/FastVLM App/CaptureView.swift`.
- Wire the "+" button in EntryListView to navigate to CaptureView.
- **Test:** Run the app, tap "+", capture or import a photo, pick a date, tap
  "Transcribe". The transcription doesn't run yet (TranscriptionView is next).

### Step 5: TranscriptionView (the two-call pipeline)

- Create `app/FastVLM App/TranscriptionView.swift`.
- Wire CaptureView's "Transcribe" button to navigate here.
- Call `TranscriptionService.transcribe` then `.segment` in the `.task` block.
- **Test:** Capture a photo of a handwritten page, watch the status update,
  and confirm parsed entries appear. Don't save yet.

### Step 6: ReviewView + save (close the loop)

- Create `app/FastVLM App/ReviewView.swift`.
- Wire TranscriptionView to show ReviewView when parsing completes.
- Implement `saveEntries()` — create `JournalPage` + `JournalEntry` objects,
  insert into `modelContext`.
- **Test:** Capture → transcribe → review → save → land back on EntryListView
  with the new entries visible. Search for a word in the transcription to
  confirm search works.

### Step 7: Polish

- Empty states ("No entries yet — capture your first page!")
- Error handling (model fails to load, transcription is garbage, etc.)
- Date formatting in the list
- Image viewing (tap an entry to see its source page image)
- Delete entries/pages

---

## Swift concepts cheat sheet (for a Python/JS developer)

| Swift | Python equivalent | JS equivalent | Notes |
|---|---|---|---|
| `struct` | tuple / dataclass (immutable) | object (value-copy semantics) | Value type — copied on assignment. Most SwiftUI views are structs. |
| `class` | class | class | Reference type — shared reference. SwiftData models must be classes. |
| `@State` | React `useState` | React `useState` | Local view state. Mutating it triggers re-render. |
| `@Observable` | `@property` + observer | Vue reactivity / MobX | Class whose property changes notify observers. |
| `@Binding` | callback ref | controlled component props | Two-way binding to parent's `@State`. |
| `@Query` | reactive SQLAlchemy query | live query / subscription | Auto-updates view when SwiftData changes. |
| `@Environment` | React Context | React Context | Dependency injection — access shared objects like `modelContext`. |
| `@Environment(\.dismiss)` | router.back() | navigation.goBack() | Close the current sheet/navigation. |
| `some View` | — | — | "some type that conforms to View protocol" — like a generic return type. Don't overthink it. |
| `async`/`await` | `async`/`await` | `async`/`await` | Same concept. |
| `Task { }` | `asyncio.create_task()` | `new Promise()` | Launch async work. Cancelled when the view disappears (if in `.task`). |
| `AsyncStream` | async generator (`async yield`) | Observable / async iterable | How camera frames are streamed. |
| `.task { }` | `useEffect(() => {...}, [])` | `useEffect` | Runs async code when a view appears. |
| `#if os(iOS)` | — | — | Compile-time conditional. Not runtime — the other branch isn't even compiled. |
| `Protocol` | ABC / interface | TypeScript interface | A contract a type can conform to. |
| `@Model` | SQLAlchemy `@declarative_base` | ORM model decorator | SwiftData persistence marker. |
| `modelContext` | DB session | DB connection/transaction | Insert/fetch/delete objects through this. |

### Common patterns you'll see in this codebase

**Property wrappers (`@` prefix):** These are decorators that add behavior to a
property. `@State`, `@Binding`, `@Query`, `@Observable` — they look weird at
first but they're just Swift's way of saying "this property has special
behavior" (like Python decorators on methods).

**`$variable` prefix:** When you see `$searchText`, it means "a binding to
this state" — a two-way reference. You pass `$searchText` to a text field so
the field can both read and write the value. Without `$`, you'd only pass the
current value (read-only).

**`some View`:** Every SwiftUI view's `body` returns `some View`. Think of it
as "a specific type that conforms to the View protocol, but I don't want to
write out the exact type." It's the compiler's job to figure it out. Just
return your view hierarchy and don't worry about the return type.

**`ForEach` + `List`:** Like mapping over an array in React (`items.map(...)`)
but for native lists. SwiftUI handles scrolling, selection, and swipe-to-delete
for free.

---

## Key files reference

| File | Role | Status |
|---|---|---|
| `app/FastVLM App/FastVLMApp.swift` | App entry point — will get `.modelContainer` + root view change | Modify |
| `app/FastVLM App/FastVLMModel.swift` | Model loading + inference — reuse as-is | Keep |
| `app/FastVLM App/prompts.txt` | Transcription + segmentation prompts | Done |
| `app/FastVLM App/JournalModels.swift` | SwiftData models | Create |
| `app/FastVLM App/TranscriptionService.swift` | Two-call pipeline + parsing | Create |
| `app/FastVLM App/EntryListView.swift` | Browse + search entries | Create |
| `app/FastVLM App/CaptureView.swift` | Photo capture + date picker | Create |
| `app/FastVLM App/TranscriptionView.swift` | Progress screen | Create |
| `app/FastVLM App/ReviewView.swift` | Edit/merge entries before save | Create |
| `app/FastVLM App/ContentView.swift` | Old live-camera chat | Keep as reference |
| `app/Video/CameraController.swift` | AVFoundation camera | Reuse in CaptureView |
| `app/Video/VideoFrameView.swift` | Camera preview view | Reuse in CaptureView |

---

## Decisions summary

| Decision | Choice |
|---|---|
| Storage | SwiftData (`@Model` classes, SQLite under the hood) |
| Capture | Single photo per page now; many-to-many schema ready for multi-page |
| Search | `localizedStandardContains` on entry text + date-sorted browse; SQLite FTS5 later if needed |
| Platform | iOS + macOS (universal, using `#if os(iOS)` / `#elseif os(macOS)`) |
| Cross-page entries | Manual merge in ReviewView (user reviews, can merge adjacent entries) |
| Entry dating | Model extracts dates from text during segmentation; falls back to page's `firstEntryDate` |
| Segmentation | Second VLM call (text-only) using the segmentation prompt |
| Prompts | `app/FastVLM App/prompts.txt` — editable, loaded at runtime via `Bundle.main` |

---

## Open questions to resolve during implementation

1. **Text-only VLM call:** Does `UserInput(images: [])` work cleanly with
   FastVLM, or does the model require an image token? Test in Step 3. If not,
   pass a 1×1 dummy image.

2. **Token streaming during transcription:** The existing `FastVLMModel.generate`
   streams tokens into `model.output` live. For the transcription flow, do we
   want to show the live transcription streaming (nice UX) or just a spinner?
   The plumbing supports both — decide during Step 5.

3. **Image storage size:** Storing full-resolution photos as `Data` in SwiftData
   works but can bloat the database. Consider downsampling before storage, or
   storing images as files in the app's Documents directory and keeping only a
   path reference in SwiftData. Decide during Step 6.

4. **macOS photo import:** `PhotosPicker` works on both platforms, but macOS
   also benefits from drag-and-drop file import. Consider adding a
   `.fileImporter` modifier for Mac. Low priority — the camera/PhotosPicker
   path works cross-platform.

5. **Multiple pages per upload session:** The plan assumes one page at a time.
   A future enhancement: batch upload several pages, transcribe them in
   sequence, then review all entries together (where cross-page merging
   becomes most useful). The data model already supports this via the
   many-to-many relationship.
