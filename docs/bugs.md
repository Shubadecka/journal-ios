# Remaining bugs

Original review 2026-10-05; re-reviewed 2026-10-06 after first round of fixes.
Fixed in round 1: `ParsedEntryRaw: Codable`, nested `NavigationStack` removed,
`en_US_POSIX` locale, `.applyOrientationProperty`, empty `TranscriptionView.swift` deleted.
Fixed 2026-10 (engine swap): #1(a), #1(b), #2, #3 closed by moving the pipeline
to Foundation Models — typed guided generation removes the JSON parsing path
entirely, and the throwing `LanguageModelSession.respond` API replaces the
output-smuggling FastVLM wrapper (deleted). Work through top to bottom.
Status: `[ ]` open, `[x]` fixed, `[~]` won't fix (with reason).

---

## 1. Fence-strip in `parseEntries` can crash the app — introduced by the fix

- **Status:** `[x]` Fixed 2026-10 — engine swapped to Foundation Models with
  typed guided generation (`SegmentedPage`); `parseEntries` and the bracket
  slicing no longer exist. `[illegible]` markers pass through guided
  generation verbatim (verified by probe).

- **File:** `app/FastVLM App/TranscriptionService.swift:59`
- **Severity:** 🔴 runtime crash (regression)

Current code:

```swift
var output = output.split(separator: "[")[1].split(separator: "]")[0]
```

Two problems:

**a) Uncaught index-out-of-range → app crash.** If the model output contains
no `[` (or no `]`) — e.g. generation failed and `model.output` is
`"Failed: <error>"` — `split(...)[1]` is a subscript out of range. That raises
a `fatalError`, **not** an `Error`, so the `catch` in `TranscriptionQueue.drain`
cannot catch it. Previously this path threw a decodable error and the job was
marked failed; now it kills the app.

**b) `[illegible]` truncation.** The transcription prompt explicitly tells the
model to mark unreadable text as `[illegible]`. If that marker survives into an
entry (it should — the text must be preserved), it appears *inside* the JSON.
`split(separator: "[")` then cuts at the *first* `[`, which is inside the entry
string, and `split(separator: "]")[0]` discards everything after — the entry
loses its tail and the closing `}`/`]`, so the JSON decode fails and the job
fails every time a page contains an illegible mark.

Fix: use index-based slicing with guards that **throw**, never subscript:

```swift
guard let start = output.firstIndex(of: "["),
      let end = output.lastIndex(of: "]"),
      start < end else {
    throw NSError(domain: "JournalApp", code: 3,
        userInfo: [NSLocalizedDescriptionKey: "No JSON array found in model output"])
}
let json = String(output[start...end])
```

`lastIndex(of: "]")` handles `[illegible]` correctly because the array's closing
` ]` is the last bracket in well-formed output. Also: the `var output` is never
mutated — use `let`.

## 2. Generation errors smuggled through `model.output`

- **Status:** `[x]` Fixed 2026-10 — `FastVLMModel` deleted with the MLX
  engine; `LanguageModelSession.respond` is a throwing API, so failures
  propagate as errors into `TranscriptionQueue.drain`'s catch and surface as
  `JobPhase.failed(error.localizedDescription)`.

- **File:** `app/FastVLM App/FastVLMModel.swift:167`
- **Severity:** 🟡 feeds bug #1, misleading errors

On failure, `generate` sets `output = "Failed: \(error)"` and returns normally,
so `transcribePage`/`segmentPageTranscription` treat the error text as a
successful transcription and hand it to `parseEntries`. Combined with #1a this
is now the crash path. Even without the crash, the surfaced error ("Expected
yyyy-MM-dd, got: Failed: …") hides the real cause.

Fix direction: give the service a way to distinguish failure — e.g. a
`generate` overload that throws (or returns nil / a Result) instead of writing
the error into `output`, and have `transcribePage`/`segmentPageTranscription`
propagate it.

## 3. `generate` reuse guard can return the wrong task

- **Status:** `[x]` Fixed 2026-10 — obsolete with the FastVLM wrapper deleted;
  the new service creates one `LanguageModelSession` per call, so there is no
  shared task to race.

- **File:** `app/FastVLM App/FastVLMModel.swift:113`
- **Severity:** 🟢 not reachable today, but a landmine

```swift
if let currentTask, running { return currentTask }
```

If two callers ever overlap, the second gets the `Task` running the **first
caller's prompt**, then reads whatever text it produced. The serial `drain`
loop currently prevents overlap, so not blocking — but it silently returns
wrong output if parallel jobs are ever added.

## 4. Minor / cleanup

- `[x]` Error domain typo `"JounalApp"` — fixed 2026-10 in the service rewrite;
  all domains are now `"JournalApp"`.
- `[x]` `loadPrompts`' misleading count message — obsolete 2026-10: the rewrite
  splits on the two `===` headers with a single "not separating cleanly" error.
- `[ ]` Photos picker gotcha: `onChange(of: photosPickerItem)` won't re-fire if
  the user re-picks the **identical** photo after Cancel → `capturedImage` stays
  nil and Transcribe stays disabled. Low priority.
- `[~]` `ParsedEntry: Codable` conformance is unnecessary (it's constructed
  manually, never decoded). Harmless — remove or keep, taste call.