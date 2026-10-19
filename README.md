# Journal-iOS: On-device journal transcription and search

**Still a work in progress**

An iOS/macOS app that turns photos of handwritten journal pages into searchable
text. Photograph or import one or more pages, and an on-device Vision-Language
Model transcribes the handwriting; a second model pass splits each transcription
into individual dated entries. Entries and their source images are stored
locally with SwiftData, so you can browse and search your journal later — all
privately, with no data leaving the device.

The transcription engine is
**[FastVLM: Efficient Vision Encoding for Vision Language Models](https://www.arxiv.org/abs/2412.13303) (CVPR 2025)**,
forked from [apple/ml-fastvlm](https://github.com/apple/ml-fastvlm). FastVLM's
FastViTHD vision encoder is fast enough for on-device handwriting transcription;
this project repurposes its demo app into a capture → transcribe → store →
search workflow.

<p align="center">
<img src="docs/acc_vs_latency_qwen-2.png" alt="Accuracy vs latency figure." width="400"/>
</p>

## How it works

1. **Capture** — photograph one or more journal pages, or import them from
   Photos. Each batch is queued and transcribed in the background while a
   banner shows progress.
2. **Transcribe** — the on-device VLM reads each page verbatim; unreadable
   words are marked `[illegible]`.
3. **Segment** — a second text-only model pass splits the transcription into
   individual entries and assigns each a date (dates may be inferred from the
   page and flagged for review).
4. **Store** — entries are saved together with the source image in a local
   SwiftData store.
5. **Search** — browse entries newest-first and full-text search past entries;
   entries with inferred dates are marked with a red border for review.

## Status

The journal flow is implemented end-to-end: multi-page capture/import, on-device
transcription and segmentation, a serial transcription queue with progress
banner, and browse/search over saved entries. Remaining work: a page view with
re-transcription and polish — see [`docs/plan.md`](docs/plan.md) for step status
and [`AGENTS.md`](AGENTS.md) for the codebase structure.

## Getting Started

The app runs the FastVLM model on-device. You need a Mac (Apple Silicon) with
Xcode to build it.

### Download a model

```bash
chmod +x app/get_pretrained_mlx_model.sh
app/get_pretrained_mlx_model.sh --model 0.5b --dest app/FastVLM/model
```

Model options: `0.5b` (fastest, FP16), `1.5b` (balanced, INT8), `7b` (most
accurate, INT4). See [`app/README.md`](app/README.md) for details.

### Build and run

```bash
open app/FastVLM.xcodeproj
```

Select the `FastVLM App` target and a destination (iOS 18.2+ device/simulator,
or My Mac on macOS 15.2+), set your development team under Signing & Capabilities,
then `⌘R`.

### Python inference / training (optional)

The `llava` Python package and `predict.py` are retained from the upstream fork
for training, evaluation, and PyTorch inference.

```bash
conda create -n fastvlm python=3.10
conda activate fastvlm
pip install -e .

python predict.py --model-path /path/to/checkpoint-dir \
                  --image-file /path/to/image.png \
                  --prompt "Describe the image."
```

PyTorch checkpoints: `bash get_models.sh` (downloads to `checkpoints/`).
Export to Apple Silicon format: see [`model_export/`](model_export/).

## Citation
Forked from **[FastVLM](https://github.com/apple/ml-fastvlm)** based on the following paper:
```
@InProceedings{fastvlm2025,
  author = {Pavan Kumar Anasosalu Vasu, Fartash Faghri, Chun-Liang Li, Cem Koc, Nate True, Albert Antony, Gokul Santhanam, James Gabriel, Peter Grasch, Oncel Tuzel, Hadi Pouransari},
  title = {FastVLM: Efficient Vision Encoding for Vision Language Models},
  booktitle = {Proceedings of the IEEE/CVF Conference on Computer Vision and Pattern Recognition (CVPR)},
  month = {June},
  year = {2025},
}
```

## Acknowledgements
Our codebase is built using multiple opensource contributions, please see [ACKNOWLEDGEMENTS](ACKNOWLEDGEMENTS) for more details.

## License
Please check out the repository [LICENSE](LICENSE) before using the provided code and
[LICENSE_MODEL](LICENSE_MODEL) for the released models.
