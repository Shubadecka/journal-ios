# Repository Guidelines

## Project Overview

On-device handwritten-journal app: photograph/import paper journal pages →
transcribe the handwriting with a vision-language model → segment the
transcription into dated entries → persist and search them. All inference is
on-device; there is no backend.

The model is **FastVLM** (CVPR 2025), forked from
[apple/ml-fastvlm](https://github.com/apple/ml-fastvlm): a Qwen2 LLM on MLX
plus a FastViT-HD vision tower on Core ML. The repo has two halves:

- **Swift app** (`app/`) — the journal product. This is where active work is.
- **Python tooling** (`llava/`, `predict.py`, `model_export/`) — vendored
  upstream LLaVA code for training, PyTorch eval, and model export. Treat as
  third-party; rarely needs changes.

## Architecture & Data Flow

Two LLM calls per page, then SwiftData persistence:

1. Capture: `EntryListView` → `ImportView` (PhotosPicker) or `CaptureView`
   (`CameraPicker` wrapper) collect `[Data]` page images → `TranscribeForm`
   enqueues one job per image and dismisses.
2. `TranscriptionQueue.drain` (serial loop) decodes each image.
3. `TranscriptionService.transcribePage` — VLM call 1: image → verbatim
   transcription (prompt from `prompts.txt`).
4. `segmentPageTranscription` — VLM call 2: text-only, `{transcription}` filled
   into the segmentation prompt → JSON array of `{date, entry, orderInPage}`.
5. `parseEntries` (guarded bracket-slice + `JSONDecoder`, `yyyy-MM-dd` UTC) and
   `inferDates` (fills missing dates, sets `needsReview`).
6. Auto-save `JournalPage` + `JournalEntry` into the passed `ModelContext`;
   `EntryListView` renders them via `@Query`, search via `.searchable`.
   `TranscriptionBanner` (`.safeAreaInset`) shows queue progress.

Key types (all in `app/FastVLM App/`):

| Type | Role |
|---|---|
| `JournalApp` (`FastVLMApp.swift`) | `@main`; owns `TranscriptionQueue`, injects `.environment`, installs `.modelContainer` |
| `TranscriptionQueue` | `@MainActor @Observable` serial job queue (`TranscriptionJob`/`JobPhase`). **In-memory only — app kill loses queued work.** |
| `TranscriptionService` | Prompt loading, the two LLM passes, JSON parsing, date inference |
| `FastVLMModel` | MLX generation wrapper (`VLMModelFactory.shared.loadContainer`, `generate` → `Task<Void, Never>`) |
| `JournalPage` / `JournalEntry` (`JournalModels.swift`) | SwiftData `@Model`s; entries many-to-many `pages` (cross-page entries), `needsReview` flag |

`app/FastVLM/FastVLM.swift` is the vendored Apple model port (Qwen2 language
model in MLX, `fastvithd` CoreML vision tower behind `NSLock`,
`FastVLMProcessor` image preprocessing) registered as an MLX `VLMModel`. Leave
it alone unless the model itself changes.

Authoritative design doc: `docs/plan.md` (data model rationale, pipeline, screen
map, decisions). Its status table marks implementation steps 1–6 done; 7
(PageView + re-transcription) and 8 (polish) are open. The README "Status"
section is stale — the journal flow is largely implemented.

## Key Directories

- `app/FastVLM App/` — SwiftUI app: views, queue/service, SwiftData models,
  `prompts.txt`, entitlements. **All product code lives here.**
- `app/FastVLM/` — vendored FastVLM framework source; `app/FastVLM/model/`
  (gitignored) holds downloaded MLX weights + `fastvithd.mlpackage`, bundled as
  framework resources via a filesystem-synchronized folder.
- `app/Camera/` — `CameraPicker` (`UIImagePickerController` → JPEG `Data`).
- `app/Configuration/` — `Build.xcconfig` (vestigial, one unused variable).
- `llava/` — vendored LLaVA: `model/` (arch, Qwen2 backend), `train/`, `serve/`.
- `model_export/` — vision-encoder export to Core ML + mlx-vlm patch; see its
  README for the full weights pipeline.
- `docs/` — living `plan.md` and `bugs.md` (see Testing & QA).

## Development Commands

Model first — the build fails without it (weights are bundled resources):

```bash
chmod +x app/get_pretrained_mlx_model.sh
app/get_pretrained_mlx_model.sh --model 0.5b --dest app/FastVLM/model
# 0.5b = FP16 (fastest) | 1.5b = INT8 | 7b = INT4
```

Build/run (Mac with Apple Silicon + Xcode):

```bash
open app/FastVLM.xcodeproj   # scheme "FastVLM App", ⌘R
# CLI equivalent:
xcodebuild -project app/FastVLM.xcodeproj -scheme "FastVLM App" build
```

Destination: iOS 18.2+ device/simulator or My Mac (macOS 15.2+); set your
development team under Signing & Capabilities on first build.

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
  take `@Binding` (see `TranscribeForm`).
- **Concurrency**: service methods are `async throws`; the queue is serial by
  design (single `drainTask`). MLX token-stream callbacks hop back with
  `Task { @MainActor in … }`. Don't introduce concurrent generation without
  fixing `FastVLMModel.generate`'s reuse guard (`docs/bugs.md` #3) — it returns
  the wrong `Task` on overlap.
- **Error handling**: `throws` with `NSError(domain: "JournalApp", code: …)`;
  job failures surface as `JobPhase.failed` + banner row, never crashes. Never
  subscript model output with `split(...)[n]` — a missing bracket is an
  uncapturable `fatalError`; use guarded `firstIndex`/`lastIndex` like
  `parseEntries`.
- **Model errors travel through `output`**: `generate` writes `"Failed: …"`
  into `model.output`; `transcribePage`/`segmentPageTranscription` detect that
  prefix and throw (`docs/bugs.md` #2). Keep that contract when touching
  `FastVLMModel`.
- **Prompts are config**: behavior tweaks usually mean editing
  `app/FastVLM App/prompts.txt` (`=== SECTION ===` headers, `{transcription}`
  placeholder, `[illegible]` marker, JSON output shape), not Swift.
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
| `app/FastVLM App/TranscriptionService.swift` | The two-call pipeline + JSON/date parsing — most bug-prone area |
| `app/FastVLM App/TranscriptionQueue.swift` | Serial job lifecycle (enqueue/drain/cancel/auto-save) |
| `app/FastVLM App/FastVLMModel.swift` | MLX wrapper; generation params (temp 0.2, maxTokens 2400) live here |
| `app/FastVLM App/prompts.txt` | Runtime prompts; editing it changes transcription quality |
| `app/FastVLM/FastVLM.swift` | Vendored model implementation (upstream) |
| `app/FastVLM.xcodeproj/project.pbxproj` | Targets: `FastVLM App` (app), `FastVLM` (framework, bundles model), `Video` (empty shell) |
| `docs/plan.md`, `docs/bugs.md` | Living architecture plan and bug tracker |
| `pyproject.toml` | Python package `llava` (1.2.2.post1, `requires-python >= 3.8`) |

## Runtime/Tooling Preferences

- **Host**: macOS on Apple Silicon; Xcode 16.2+ (project `objectVersion 77`),
  Swift 5. Multi-platform target: iOS 18.2 / macOS 15.2 / visionOS 2.2.
- **Dependencies**: SwiftPM only (pinned: mlx-swift 0.25.6, mlx-swift-examples
  2.25.7, swift-transformers 0.1.24). Don't add other package managers.
- **Model files are gitignored** (`app/FastVLM/model/`, `checkpoints/`) — never
  commit weights. Code is licensed under `LICENSE` (permissive); model weights
  under `LICENSE_MODEL` (research/non-commercial only).
- **Sandbox**: the app is sandboxed with camera, user-selected read-only files,
  network client, and increased-memory entitlements — widen deliberately.
- **Python**: 3.10 via conda (README), `pip install -e .`; no linter/formatter
  config exists — match surrounding style. No Node/Bun tooling in this repo.

## Testing & QA

- **No automated tests and no CI.** No XCTest/pytest anywhere; the Xcode
  scheme's test action is empty; `llava/serve/test_message.py` is a manual
  serving-stack smoke client, not a test.
- QA is manual: every implementation step in `docs/plan.md` carries a
  verification checklist; `docs/bugs.md` is the regression list (worked top to
  bottom). Note the tracker drifts from code — e.g. its bug #1 (`parseEntries`
  fence-strip crash) is already fixed in `TranscriptionService.swift`; verify a
  listed bug still reproduces before "fixing" it.
- **Verify pipeline changes end-to-end**: build, run a real page image through
  capture → transcribe → segment → save, and inspect the parsed entries and
  `needsReview` flags in `EntryListView`. A compiling build is not proof here.
