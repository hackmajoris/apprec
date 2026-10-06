# AppRec

A macOS menu bar app that records one app's audio plus your microphone, then writes a transcript and a summary and names the recording after what was said. Transcription runs on your Mac; summaries run on your Mac through Ollama or Apple Intelligence.

Website: https://hackmajoris.github.io/apprec/

## Features

- **Record one app.** Pick any running app (Teams, Zoom, a browser, Slack…) and record only its sound, optionally mixed with your microphone.
- **On-device transcription.** Whisper large-v3 turbo runs locally through [WhisperKit](https://github.com/argmaxinc/WhisperKit). The spoken language is detected automatically.
- **Summaries.** Each transcript gets a summary with a TL;DR, key points and action items, in the language of the recording.
- **Descriptive names.** After summarizing, the recording's folder is renamed to the date plus a short title, e.g. `2026-10-06 12.40 Release planning for Friday`.
- **Plain files.** Everything is saved in `~/Music/Recordings`, one folder per recording.

## Requirements

| | Minimum | Recommended |
|---|---|---|
| macOS | 15 | 26, which adds Apple Intelligence summaries when Ollama isn't installed |
| Mac | Apple silicon | |
| Memory | 8 GB (summaries use `gemma3:4b`) | 16 GB or more (summaries use `gemma3:12b`, which writes better summaries) |
| Disk | About 1 GB for the speech model | About 10 GB: speech model plus Ollama with `gemma3:12b` (8.1 GB) |
| Summaries | None: recordings are transcribed only | [Ollama](https://ollama.com/download), for summaries in the language of the recording |

Building from source also needs Xcode 26 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

## Install

### Homebrew

```sh
brew install --cask hackmajoris/apps/apprec
```

Update with `brew upgrade --cask apprec`.

AppRec isn't notarized by Apple yet. The cask removes the quarantine flag so macOS doesn't block the app.

### From source

```sh
git clone https://github.com/hackmajoris/apprec
cd apprec
brew install xcodegen
make install
```

`make install` builds a release and copies it to `/Applications`.

## Usage

1. Click the waveform icon in the menu bar.
2. Choose the app to record. Turn **Include microphone** off if you only want the app's sound.
3. Click **Record**, then **Stop** when you're done.

After you stop, AppRec saves the audio, transcribes it and summarizes it on its own. Each recording in the list has buttons to open the transcript, open the summary, play, and move it to the Trash. Rows without a transcript or summary show a button to create one. Right-click a recording to show it in Finder.

The first recording asks for **Screen & System Audio Recording** permission (needed to capture another app's sound) and **Microphone** permission.

### Files

```
~/Music/Recordings/
  2026-10-06 12.40 Release planning for Friday/
    audio.m4a
    transcript.txt
    summary.md
```

New recordings start as `<App> <date and time>/` and are renamed once the summary is written. Deleting a recording in AppRec moves its folder to the Trash.

## Transcription

- **Model:** Whisper large-v3 turbo, Core ML build `openai_whisper-large-v3-v20240930_turbo_632MB` from [argmaxinc/whisperkit-coreml](https://huggingface.co/argmaxinc/whisperkit-coreml).
- **First use:** the model (about 630 MB) is downloaded to `~/Library/Application Support/AppRec`, then macOS prepares it for your chip. This can take a few minutes and the menu shows progress. It happens once.
- **After that:** works offline. Audio is split at pauses and the language is detected automatically. On an M3 Max, a 30 second clip takes about 5 seconds.

## Summaries

AppRec picks a summary model in this order:

1. **Ollama**, if it's running on `localhost:11434` and the selected model is installed. The summary is written in the transcript's language.
2. **Apple Intelligence**, on macOS 26 or later with Apple Intelligence turned on. Summaries are always in English, because the on-device model doesn't handle every language well.

If neither is available, recordings are still transcribed but not summarized.

### Ollama setup

1. Install [Ollama](https://ollama.com/download) and open it.
2. In AppRec, expand **Summary configs**. It shows whether Ollama is installed and running, and offers **Open Ollama** if it isn't running.
3. Pick a model. The recommended one is `gemma3:12b` on Macs with 16 GB of memory or more, and `gemma3:4b` otherwise. If it isn't installed yet, click **Download** and AppRec pulls it through Ollama.

Any model installed in Ollama shows up in the picker.

## Privacy

Audio, transcripts and summaries stay on your Mac. AppRec only goes online to download the speech model once, and to talk to Ollama on `localhost`.

## Development

```sh
make          # list commands
make run      # build and launch a debug build
make install  # build a release and install it to /Applications
make dist     # zip the release app to build/AppRec.zip and print its SHA-256
make site     # serve the website from docs/ at http://localhost:8000
make clean    # remove build output
```

The Xcode project is generated from `project.yml` by XcodeGen and isn't checked in. WhisperKit is the only package dependency.

| Path | What it is |
|---|---|
| `Sources/Recorder.swift` | Audio capture with ScreenCaptureKit, the recordings folder, transcribe and summarize flow, renaming |
| `Sources/LocalTranscriber.swift` | WhisperKit model download, preparation and transcription |
| `Sources/Summarizer.swift` | Chooses Ollama or Apple Intelligence; Apple Intelligence summaries |
| `Sources/Ollama.swift` | Ollama detection, model list and download, summaries |
| `Sources/MenuView.swift` | The menu bar window |
| `Sources/Player.swift` | Playback |
| `docs/` | The website, published with GitHub Pages |
| `packaging/apprec.rb` | Homebrew cask template |

## Releasing

Push a version tag:

```sh
git tag v1.0.0
git push origin v1.0.0
```

The release workflow builds `AppRec.zip`, publishes a GitHub release and updates `Casks/apprec.rb` in [hackmajoris/homebrew-apps](https://github.com/hackmajoris/homebrew-apps) from `packaging/apprec.rb`.

This needs a repository secret `HOMEBREW_TAP_TOKEN`: a fine-grained token with **Contents: Read and write** access to `hackmajoris/homebrew-apps` only.

```sh
pbpaste | gh secret set HOMEBREW_TAP_TOKEN --repo hackmajoris/apprec
```

The website is deployed by the Pages workflow on every push to `main` that changes `docs/`.

## Known limitations

- The app is ad-hoc signed, not notarized. macOS may ask for recording and microphone permission again after an update.
- Apple Intelligence summaries are English only.
- The app's version number is fixed at `1.0` in `project.yml` and doesn't follow release tags.
