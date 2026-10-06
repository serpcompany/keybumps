# 0008: Dictation transcribes with whisper.cpp on the GPU

Status: Accepted (2026-10-06; the owner approved shipping it in beta.18). Tracked by #279; it also resolves #277. Step 1 is #283.

## Context

Dictation runs Whisper through WhisperKit on the Neural Engine. Measured on the owner's Mac on 2026-10-06 (#277, #278, #279):

- **The wait after speaking is long.** With the model loaded, a 7-second dictation took 0.90 s. After five idle minutes it took a median of 2.05 s, because the model loaded only after the person stopped talking (#278 moves the load to the start of recording).
- **The first dictation after a few unused days can take about 90 seconds.** macOS deletes compiled Neural Engine models it hasn't used recently, and recompiling Turbo took 84–98 s.
- **Superwhisper, on the same Mac,** records 0.14 s with small.en and 0.33 s with medium.en. It runs whisper.cpp on the GPU.

The benchmark in #279 ran the same clips through both engines: four synthesized English clips, with the model loaded.

| Engine and model | 7.2 s clip | 46.6 s clip | Uncached load |
| --- | --- | --- | --- |
| WhisperKit, Turbo, Neural Engine | 0.90 s | 2.8 s | 84–98 s |
| whisper.cpp, Turbo q5_0, GPU | 0.32 s | 0.89 s | about 20 s (one-time GPU shader compile), then 0.25 s |

Accuracy on those clean clips was equal. Accuracy on real speech is the remaining check.

## Decisions

1. **The engine is whisper.cpp** (ggml-org, MIT), from its official release framework: `whisper-b5130-xcframework.zip`, which is v1.9.4.
   - It's added as a Swift package binary target pinned by SHA-256, in a local package under `apps/macos/Packages/`.
   - It runs on the GPU (Metal) with flash attention, greedy decoding, and full 30-second windows. Shrinking the window (`audio_ctx`) repeated text on short clips with Turbo, so it stays off.
2. **The model is large-v3-turbo, quantized q5_0.**
   - It's `ggml-large-v3-turbo-q5_0.bin`, 574,041,195 bytes, SHA-256 `394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2`.
   - It comes from `huggingface.co/ggerganov/whisper.cpp`, pinned to revision `5359861c739e955e79d9a303bcbc70fb988958b1`.
   - q8_0 (874 MB) may replace it if it proves more accurate at the same speed.
3. **The model is a download, not bundled.**
   - Bundling it would take the app from 12 MB to about 590 MB, and every Sparkle update would download it again.
   - Keybumps offers the download and selects the model once it's installed. Apple Speech covers the time until then, as it does today.
   - Bundling stays possible if zero-setup Dictation matters more than download size.
4. **No Neural Engine.** Keybumps never places a Core ML encoder (`*-encoder.mlmodelc`) next to the model. So whisper.cpp falls back to the GPU, and macOS's compiled-model cleanup can't cause a recompile.
5. **The move is gradual.**
   - First, whisper.cpp Turbo is added as another engine, beside the WhisperKit models.
   - Then it becomes the default.
   - Finally, WhisperKit, its package, and its downloaded models are removed. The old model folders (up to about 2.5 GB in Application Support) are deleted.
6. **Loading starts when recording starts** (#278), whatever the engine.

## Consequences

- **First load:** the first load after install, or after macOS clears the app's Metal shader cache, compiles GPU shaders. That took about 20 s on a heavily loaded Mac. Later loads take about 0.25 s, and starting the load when recording starts (#278) hides most of it.
- **Licensing:** `apps/macos/LICENSE.whisper-cpp` carries ggml-org's MIT license. The weights are OpenAI's Whisper (MIT, `LICENSE.openai-whisper`, already shipped).
- **Signing:** the framework is embedded and re-signed with the app's Developer ID identity, so notarization covers it.
- **Size:** the app grows by about 8 MB, the framework's universal binary.
- **Before Turbo becomes the default:**
  - The owner confirms accuracy on real recordings, locally, with `~/dev/prototypes/keybumps-whisper-comparison/compare-all.sh`.
  - q8_0 is measured against q5_0.
- **Fixes that stop applying:** #277's Neural Engine problems no longer apply. A timeout that keeps the recording is still worth adding for any engine.
