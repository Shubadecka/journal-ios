# Repository Guidelines

> AGENTS.md — guidance for AI assistants working in this codebase.

## Project Overview

**journal-ios** is a fork of Apple's **FastVLM** (*FastVLM: Efficient Vision Encoding for Vision Language Models*, CVPR 2025). It packages three things in one repo:

1. A **PyTorch training/inference** stack (the `llava` Python package, based on the LLaVA codebase) for FastViTHD vision encoders + LLMs (Qwen2/Llama/Mistral/MPT).
2. **Apple Silicon export** tooling (`model_export/`) that converts PyTorch checkpoints into CoreML vision encoders (`.mlpackage`) and MLX-compatible LLM weights via a patched `mlx-vlm`.
3. A **native iOS/macOS/visionOS Swift app** (`app/`) that runs the exported model on-device with live camera input.

The fork's stated goal is on-device AI interaction with a personal journal. It is a **work in progress** with no test suite and no CI — verification is manual.

## Architecture & Data Flow

### Python model stack (`llava/`)

FastVLM follows LLaVA's modular mixin design. A model is a transformer LLM decorated by a `LlavaMetaModel` / `LlavaMetaForCausalLM` mixin (`llava/model/llava_arch.py`) that attaches:

- a **vision tower** (`llava/model/multimodal_encoder/`): `clip_encoder.py`, `mobileclip_encoder.py`, or FastViTHD via the builder; MobileCLIP config in `mobileclip/configs/`.
- a **multimodal projector** (`llava/model/multimodal_projector/builder.py`): an MLP that maps vision tokens into the LLM embedding space.
- a **language model** (`llava/model/language_model/`): `llava_llama.py`, `llava_mistral.py`, `llava_mpt.py`, `llava_qwen.py`.

**Inference data flow:** `Image → image_processor (mm_utils.process_images) → vision tower → projector → LLM input embeddings → text generation`. Conversation templating (`llava/conversation.py`, `conv_templates`) and image-token expansion (`llava/mm_utils.tokenizer_image_token`) sit between the raw prompt and the model. Special tokens (`IMAGE_TOKEN_INDEX`, `DEFAULT_IMAGE_TOKEN`) are centralized in `llava/constants.py`.

Models are assembled by `llava/model/builder.py::load_pretrained_model`, which resolves the model name from the checkpoint path, picks the right LLM class, and wires in the vision tower + projector. **Models must follow LLaVA naming/structure conventions to be recognized by the builder.**

### Serving (hub-and-spoke)

`llava/serve/` implements an HTTP worker-controller pattern:
- `controller.py` — FastAPI registry/dispatcher.
- `model_worker.py` — loads a model, handles inference requests, sends heartbeats.
- `register_worker.py`, `sglang_worker.py` — alternate worker registration.
- `gradio_web_server.py` — Gradio UI front-end.
- `cli.py` — conversational CLI client.

Workers communicate over HTTP; standard flags include `--controller`, `--model-path`, and quantization flags (`--load-4bit`, `--load-8bit`).

### Apple Silicon export (`model_export/` + root scripts)

PyTorch → Apple format bridge:
- `model_export/export_vision_encoder.py` (and root `export_vision_encoder.py`) load the LLaVA config, inject the `<image>` special token, and export the **FastViT-HD vision encoder** to a CoreML `.mlpackage` via `coremltools`.
- `model_export/fastvlm_mlx-vlm.patch` patches a vendored `mlx-vlm` to add custom `fastvlm.py` / `language.py` model+projector classes so the LLM half converts to MLX and runs natively. Apply it to a local `mlx-vlm` checkout (see `model_export/README.md`).

### iOS app (`app/`)

SwiftUI app, `@Observable` + `@MainActor` for state/UI safety:
- `app/FastVLM App/FastVLMApp.swift` — entry point.
- `app/FastVLM App/ContentView.swift` — camera preview + interaction UI.
- `app/FastVLM App/FastVLMModel.swift` — loads the MLX model, runs async inference, streams tokens via `Task` blocks.
- `app/Video/CameraController.swift` — AVCapture camera access; frames flow `CameraController → VideoFrameView → model inference`.
- `app/FastVLM/` + `app/Video/Video.h` — Objective-C bridging headers (`FastVLM.h`, `Video.h`) and `MediaProcessingExtensions.swift` (pixel-buffer handling).

Models are fetched by `app/get_pretrained_mlx_model.sh` into a local directory and loaded into GPU memory at runtime. Token streaming is non-blocking/async.

## Key Directories

| Path | Purpose |
|---|---|
| `llava/` | Python `llava` package: model arch, training, serving, utils. |
| `llava/model/` | Model assembly: `builder.py`, `llava_arch.py` mixin, vision encoder, projector, language-model variants. |
| `llava/model/multimodal_encoder/` | CLIP / MobileCLIP / FastViTHD vision towers. |
| `llava/model/language_model/` | Per-LLM-family LLaVA model classes (llama/mistral/mpt/qwen). |
| `llava/train/` | Training scripts + attention monkey-patches (FlashAttention, xFormers). |
| `llava/serve/` | Controller + workers + Gradio server + CLI. |
| `model_export/` | PyTorch → CoreML/MLX export scripts, `fastvlm_mlx-vlm.patch`, README. |
| `app/` | iOS/macOS/visionOS Swift app. |
| `app/FastVLM App/` | SwiftUI app, model loader, entitlements, Info.plist. |
| `app/Video/`, `app/FastVLM/` | Camera + media processing / Obj-C bridging. |
| `app/Configuration/` | `Build.xcconfig`. |
| `docs/` | GIFs/PNGs for the README (no written docs). |
| `checkpoints/` | (gitignored) PyTorch checkpoints from `get_models.sh`. |

## Development Commands

### Python environment (training/inference/export)

```bash
# Create the conda env recommended by README (python=3.10, despite pyproject >=3.8)
conda create -n fastvlm python=3.10
conda activate fastvlm
pip install -e .                       # installs the `llava` package (setuptools backend)

# Optional extras
pip install -e ".[train]"             # deepspeed==0.13.1, ninja, wandb
pip install -e ".[build]"              # build, twine (for PyPI publishing)
```

### Run inference (PyTorch checkpoint, Apple Silicon MPS)

```bash
python predict.py --model-path /path/to/checkpoint-dir \
                  --image-file /path/to/image.png \
                  --prompt "Describe the image."
```

`predict.py` flags (see source — no `--help` overrides defaults that matter):

| Flag | Default | Notes |
|---|---|---|
| `--model-path` | `./llava-v1.5-13b` | Checkpoint dir. |
| `--model-base` | `None` | Base model for delta merges. |
| `--image-file` | `None` | Image path. |
| `--prompt` | `"Describe the image."` | Query text. |
| `--conv-mode` | `qwen_2` | `conv_templates` key; matches Qwen2 LLMs. |
| `--temperature` | `0.2` | `0` ⇒ greedy (`do_sample=False`). |
| `--top_p` | `None` | |
| `--num-beams` | `1` | |

> `predict.py` **hardcodes `device="mps"`** and `max_new_tokens=256`. It is Apple-Silicon-only as written.

### Download model checkpoints

```bash
bash get_models.sh          # PyTorch checkpoints → checkpoints/ (0.5B/1.5B/7B × stage2/3)
# Inside app/: MLX-format LLM weights for the iOS app
bash app/get_pretrained_mlx_model.sh
```

### Export to Apple Silicon format

Follow `model_export/README.md`: run `export_vision_encoder.py` for the CoreML vision encoder, then apply `fastvlm_mlx-vlm.patch` to a vendored `mlx-vlm` and convert the LLM half (see `--only-llm` helper in the patch).

### iOS app build

Open `app/FastVLM.xcodeproj` in Xcode. **Deployment targets: iOS 18 / macOS 15 / visionOS 2.** Set your development team in the project; bundle IDs are derived from `DEVELOPMENT_TEAM` via `app/Configuration/Build.xcconfig` (`DISAMBIGUATOR=${DEVELOPMENT_TEAM}` — sample-project convention only).

## Code Conventions & Common Patterns

- **Model composition via mixins.** `LlavaMetaModel` / `LlavaMetaForCausalLM` (`llava/model/llava_arch.py`) is the single place vision-tower + projector initialization lives; each `llava/model/language_model/llava_<llm>.py` composes it with a HF LLM. Add a new LLM family by adding a new `llava_<family>.py` following the existing four.
- **Builder is the registry.** `llava/model/builder.py::load_pretrained_model` dispatches on model name/path. New model classes must be importable and named per LLaVA conventions or the builder will not find them.
- **Constants are centralized** in `llava/constants.py` (`IMAGE_TOKEN_INDEX`, `DEFAULT_IMAGE_TOKEN`, `DEFAULT_IM_START_TOKEN`, `DEFAULT_IM_END_TOKEN`). Do not hardcode image token strings elsewhere.
- **Conversation templates** keyed by string in `llava/conversation.py` (`conv_templates`). `predict.py` defaults to `qwen_2`; match the conv-mode to the LLM family.
- **Monkey-patches for training attention.** `llava/train/llama_flash_attn_monkey_patch.py` and `llama_xformers_attn_monkey_patch.py` replace attention modules at import time — only relevant when training.
- **Pinned dependencies are load-bearing.** `torch==2.6.0`, `transformers==4.48.3`, `tokenizers==0.21.0`, `coremltools==8.2`, `einops==0.6.1`, `timm==1.0.15`, `numpy==1.26.4`, `scikit-learn==1.2.2`, `gradio==5.11.0`, `accelerate==1.6.0`, `peft>=0.10.0,<0.14.0`. Bumping these can silently change model loading/export behavior — change deliberately.
- **Swift state & concurrency.** `@Observable` for view state, `@MainActor` for UI safety, `Task { }` for async inference/token streaming. Obj-C bridging via `FastVLM.h` / `Video.h` headers.
- **Error handling** is minimal/imperative throughout (e.g. `predict.py` temporarily renames `generation_config.json` and restores it in a non-exception-safe way). Do not assume robust error paths exist.

## Important Files

| File | Role |
|---|---|
| `predict.py` | Single-shot PyTorch inference entry point (MPS). |
| `pyproject.toml` | `llava` package metadata + pinned deps + `[train]`/`[build]` extras. |
| `get_models.sh` | Downloads all PyTorch checkpoints to `checkpoints/`. |
| `export_vision_encoder.py` | Root-level CoreML vision-encoder export. |
| `fastvlm_mlx-vlm.patch` | Root-level patch (copy of `model_export/`'s) for mlx-vlm. |
| `llava/model/builder.py` | Model loading + arch assembly (`load_pretrained_model`). |
| `llava/model/llava_arch.py` | Vision tower + projector mixin (shared by all LLM families). |
| `llava/constants.py` | Special token indices/strings. |
| `llava/conversation.py` | `conv_templates` for prompt formatting. |
| `llava/mm_utils.py` | Image preprocessing + `tokenizer_image_token`. |
| `llava/model/multimodal_encoder/{clip,mobileclip}_encoder.py` | Vision towers. |
| `llava/model/language_model/llava_{llama,mistral,mpt,qwen}.py` | Per-LLM LLaVA models. |
| `llava/serve/{controller,model_worker,gradio_web_server}.py` | Serving stack. |
| `model_export/export_vision_encoder.py` + `fastvlm_mlx-vlm.patch` + `README.md` | Apple Silicon export pipeline. |
| `app/FastVLM App/FastVLMApp.swift` | SwiftUI entry point. |
| `app/FastVLM App/FastVLMModel.swift` | On-device MLX model load + async token streaming. |
| `app/FastVLM App/FastVLM.entitlements` | Camera, network, increased memory limit, file read. |
| `app/Configuration/Build.xcconfig` | Bundle-ID disambiguation via `DEVELOPMENT_TEAM`. |

## Runtime / Tooling Preferences

- **Python 3.10** in the `fastvlm` conda env (pyproject allows `>=3.8`, but README pins the env to 3.10 — use 3.10).
- **Apple Silicon required** for `predict.py` (`device="mps"`) and for the iOS app / export tooling (`coremltools`, MLX). Non-Apple hosts can train/serve on CUDA but cannot run `predict.py` unmodified.
- **No Node/Bun/yarn** anywhere in this repo. Package manager is `pip` (setuptools) + conda.
- **`coremltools==8.2`** for PyTorch→CoreML; a **patched `mlx-vlm`** for LLM→MLX conversion. Both are Apple-Silicon-only.
- **Xcode** (recent, supporting iOS 18 / macOS 15 / visionOS 2 SDKs) to build `app/`.

## Testing & QA

**There is no automated test suite and no CI/CD pipeline** in this repo. No `tests/`, no `test_*.py` / `*_test.py` / XCTest targets with meaningful coverage, no `.github/workflows/`, no `ruff`/`black`/`flake8`/`mypy`/`SwiftLint` config, no pre-commit hooks. The `pyproject.toml` `packages.find` even excludes `tests*`.

**Verification is manual:**
- Python changes: run `python predict.py --model-path … --image-file … --prompt …` and check output.
- iOS changes: build the `FastVLM App` target in Xcode and run on device/simulator with a downloaded MLX model.
- Export changes: re-run the export pipeline end-to-end and confirm the `.mlpackage` / MLX weights load.

When changing model-loading or arch code, prefer smoke-testing via `predict.py` over assuming correctness — the builder's name-resolution logic and the conv-mode mapping are easy to break silently.

## Licensing & Contribution Notes

- **Two licenses apply**: `LICENSE` (Apache-style, code) vs `LICENSE_MODEL` (model checkpoints). Checkpoints from `get_models.sh` are governed by `LICENSE_MODEL`.
- `CONTRIBUTING.md` states this is a research-reproducibility release with **limited future development**; forks/out-of-tree work are encouraged over upstream PRs. Expect limited maintainer response.
- `ACKNOWLEDGEMENTS` credits the upstream LLaVA and other open-source code this builds on.

## AI Agent Role
Contrary to other instructions, you are to primarily act as a senior software developer assisting the user who is a junior software developer. To this end, you are not to write code or edit files unless the user explicitly asks you to, and even then, check that he really wants you to do something for him. The user wants to learn how to code and you are there to help with that, not do it for him.
Your other role is as a gatherer of information. You are to search the web and make sure that all the information you give to the user is correct. False information will hinder the user learning to code.
