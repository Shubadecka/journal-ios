# Repository Guidelines

## Project Overview

On-device handwritten-journal app: photograph/import paper journal pages →
transcribe the handwriting with Apple's on-device system model → segment the
transcription into dated entries → persist and search them. All inference is
on-device; there is no backend.

The transcription engine is **Apple Intelligence (Foundation Models)**: a
`LanguageModelSession` per pass, image attachments for transcription and
`@Generable` guided generation for segmentation. The repo retains the
historical FastVLM sources (`app/FastVLM/`, vendored upstream code) but they
are no longer referenced by the project; the app builds with no model
download. The repo has two halves:

- **Swift app** (`app/`) — the journal product. This is where active work is.
- **Python tooling** (`llava/`, `predict.py`, `model_export/`) — vendored
  upstream LLaVA code for training, PyTorch eval, and model export. Treat as
  third-party; rarely needs changes.

## Architecture & Data Flow

Two LLM calls per page, then SwiftData persistence:

1. Capture: `EntryListView` → `ImportView` (PhotosPicker) or `CaptureView`
   (`CameraPicker` wrapper) collect page photos into `PageDraft`s →
   `PageReviewView` (verification screen) lists them with Rotate/Crop/Undo
   (edits in memory only; JPEG-encoded once at Transcribe) → Transcribe
   enqueues one job per image and dismisses.
2. `TranscriptionQueue.drain` (serial loop) decodes each image.
3. `TranscriptionService.transcribePage` — VLM call 1: image → verbatim
   transcription (prompt from `prompts.txt`, image passed as a Foundation
   Models `Attachment`).
4. `segmentPageTranscription` — VLM call 2: text-only guided generation
   (`respond(to:generating: SegmentedPage.self)`, `{transcription}` filled
   into the segmentation prompt) → typed `SegmentedPage` of `{date, entry,
   orderInPage}`.
5. `parseDate` (`yyyy-MM-dd` UTC, empty/`null` → nil) and `inferDates` (fills
   missing dates, sets `needsReview`).
6. Auto-save `JournalPage` + `JournalEntry` into the passed `ModelContext`;
   `EntryListView` renders them via `@Query`, search via `.searchable`.
   `TranscriptionBanner` (`.safeAreaInset`) shows queue progress.

Key types (all in `app/FastVLM App/`):

|Type|Role|
|---|---|
|`JournalApp` (`FastVLMApp.swift`)|`@main`; owns `TranscriptionQueue`, injects `.environment`, installs `.modelContainer`|
|`TranscriptionQueue`|`@MainActor @Observable` serial job queue (`TranscriptionJob`/`JobPhase`). **In-memory only — app kill loses queued work.**|
|`TranscriptionService`|Availability gate, prompt loading, the two Foundation Models passes, date inference|
|`JournalPage` / `JournalEntry` (`JournalModels.swift`)|SwiftData `@Model`s; entries many-to-many `pages` (cross-page entries), `needsReview` flag|

Authoritative design doc: `docs/plan.md` (data model rationale, pipeline, screen
map, decisions). Its status table marks implementation steps 1–6 done; 7
(PageView + re-transcription) and 8 (polish) are open. The README "Status"
section is stale — the journal flow is largely implemented.

## Key Directories

- `app/FastVLM App/` — SwiftUI app: views, queue/service, SwiftData models,
  `prompts.txt`, entitlements. **All product code lives here.**
- `app/FastVLM/` — vendored FastVLM framework source, kept on disk for
  reference only; **not referenced by the Xcode project** (the framework
  target was removed in the Foundation Models swap). `app/FastVLM/model/`
  (gitignored) may hold leftover MLX weights; nothing builds against them.
- `app/Camera/` — `CameraPicker` (`UIImagePickerController` → JPEG `Data`),
  compiled only where UIKit exists (macOS has library-import only).
- `app/Configuration/` — `Build.xcconfig` (vestigial, one unused variable).
- `llava/` — vendored LLaVA: `model/` (arch, Qwen2 backend), `train/`, `serve/`.
- `model_export/` — vision-encoder export to Core ML + mlx-vlm patch; see its
  README for the full weights pipeline.
- `docs/` — living `plan.md` and `bugs.md` (see Testing & QA).

## Development Commands

Build/run (Mac with Apple Silicon + Xcode 27+); no model download needed:

```bash
open app/FastVLM.xcodeproj   # scheme "FastVLM App", ⌘R
# CLI equivalent:
xcodebuild -project app/FastVLM.xcodeproj -scheme "FastVLM App" build
```

Destination: iOS 27+ device (Apple Intelligence required for transcription) or
My Mac (macOS 27+); set your development team under Signing & Capabilities on
first build. macOS currently supports library import only — the camera UI is
iOS/visionOS-only and gated behind `#if canImport(UIKit)`.

Python (optional — training/eval/export only, not needed for app work):

```bash
conda create -n fastvlm python=3.10 && conda activate fastvlm
pip install -e .
bash get_models.sh           # PyTorch checkpoints → checkpoints/
python predict.py --model-path checkpoints/<ckpt> --image-file img.png --prompt "..."
```

Model export (PyTorch → Core ML + MLX): `model_export/README.md`
(`export_vision_encoder.py`, patched mlx-vlm pinned at commit `1884b55`).

## Code Conventions & Common Patterns

- **State**: Observation framework — `@MainActor @Observable` classes created in
  `FastVLMApp`, injected once with `.environment(...)`, read with
  `@Environment(Type.self)`. Views hold local state in `@State`; shared forms
  take `@Binding` (see `PageReviewView`).
- **Concurrency**: service methods are `async throws`; the queue is serial by
  design (single `drainTask`). Each pass creates its own `LanguageModelSession`
  — no shared session state, so parallel generation wouldn't race. MLX
  token-stream callbacks are gone with the old engine.
- **Error handling**: `throws` with `NSError(domain: "JournalApp", code: …)`;
  job failures surface as `JobPhase.failed` + banner row, never crashes.
  `ensureAppleIntelligence()` gates both passes — on non-Apple-Intelligence
  devices every job fails with the availability message; there is no fallback
  engine.
- **Model errors are thrown**: `LanguageModelSession.respond` is a throwing
  API; failures propagate out of `transcribePage`/`segmentPageTranscription`
  into the queue's catch. There is no string-smuggling error channel anymore.
- **Prompts are config**: behavior tweaks usually mean editing
  `app/FastVLM App/prompts.txt` (`=== SECTION ===` headers, `{transcription}`
  placeholder, `[illegible]` marker), not Swift. Guided generation
  (`SegmentedPage`) enforces the output shape, so the prompt carries semantics
  only. Date-line ownership is load-bearing: a date heads the text BELOW it;
  text before the first date line is its own undated entry.
- **Navigation**: enum-driven routing (`PageSource` + `.navigationDestination(item:)`),
  one `NavigationStack` at root.
- **Naming**: standard Swift — UpperCamelCase types/files, lowerCamelCase
  members; `// MARK: -` sections inside the vendored `FastVLM.swift`.
- **Vendored code** (`app/FastVLM/`, `llava/`, `model_export/`, `predict.py`)
  carries upstream license headers (LLaVA Apache-2.0 / Apple). Keep diffs
  minimal and mark local edits in comments (existing style: `# fix: add qwen2`).
  Product code stays in `app/FastVLM App/` + `app/Camera/`.

## Important Files

| File | Why it matters |
|---|---|
| `app/FastVLM App/FastVLMApp.swift` | Entry point: DI + SwiftData container |
| `app/FastVLM App/TranscriptionService.swift` | The two-call Foundation Models pipeline + guided-generation types + date inference — most bug-prone area |
| `app/FastVLM App/TranscriptionQueue.swift` | Serial job lifecycle (enqueue/drain/cancel/auto-save) |
| `app/FastVLM App/prompts.txt` | Runtime prompts; editing it changes transcription quality |
| `app/FastVLM.xcodeproj/project.pbxproj` | Targets: `FastVLM App` (app), `Video` (empty shell); zero SPM packages |
| `docs/plan.md`, `docs/bugs.md` | Living architecture plan and bug tracker |
| `pyproject.toml` | Python package `llava` (1.2.2.post1, `requires-python >= 3.8`) |

## Runtime/Tooling Preferences

- **Host**: macOS on Apple Silicon; Xcode 27+ (project `objectVersion 77`),
  Swift 5. Multi-platform target: iOS 27 / macOS 27 / visionOS 27.
- **Dependencies**: none — the Foundation Models framework is part of the OS
  SDK. The project has zero SwiftPM packages; don't add other package
  managers.
- **Model files**: the app ships no weights (the engine is the OS's Apple
  Intelligence model). Legacy MLX weights stay gitignored
  (`app/FastVLM/model/`, `checkpoints/`) — never commit them. Code is licensed
  under `LICENSE` (permissive); model weights under `LICENSE_MODEL`
  (research/non-commercial only).
- **Sandbox**: the app is sandboxed with camera, user-selected read-only files,
  network client, and increased-memory entitlements — widen deliberately.
  Foundation Models needs no entitlement.
- **Python**: 3.10 via conda (README), `pip install -e .`; no linter/formatter
  config exists — match surrounding style. No Node/Bun tooling in this repo.

## Testing & QA

- **No automated tests and no CI.** No XCTest/pytest anywhere; the Xcode
  scheme's test action is empty; `llava/serve/test_message.py` is a manual
  serving-stack smoke client, not a test.
- QA is manual: every implementation step in `docs/plan.md` carries a
  verification checklist; `docs/bugs.md` is the regression list (worked top to
  bottom). Most legacy entries were closed by the Foundation Models swap;
  verify a listed bug still reproduces before "fixing" it.
- **Verify pipeline changes end-to-end**: build, run a real page image through
  capture → transcribe → segment → save, and inspect the parsed entries and
  `needsReview` flags in `EntryListView`. A compiling build is not proof here.
  Requires a device with Apple Intelligence enabled — simulators are not
  eligible.
