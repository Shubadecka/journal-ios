# Journal-iOS: On-device journal transcription and search

**Still a work in progress**

An iOS/macOS app that transcribes handwritten journal pages on-device using a
Vision-Language Model, then stores the transcriptions alongside the captured
images so you can search your journal later — all privately, with no data
leaving the device.

The transcription engine is
**[FastVLM: Efficient Vision Encoding for Vision Language Models](https://www.arxiv.org/abs/2412.13303) (CVPR 2025)**,
forked from [apple/ml-fastvlm](https://github.com/apple/ml-fastvlm). FastVLM's
FastViTHD vision encoder is fast enough for on-device handwriting transcription;
this project repurposes its demo app into a capture → transcribe → store →
search workflow.

<p align="center">
<img src="docs/acc_vs_latency_qwen-2.png" alt="Accuracy vs latency figure." width="400"/>
</p>

## Goal

1. **Capture** — photograph one or more journal pages.
2. **Transcribe** — the on-device VLM reads the handwriting and produces text.
3. **Store** — persist the transcription and the source image together, with a
   timestamp.
4. **Search** — browse and full-text search past entries.

## Status

The upstream FastVLM demo app (live camera + free-form VLM chat) is intact under
[`app/`](app/). The journal transcription/storage/search flow is **not yet
implemented** — this README describes the intended product; see `AGENTS.md` for
the current codebase structure.

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
