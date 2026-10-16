# Vecta

**Your PLAUD recordings, directly transferred and processed on your Mac.**

Vecta is a native Apple Silicon macOS app that connects to compatible PLAUD
recorders over Bluetooth and local Wi-Fi Fast Transfer — without the PLAUD SDK, a
relay website, or a recording-transfer middleman. Keep recordings in a searchable
local library, transcribe and summarize them on your Mac, remember speakers across
meetings, and export visual or PDF reports when you need to share the result.

**Recording content is not sent to cloud inference, and Vecta has no cloud-inference
fallback.** The interface supports English and Russian.

[Download Vecta 0.1.0 build 79](https://github.com/olgvroe/Vecta/releases/tag/v0.1.0-build79)
· [Installation](docs/INSTALL.md)
· [Build from source](docs/BUILD.md)

![English transcript with named speakers](docs/assets/screenshots/transcript.png)

*Screenshots show the real native interface with fictional meeting data. The demo
transcript and summaries are prepared examples, not model-quality benchmarks.*

## A local workflow

Vecta implements its own **BLE and local Wi-Fi Fast Transfer**, without the PLAUD
SDK, a relay website, or an intermediary service for recording transfer. Audio is
received directly from the selected recorder and kept in your local library.

Speech recognition, speaker separation, text and visual summaries, and the
assistant run on your Mac. **No recording content is sent to cloud inference, and
there is no cloud fallback.** You do not need Docker, a browser dashboard or a
separate model server.

Internet access is needed for initial device authorization and model downloads.
Once your recorder is configured and the models are installed, normal recording
transfer and processing work without Internet access. Installing another model
or deliberately refreshing authorization may require it again.

> **Device setup:** first-time connection to a modern PLAUD recorder requires your
> own authorized PLAUD Partner credentials. Vecta does not include shared keys or
> provide Partner access. You can import local audio without device credentials.
> See [setup and network boundaries](#setup-and-network-boundaries).

## Remember who is speaking

Save named voice profiles and use them in later recordings. Confirm a suggested
speaker, correct a name, or merge speaker groups while preserving saved results.
Voice samples and profiles remain local.

![Saved speaker profiles in the transcript workflow](docs/assets/screenshots/speakers.png)

## Visual summaries

Read the main points as a visual report: decisions, responsibilities, next steps,
quotes and relationships. Text summaries and the visual report stay with the
recording, alongside the original transcript and processing history.

![Visual summary of the fictional product-planning meeting](docs/assets/screenshots/visual-summary.png)

## PDF reports

Export a transcript, text summary, visual summary or complete report as **PDF or
TXT**. PDF export preserves the visual layout and uses saved results; exporting
does not start another AI job.

![Native PDF export options](docs/assets/screenshots/pdf-export.png)

[Open the fictional meeting's sample PDF](docs/assets/sample-report.pdf).

## Automatic sync and processing

Choose a sync interval and enable automatic summaries. While Vecta is open and
the recorder is available, new recordings can be downloaded, transcribed and
summarized locally without starting each job by hand. You choose the summary
formats and can pause or cancel processing.

Automatic sync runs **while the app is open**; Vecta is not a background service
that continues after you quit it.

## Recording permissions

Opening Conferences does not request Screen Recording or microphone access.
Recording permissions are checked when you choose Start; unattended conference
recording waits for existing permissions instead of prompting in the background.
An already authorized microphone is not requested again.

Build 79 uses a stable Apple Development signing identity rather than a different
ad-hoc code identity on each rebuild. Switching identities may require a one-time
new macOS grant. This does not override revoked permissions, OS reminders or
Gatekeeper, and is not Developer ID signing or notarization.

## Startup and background behavior

**Launch at login** is on by default. On the first normal launch, Vecta asks macOS
to register it as a login item; macOS may require approval. The setting shows
the current status and how to continue.

**Keep running in background** is also on by default. Closing the main window
keeps Vecta and its work open; reopen it from the Dock, Settings or the status
menu. Choose **Quit Vecta** or press **Command-Q** to terminate it. Turn the
setting off if closing the window should quit the app.

![Launch and background settings](docs/assets/screenshots/automation.png)

## Fast transcription

**Fast transcription** is on by default. While Vecta remains open—including
when its window is closed in background mode—it may retain roughly **700 MB** of
additional RAM so later work can start sooner. The first preparation can still
take time. Turn it off to use the earlier per-recording transcription mode.

## Summary formats

The **Formats** sidebar lets you create and edit custom text-summary
instructions, then select them for manual summaries, automatic processing and
Conferences. Deleting a custom format is permanent for that definition; saved
results and queued recipe snapshots that used it are retained.

![Custom summary formats](docs/assets/screenshots/library.png)

## Record on your Mac

Record system audio, a Mac microphone, both together, or a selected running
application for a conference. Recording is opt-in: choose **Start**, or explicitly
enable automatic conference recording in Settings. macOS requests the needed
microphone or system-audio permission for the selected source. The optional menu-bar control provides source selection and
Start/Stop without recording automatically.

## Your recording library

Keep recordings, transcripts and different summary versions together. Search the
library, listen to the original audio, ask the assistant about a recording, or
ask questions across saved transcripts.


## Requirements

- **Apple Silicon Mac, macOS 15 or later.** Intel and iOS/iPadOS are not supported.
- **8 GB unified memory for Qwen 4B; 16 GB for Qwen 9B.** Available memory and
  recording length still matter. The minimum is not a guarantee for every workload.
- Several GB of free disk space for models, recordings and processing files.
- Models are installed separately through an explicit user action.

Speech uses WhisperKit large-v3 Turbo and SpeakerKit. Summaries and assistant
features use MLX Qwen3.5 4B/9B. The interface is available in English and Russian;
new processing jobs retain their selected language policy.

## Install

Download the DMG from [Releases](https://github.com/olgvroe/Vecta/releases), open it,
and drag Vecta to Applications. Back up an existing library before replacement or
migration.

**Build 79 is a developer preview signed with Apple Development, not Developer ID,
and is not notarized.** Gatekeeper may
block it. Verify the release origin and checksums; if you choose to trust it, use
Apple's documented **Privacy & Security → Open Anyway** route. Do not disable
Gatekeeper or bypass a malware warning. See [installation instructions](docs/INSTALL.md).

A clean-user, downloaded-DMG first-launch test is not claimed for this preview.
[Verification status and limits](RELEASE_READINESS_REPORT.md) distinguish local,
GitHub CI, physical-device and clean-user checks.

## Device support

- **PLAUD NotePin S:** direct BLE and Fast Transfer accepted on an existing owner
  recorder/Mac setup, including MP3 import and previous-network restoration.
- **PLAUD Note, NotePin and Note Pro:** adapters are present; compatibility with
  every device and firmware is not claimed.
- **Local audio:** import recordings without a PLAUD account.

Vecta is independent software, not an official PLAUD product.

## Setup and network boundaries

Initial Partner provisioning sends authorization and device metadata to PLAUD
Partner endpoints. It does **not** upload recording audio, transcripts, summaries,
voice embeddings or documents. Credentials and cached device identities are kept
in the login Keychain; valid cached reconnection is local.

Model installation downloads pinned revisions from Hugging Face and verifies
file sizes and SHA-256. Inference workers are launched with a deny-network policy.
Fast Transfer uses the recorder's local Wi-Fi network and restores the previous
network afterward. It does not route audio through an Internet service.

The main app is not advertised as App-Sandbox-entitled. It uses macOS permissions,
filesystem access and bookmarks; local inference workers have a separate
network-denying sandbox policy. Read the [security policy](SECURITY.md) before
reporting a vulnerability. Never attach private recordings or credentials to a
public issue.

## Build and contribute

Install full Xcode 26.4+ with Swift 6.3+/Metal tools, Python 3.9+, Git, make and
curl. From the source root, using a new output directory:

```sh
python3 -I Tools/release.py build dist/Vecta-0.1.0 --version 0.1.0 --build 79
```

The command builds and checks the native app, workers, codecs, relink kit and DMG.
It does not install an app, download model weights, operate a recorder or publish
anything. No CMake, llama.cpp, PLAUD SDK or hosted backend is required.

See [BUILD](docs/BUILD.md), [CONTRIBUTING](CONTRIBUTING.md), [CHANGELOG](CHANGELOG.md)
and [source provenance](docs/PROVENANCE.md). Main branch: `main`; development:
`develop`. Preserve user data, historical schemas and third-party notices.

## License and origin

Vecta is licensed under [Apache-2.0](LICENSE). It retains adaptations from the
Apache-2.0 PinPoint baseline, with [NOTICE](NOTICE), provenance and import/rename
ledgers. It makes no clean-room claim.

Dependencies and model weights have separate licenses. Each distributed DMG
is accompanied by matching source, component notices and a working **LAME source/object/
relink kit**. See [dependency obligations](docs/DEPENDENCIES.md).
