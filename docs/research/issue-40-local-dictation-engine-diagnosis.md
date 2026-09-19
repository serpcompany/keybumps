# Issue #40: local dictation engine diagnosis

Date: 2026-09-19

## Verdict

Yes, with one important qualification: the right cross-version MVP is an **optional downloaded multilingual Whisper model behind the existing completed-WAV seam**, not merely a download button. Keybumps must also ship a native inference runtime, verify and manage the model, normalize audio, expose an explicit engine state, and fall back safely.

The recommended MVP is:

1. Keep the current `SFSpeechURLRecognitionRequest` implementation as the zero-download fallback.
2. Add a `whisper.cpp` adapter for macOS 14.2+ and offer one optional multilingual model download.
3. Start evaluation with `large-v3-turbo-q5_0` (547 MiB) against `small` (466 MiB) on the same approved English and Japanese WAV fixtures. Select the shipped default only if it measurably wins the issue #40 accuracy, punctuation, latency, and resource tests.
4. On macOS 26+, also benchmark Apple's new `SpeechAnalyzer` / `SpeechTranscriber`. It may become the preferred system engine there, but it cannot serve all currently supported Keybumps users because the app's deployment target is macOS 14.2.

Downloading Whisper is therefore the likely implementation path, but it is not yet evidence that Whisper beats Apple on Keybumps' samples or reproduces Superwhisper's complete output quality.

## Why this is the minimum architecture

### Engine seam

Keep recording, history, retry, insertion, and the per-recording `output.wav` / `meta.json` layout unchanged. Introduce a small completed-file transcription interface with three implementations:

- `whisperLocal`: preferred only when its verified model is installed and initialized;
- `appleSpeechAnalyzer`: macOS 26+ evaluation path, subject to device and locale availability;
- `appleLegacy`: the existing on-device `SFSpeechRecognizer` fallback.

Persist the engine and model identifier used for a result, but do not fork the recording lifecycle. A Whisper failure should leave the WAV retryable and offer the Apple fallback; it must not silently replace an explicitly selected engine's output.

### Runtime

Use `whisper.cpp`, not OpenAI's Python/PyTorch package, in the shipped app. The official project is a dependency-light C/C++ implementation, supports macOS on Intel and Arm, treats Apple Silicon as a first-class target, and supports Accelerate, Metal, Core ML, and CPU-only inference. Its official SwiftUI example documents building and embedding an XCFramework for Apple apps. On Apple Silicon, Metal can run inference on the GPU; Core ML can accelerate the encoder, but the GGML model remains necessary for the decoder. ([whisper.cpp README](https://github.com/ggml-org/whisper.cpp/blob/master/README.md), [official SwiftUI example](https://github.com/ggml-org/whisper.cpp/blob/master/examples/whisper.swiftui/README.md))

The old standalone `whisper.spm` repository explicitly says it will be archived and directs users to integrate from `whisper.cpp`, so it should not be a new production dependency. ([whisper.spm README](https://github.com/ggerganov/whisper.spm))

Both OpenAI Whisper's code and weights and `whisper.cpp` use the MIT License; their copyright notices and license text must be included in the product's third-party notices. ([OpenAI Whisper license](https://github.com/openai/whisper/blob/main/LICENSE), [whisper.cpp license](https://github.com/ggml-org/whisper.cpp/blob/master/LICENSE))

### Model download and lifecycle

Do not bundle a large model in the app. The model manager should:

- show exact download and expected installed size before consent;
- download into a temporary file with progress, cancellation, and retry;
- verify a pinned cryptographic digest from the release manifest;
- atomically move the verified file under Keybumps Application Support;
- retain the last known-good version while updating;
- expose installed, downloading, corrupt, incompatible, and unavailable states;
- allow deletion and clean re-download;
- perform no network access during transcription.

The official `whisper.cpp` catalog publishes GGML disk sizes and SHA values, but its shell downloader is not an application-grade lifecycle manager. Keybumps should pin its own release-manifest URL, byte size, and SHA-256 rather than trusting only a filename or a partial download. ([official model catalog](https://github.com/ggml-org/whisper.cpp/blob/master/models/README.md), [official downloader](https://github.com/ggml-org/whisper.cpp/blob/master/models/download-ggml-model.sh))

Official unquantized/selected quantized catalog sizes are:

| Model | Disk | Language behavior | MVP role |
| --- | ---: | --- | --- |
| `base` | 142 MiB | Multilingual | Too accuracy-constrained to assume as the quality upgrade |
| `small` | 466 MiB | Multilingual | Compact comparison candidate |
| `medium` | 1.5 GiB | Multilingual | Larger comparison candidate if the first two fail |
| `large-v3-turbo-q5_0` | 547 MiB | Multilingual, quantized | Recommended first quality/latency candidate |
| `large-v3-turbo` | 1.5 GiB | Multilingual | Escalation candidate if quantization materially harms the fixtures |

These are download/disk figures, not peak runtime memory promises. OpenAI's upstream table reports approximate required VRAM of about 2 GB for `small` and 6 GB for `turbo`, and warns that real speed varies by language, speech, and hardware. ([OpenAI Whisper README](https://github.com/openai/whisper/blob/main/README.md#available-models-and-languages))

### English and Japanese

Use a multilingual model name without `.en`. OpenAI describes `.en` variants as English-only and demonstrates Japanese transcription by selecting Japanese. `turbo` is appropriate for transcribing speech in its original language; its documented limitation concerns speech translation into English, which is outside issue #40. ([OpenAI Whisper README](https://github.com/openai/whisper/blob/main/README.md#available-models-and-languages))

Keep Keybumps' explicit per-recording language selector for the MVP: English selects English and Japanese selects Japanese. Do not add automatic language detection in this issue. Test punctuation, omitted text, names/technical terms, and beginning/middle/end retention separately for both languages. Whisper processes a file through sliding 30-second windows, so long-file preservation still needs deterministic and physical tests rather than being assumed from the model choice. ([OpenAI Whisper README](https://github.com/openai/whisper/blob/main/README.md#python-usage))

### Apple's newest path

Apple's macOS 26 `SpeechAnalyzer` / `SpeechTranscriber` is a genuine third candidate, not the current `SFSpeechRecognizer` with a new name. Apple says its new on-device model is designed for long-form and conversational audio, low latency, accuracy, and readability. `AssetInventory` downloads locale assets into system storage, updates them automatically, and keeps them outside the app's download, storage, and memory footprint. Apple also provides `supportedLocales`, `installedLocales`, and a `DictationTranscriber` fallback for unsupported hardware or languages. ([Apple WWDC25 session](https://developer.apple.com/videos/play/wwdc2025/277/), [SpeechTranscriber documentation](https://developer.apple.com/documentation/speech/speechtranscriber), [AssetInventory documentation](https://developer.apple.com/documentation/speech/assetinventory))

This is operationally simpler than owning Whisper models, so it should be measured on macOS 26. It is not the cross-version answer while Keybumps retains macOS 14.2 support, and Apple does not publish a fixed model byte size that Keybumps can promise.

## What the download alone will not solve

OpenAI warns that Whisper accuracy varies by language and accent and that models may hallucinate or repeat text. The perceived result also depends on audio conversion, decoding parameters, segmentation/VAD, language selection, optional vocabulary prompting, punctuation policy, and transcript assembly. ([OpenAI Whisper model card](https://github.com/openai/whisper/blob/main/model-card.md))

Therefore, issue #40 should approve implementation only after the same privacy-safe completed WAVs establish:

- English word error and Japanese character error, punctuation, and omissions;
- preservation of the beginning, middle, and end of long recordings;
- wall-clock latency and peak CPU/memory on the minimum supported Apple Silicon Mac;
- offline retry after installation;
- corrupt/missing model behavior and Apple fallback;
- installed Developer ID record -> transcribe -> insert behavior in an editor and browser.

If neither the Whisper candidate nor macOS 26 SpeechTranscriber materially beats the repaired Apple baseline, Keybumps should keep the existing engine rather than ship model weight for branding alone.
