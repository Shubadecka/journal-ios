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
    var transcriptionError: String? // set when transcription failed; nil = clean
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
    var needsReview: Bool        // true when the date was inferred, not parsed
                                 // from the model output → red border in the list

    // Many-to-many: an entry can span multiple pages (continues onto next page).
    // This is how we link entries back to their source page(s).
    var pages: [JournalPage] = []

    init(text: String, date: Date, orderInPage: Int, needsReview: Bool = false) {
        self.id = UUID()
        self.text = text
        self.date = date
        self.orderInPage = orderInPage
        self.needsReview = needsReview
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
App root (FastVLMApp)
├── TranscriptionBanner  ← pinned above every screen (safeAreaInset at the root);
│                          shows queue status, expands inline for job details
├── EntryListView        ← main screen: browse + search entries (replaces ContentView's role)
│   ├── CaptureButton    ← opens CaptureView
│   ├── SearchBar        ← filters entries by text
│   └── red border       ← rows with needsReview == true
├── CaptureView          ← photo capture + date picker
│   └── (on Transcribe)  → enqueue job in TranscriptionQueue, dismiss immediately
├── TranscriptionQueue   ← serial background pipeline:
│                          transcribe → segment → parse → auto-save to SwiftData
├── PageView             ← browse captured pages (thumbnails + date)
│   └── PageDetailView   ← page image; failed pages show the error here;
│                          "Re-transcribe" button at the bottom
└── EntryDetail (edit)   ← tap a flagged entry to fix its date/text, merge
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
                    // Enqueue for background transcription and close immediately —
                    // the user is never blocked waiting on the model.
                    guard let imageData = capturedImage else { return }
                    queue.enqueue(imageData: imageData, firstEntryDate: firstEntryDate)
                    dismiss()
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

### Screen 3: TranscriptionQueue (serial background pipeline)

New file: `app/FastVLM App/TranscriptionQueue.swift`

There is no transcription progress screen. Jobs run in the background while
the user keeps browsing. `TranscriptionQueue` is an `@Observable` class,
instantiated once in `FastVLMApp` and injected via `.environment`.

Jobs drain **serially** — this is required, not a compromise:
`FastVLMModel` has a `running` guard (it refuses concurrent `generate` calls)
and streams into a single shared `model.output` buffer, so two jobs running
at once would clobber each other's output.

```swift
enum JobPhase {
    case queued, transcribing, segmenting
    case done
    case failed(String)
}

struct TranscriptionJob: Identifiable {
    let id = UUID()
    let imageData: Data
    let firstEntryDate: Date
    var phase: JobPhase
    var parsedEntries: [ParsedEntry]?
}

@Observable
class TranscriptionQueue {
    var jobs: [TranscriptionJob] = []

    // ⚠️ IN-MEMORY ONLY — READ BEFORE RELYING ON THIS:
    // Force-quitting the app, iOS reclaiming memory, or the app being
    // suspended mid-job DELETES ALL IN-PROGRESS IMAGES AND TEXT. Nothing
    // is persisted until a job finishes and auto-saves its entries to
    // SwiftData. Accepted tradeoff: simplicity over resume support.

    func enqueue(imageData: Data, firstEntryDate: Date) {
        jobs.append(TranscriptionJob(
            imageData: imageData, firstEntryDate: firstEntryDate, phase: .queued))
        startDrainingIfNeeded()   // one Task drains the queue serially
    }

    func cancelQueued(_ id: UUID) {
        // Removes .queued jobs only. The ACTIVE job cannot be cancelled —
        // it runs to completion.
    }

    func retranscribe(page: JournalPage, modelContext: ModelContext) {
        // Re-runs an existing page. The job carries the page reference, so
        // the drain loop UPDATES it instead of inserting a new one.
        jobs.append(TranscriptionJob(
            imageData: page.imageData, firstEntryDate: page.firstEntryDate,
            phase: .queued, existingPage: page))
        startDrainingIfNeeded(modelContext: modelContext)
    }
}
```

The drain loop per job: `transcribe(image)` → `segment(text, pageDate)` →
`parseEntries` → insert `JournalPage` + `JournalEntry` records into
`modelContext`, then mark the job `.done`. Failures save the page — image +
date + error message in `transcriptionError` — so a failed capture is never
lost (see "PageView & re-transcription" below).

**Auto-save + review flags.** Because saving is automatic, review is deferred
instead of blocking:

- `JournalEntry.needsReview = true` when the date was *inferred* rather than
  explicitly parsed — "DATE: none" lines, and entries inheriting a date from
  the previous entry or the page's `firstEntryDate`.
- Explicitly dated entries save clean.
- Nothing is ever held back waiting for the user — the queue never stops.

### Screen 4: TranscriptionBanner (queue status, pinned above everything)

New file: `app/FastVLM App/TranscriptionBanner.swift`

An inline banner pinned to the app root with `.safeAreaInset(edge: .top)` in
`FastVLMApp.swift` — it sits above **every** screen, not inside
`EntryListView`.

- Collapsed: one line, e.g. `⟳ Transcribing 2/3…`. Hidden entirely when
  `jobs.isEmpty`.
- Tap toggles expansion in place: per-job rows (thumbnail, page date, phase,
  ✕ on queued rows only).
- Done jobs flash briefly (removed automatically ~2s after completing).
- Failed rows show in red until dismissed — transitional, until PageView
  takes over failure display (see below).
- Reads `TranscriptionQueue` from the environment; `@Observable` makes UI
  updates automatic as phases change.

### PageView & re-transcription

New files: `app/FastVLM App/PageView.swift`, `app/FastVLM App/PageDetailView.swift`

**Failure display.** When a job fails, the queue saves the page — image +
`firstEntryDate`, empty `fullTranscription`, `transcriptionError` set — instead
of dropping it:

- `PageView` (entry point: toolbar button in `EntryListView`) lists captured
  pages as thumbnails with dates.
- Page state is **derived, no status enum**: `transcriptionError != nil` →
  failed; `fullTranscription.isEmpty` → pending; else done.
- A failed page's thumbnail gets a red border — same stroke-overlay technique
  as the `needsReview` rows in EntryListView.
- A job currently running for a page is visible via `queue.jobs` — show a
  spinner on that page's row.
- Tapping a page (failed or not) opens `PageDetailView`: the full page image,
  the error message when failed, and a **Re-transcribe** button at the bottom
  of the screen.

**Re-transcription (any page, not just failed ones).** The button calls
`queue.retranscribe(page:)`:

- `TranscriptionJob` gains `var existingPage: JournalPage?`. When present, the
  drain loop **updates** that page — sets `fullTranscription`, clears
  `transcriptionError` — instead of inserting a new one.
- **Old entries are deleted only after the new transcription succeeds.**
  If the re-run fails, the page keeps its old entries and gets a fresh error.
  Deleting upfront would lose good data on a failed re-run — worse than
  showing stale text.
- **Deletion rule:** remove `JournalEntry` objects whose `pages` contains ONLY
  this page (`entry.pages.count == 1`). Entries shared with other pages
  (cross-page continuations) are left untouched, link included — their stale
  page-side text is accepted for now.
- Re-created entries follow the normal rules: explicit dates save clean,
  inferred dates get `needsReview = true` (red border).
- Guard: if a job for the same page is already queued/running, the
  Re-transcribe button is disabled (derived from `queue.jobs`).

Once PageView exists, failed banner rows become secondary — keep the
tap-to-dismiss behavior; a follow-up can auto-drop them like done jobs.

### Reviewing flagged entries (red border in EntryListView)

Entries auto-save, so review happens whenever the user feels like it:

- `EntryListView` draws a red border (`.overlay(RoundedRectangle().stroke(.red))`)
  on rows whose `entry.needsReview == true` — a "big indicator" that doesn't
  interrupt the flow.
- Tapping a flagged entry opens an edit view (to be built; same editing UI the
  old ReviewView sketch had: inline DatePicker, TextEditor, merge-with-next
  button) so dates and text can be fixed at the user's leisure.
- `@Query` auto-refreshes when SwiftData changes, so freshly saved entries
  — flagged or not — just appear in the list.

### Wiring it all together

Update `app/FastVLM App/FastVLMApp.swift` to use `EntryListView` as the root,
inject the queue once, and pin the banner above everything:

```swift
@main
struct FastVLMApp: App {
    var body: some Scene {
        WindowGroup {
            EntryListView()    // was: ContentView()
                .environment(TranscriptionQueue())          // one instance for the app
                .safeAreaInset(edge: .top) {                // banner above ALL screens
                    TranscriptionBanner()
                }
        }
        .modelContainer(for: [JournalPage.self, JournalEntry.self])
    }
}
```

The old `ContentView.swift` live-camera demo has been removed from the
project. The `Video` framework files (`CameraController`, `VideoFrameView`)
stay — CaptureView will reuse them for live capture.

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
- The "Transcribe" button calls `queue.enqueue(...)` and dismisses — the
  transcription doesn't run yet (the queue is next).

### Step 5: TranscriptionQueue (the background pipeline)

- Create `app/FastVLM App/TranscriptionQueue.swift`.
- Inject it via `.environment(TranscriptionQueue())` in `FastVLMApp.swift`.
- The drain loop calls `TranscriptionService.transcribe` then `.segment`,
  then inserts `JournalPage` + `JournalEntry` records (with `needsReview`
  flags) into `modelContext`.
- **Test:** Capture a photo of a handwritten page, tap Transcribe, and
  immediately navigate back to the list. The queue drains in the background;
  entries appear when done. Verify `needsReview` is true only for entries
  with inferred ("DATE: none" / inherited) dates.

### Step 6: TranscriptionBanner + needs-review editing (close the loop)

- Create `app/FastVLM App/TranscriptionBanner.swift`; pin it with
  `.safeAreaInset(edge: .top)` at the app root so it sits above every screen.
- Draw a red border on `needsReview` rows in `EntryListView`; tapping a
  flagged entry opens the edit view (inline DatePicker, TextEditor,
  merge-with-next — reuse the old ReviewView editing code).
- **Test:** Transcribe two pages back to back — the banner shows the queue
  draining on every screen. Flagged entries show the red border; editing a
  flagged entry's date clears the flag. Search for a word in the
  transcription to confirm search works.

### Step 7: PageView + re-transcription

- Add `transcriptionError: String?` to `JournalPage` (optional property —
  SwiftData lightweight-migrates it, no DB wipe needed).
- Switch the queue's failure path to save the page (image + date + error).
- Create `PageView.swift` (+ toolbar entry point in EntryListView) and
  `PageDetailView.swift` with the Re-transcribe button.
- Teach the queue to update an existing page (`existingPage` on the job) and
  to delete page-exclusive entries after a successful re-run.
- **Test:** transcribe a blank/garbage image to force a failure — the page
  appears in PageView with a red border and the error on tap. Then
  re-transcribe a good page: its page-exclusive entries disappear and new
  ones appear; an entry shared with another page survives untouched.

### Step 8: Polish

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
| `app/FastVLM App/TranscriptionQueue.swift` | Serial background job queue: transcribe → segment → auto-save. **In-memory only — app kill deletes all in-progress images/text.** | Done |
| `app/FastVLM App/TranscriptionBanner.swift` | Inline queue banner pinned above every screen | Done |
| `app/FastVLM App/EntryListView.swift` | Browse + search entries; red border on needsReview rows | Done |
| `app/FastVLM App/CaptureView.swift` | Photo capture + date picker; enqueues and dismisses | Done |
| `app/FastVLM App/PageView.swift` | Browse pages (thumbnails); derived state, spinner for in-flight jobs | Create |
| `app/FastVLM App/PageDetailView.swift` | Page image + error; Re-transcribe button at the bottom | Create |
| `app/FastVLM App/EntryDetailView.swift` | Edit flagged entries: dates, text, merge (name TBD) | Create |
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
| Cross-page entries | Manual merge in the entry edit view (tap a flagged entry; can merge adjacent entries) |
| Entry dating | Model extracts dates from text during segmentation; falls back to page's `firstEntryDate` |
| Segmentation | Second VLM call (text-only) using the segmentation prompt |
| Prompts | `app/FastVLM App/prompts.txt` — editable, loaded at runtime via `Bundle.main` |
| Transcription | Backgrounded serial queue (`TranscriptionQueue`) — no progress screen; user never waits on the model |
| Job persistence | In-memory only: killing the app deletes all in-progress images and text; finished results auto-save to SwiftData |
| Review | Auto-save + `needsReview` flag on inferred dates; red border in EntryListView; edit on tap, never blocking |
| Cancel | Queued jobs cancellable from the banner; the active job runs to completion |
| Failure handling | Failed job saves the page (image + `transcriptionError`); red border in PageView, error on tap in the detail view |
| Re-transcription | Button at the bottom of the page detail screen; updates the existing page; entries exclusive to that page are deleted only after the new run succeeds |

---

## Open questions to resolve during implementation

1. **Text-only VLM call:** Does `UserInput(images: [])` work cleanly with
   FastVLM, or does the model require an image token? Test in Step 3. If not,
   pass a 1×1 dummy image.

2. **Token streaming in the banner:** `FastVLMModel.generate` streams tokens
   into `model.output` live. The banner shows phase + queue position, not live
   text. Optional polish: a token/word count while a job is transcribing.

3. **Image storage size:** Storing full-resolution photos as `Data` in SwiftData
   works but can bloat the database. Consider downsampling before storage, or
   storing images as files in the app's Documents directory and keeping only a
   path reference in SwiftData. Decide during Step 5 (where auto-save happens).

4. **macOS photo import:** `PhotosPicker` works on both platforms, but macOS
   also benefits from drag-and-drop file import. Consider adding a
   `.fileImporter` modifier for Mac. Low priority — the camera/PhotosPicker
   path works cross-platform.

5. **Multiple pages per upload session:** The plan assumes one page at a time.
   A future enhancement: batch upload several pages, transcribe them in
   sequence, then review all entries together (where cross-page merging
   becomes most useful). The data model already supports this via the
   many-to-many relationship.

6. **Re-transcription vs. cross-page entries:** An entry spanning pages A+B
   keeps its stale page-A content after A is re-transcribed (deletion rule
   only covers entries exclusive to the page). A future refinement could
   re-link the new A-side text into the shared entry instead of leaving the
   stale version in place.
