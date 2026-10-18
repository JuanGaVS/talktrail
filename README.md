# Talktrail

Local call transcription for macOS. Talktrail records your microphone and the call audio (Zoom, Teams, Meet, anything), transcribes them on the Mac and saves a Markdown file to `~/Documents/Transcripts`. **No audio or text ever leaves the Mac.**

For now that is its only feature: there is no noise suppression or accent conversion.

The app and the command-line tool are in English and Spanish and follow the macOS language.

## Why there is no audio driver

Many call tools install a virtual audio driver (a Core Audio HAL plug-in) that you have to pick as the microphone or speaker in Zoom, Teams or Meet. That is needed to **modify** the audio, for example to remove noise. To **only transcribe**, it is not: Talktrail reads the microphone like any other app and captures what plays through the speakers with a Core Audio *process tap* (macOS 14.4+). It installs nothing in `/Library`, needs no administrator rights, cannot take down `coreaudiod`, and you never have to change the device in your call app.

## How it works

```
Microphone ──► AVAudioEngine ─────────────► SpeechAnalyzer ("Me") ───────┐
                                                                         ├─► live draft (temporary)
System audio ──► process tap ──► SpeechAnalyzer ("Remote") ──────────────┘
                      │                                                    when stopped:
                      └──► remote audio (temporary, 16 kHz) ──► diarization (FluidAudio)
                                                                         │
                               ~/Documents/Transcripts/transcript-….md ◄─┘
```

- **Transcription:** Apple's `SpeechAnalyzer` / `SpeechTranscriber` (macOS 26), entirely on the device. One analyzer per channel.
- **Echo:** without headphones, the microphone also picks up the call. Phrases from "Me" that repeat a remote phrase spoken at the same moment are dropped.
- **Speaker identification:** when you stop, the remote audio goes through [FluidAudio](https://github.com/FluidInference/FluidAudio): pyannote segmentation, WeSpeaker embeddings and VBx clustering, on Core ML. Each word is attributed to "Speaker 1", "Speaker 2"…, and a phrase is split where the speaker changes. The microphone stays "Me". An hour of audio takes a minute or two.
- **Files:** the live draft is written to the user's private temporary folder and deleted once the final transcript is saved. The temporary remote audio is deleted too. If the app quits unexpectedly, the next recording recovers the draft as `…-recovered.md`.

Sample output:

```markdown
# Transcript

- **Started:** 2026-10-17 10:12:25
- **Language:** en_US
- **Participants:** Me (microphone) · Speaker 1–2 (call audio)

---

**[10:12:40] Speaker 1:** Good morning, everyone, thanks for joining.

**[10:12:46] Me:** Thanks. Let's start with the budget.
```

## Privacy and network

| What | Where | Network |
|---|---|---|
| Final transcript | `~/Documents/Transcripts` (permissions `600`) | — |
| Live draft and temporary remote audio | the user's temporary folder; deleted when done | — |
| Apple speech model (one per language) | installed by macOS the first time a language is used | one-time download from Apple, model only |
| Speaker identification models (21 MB) | inside `Talktrail.app` | **none**: the app forces `ModelHub.offlineMode` |

## Requirements

- macOS 26 or later. The default build targets Apple Silicon.
- Command Line Tools with Swift 6.2 or later (Xcode is not required).

## Building

```sh
scripts/build.sh
```

This produces `build/Talktrail.app` (the menu bar app) and `build/talktrail` (the CLI), ad-hoc signed. GitHub Actions runs the same script on macOS 26 for every pull request and every push to `main` (`.github/workflows/build.yml`). To distribute it to other Macs, sign with a Developer ID and notarize:

```sh
SIGN_IDENTITY="Developer ID Application: <Name> (<TEAMID>)" scripts/build.sh
```

### Models

`Models/speaker-diarization` is included (revision `df2625ac…`; the SHA-256 hashes match its `provenance.json`). To download it again:

```sh
swift build -c release --product talktrail
.build/release/talktrail fetch-models /tmp/talktrail-models
cp -R /tmp/talktrail-models/speaker-diarization Models/
```

## Usage

**App:** open `Talktrail.app`. A waveform icon appears in the menu bar, where you can:

- Start and stop a transcription.
- Pick the language of the call.
- Turn the microphone, the call audio and speaker identification on or off.
- Open the last transcript or the transcripts folder.

The first time, macOS asks for **Microphone** and **System Audio Recording** permission.

**CLI:**

```sh
build/talktrail record -l en-US          # records until Ctrl+C
build/talktrail transcribe meeting.m4a   # transcribes a file and identifies the speakers
build/talktrail locales                  # available languages
build/talktrail --help
```

Run from a terminal, `talktrail record` only captures the microphone reliably. iTerm2 and Terminal don't declare `NSAudioCaptureUsageDescription`, so macOS gives them silence instead of the system audio. Use the app to record calls.

## Languages

The interface, the transcript headings and labels ("Me", "Speaker 1"), and the transcripts folder follow the macOS language: English by default, Spanish ("Yo", "Persona 1", `~/Documents/Transcripciones`) when Spanish comes first in System Settings > General > Language & Region. To use a different language for the app only, add Talktrail under **Applications** on that same screen.

The language of the call itself is chosen separately, in the app's menu or with `talktrail -l`.

User-facing text is written in English in the code, through `localized("…")`, and translated in `Sources/TalktrailCore/Resources/es.lproj/Localizable.strings`. `scripts/check-localizations.py` checks that every text has a Spanish translation with the same format specifiers; CI runs it on every pull request.

## Known limitations

- **One language per session.** If the call mixes languages, whatever is said in the other language is transcribed poorly.
- **Names:** speaker identification tells voices apart, not names; rename "Speaker 1" by hand. With short turns (≈2 s) from similar voices, the model can attribute them to the neighbouring speaker or merge two voices into one. In tests with synthetic voices this happened with two male voices. It still needs validating on real calls.
- **Without headphones**, the echo filter drops clear repetitions, but if you talk over someone, that "Me" phrase can include part of what they said.
- **Timestamps** are accurate to about ±0.5 s.

## Troubleshooting

- **`swift build` fails with `extra argument 'swiftLanguageModes'`:** the Command Line Tools were left with stale Swift 5.10 files. Fix:
  `sudo rm /Library/Developer/CommandLineTools/usr/lib/swift/pm/ManifestAPI/PackageDescription.swiftmodule/*.private.swiftinterface`
- **The "Remote" side is empty:** the permission is missing in System Settings > Privacy & Security > Screen & System Audio Recording. Without it, macOS delivers silence instead of an error. The app warns after 45 s of silence.
- **macOS asks for the permissions again after every build:** that happens with ad-hoc signing, because the identity changes with every build. It doesn't happen with a Developer ID.
- **Diagnostics:** `TALKTRAIL_DEBUG=1` shows each channel's audio level, the timing of every word and each speaker's turns. For the app: `open --env TALKTRAIL_DEBUG=1 --stderr /tmp/talktrail.log build/Talktrail.app`.

## License

Talktrail is licensed under [Apache-2.0](LICENSE). Third-party attributions are in [NOTICE](NOTICE). `scripts/build.sh` copies both files, along with FluidAudio's licenses, to `Talktrail.app/Contents/Resources/Licenses`.

### Third-party licenses

- [FluidAudio](https://github.com/FluidInference/FluidAudio) 0.17.7: Apache-2.0. It is built without the `NemoTextProcessing` trait, so its prebuilt binary is not linked.
- `FluidInference/speaker-diarization-coreml` models: CC-BY-4.0, derived from [pyannote/speaker-diarization-community-1](https://huggingface.co/pyannote/speaker-diarization-community-1). They require attribution when distributed.
