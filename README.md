# Vecta

**Native macOS recording library with local transcription and AI.**

Vecta imports audio and downloads recordings from a selected PLAUD recorder using
its independent BLE / Wi-Fi Fast Transfer implementation. Playback, transcription,
speaker tools, text/visual summaries, recording assistant and questions across the
library run on your Mac. Audio, transcripts, summaries, voice embeddings and user
documents are not sent to cloud inference. There is no hosted-processing fallback.

**0.1.0 developer preview.** This is not an official PLAUD product, not a universal
consumer authorization service, and not a notarized app. Read the limits below and
[release verification / remaining gates](RELEASE_READINESS_REPORT.md).

## Features

- Native SwiftUI/AppKit recording library, search, playback and audio import.
- Independent Bluetooth transport, reconnection and local Wi-Fi Fast Transfer.
- WhisperKit large-v3 Turbo speech recognition and SpeakerKit diarization.
- Persistent speaker names, explicit voice confirmation and guarded speaker merge.
- MLX Qwen3.5 4B / 9B summaries, visual cards, recording assistant and library answers.
- Processing history, explicit model selection/download, cancellation and recovery.
- Text/PDF/audio exports, source-preserving migration, light/dark themes, English/Russian UI.

## System requirements

Full app: **Apple Silicon, macOS15+, at least 8 GB unified memory** (4B).
9B requires at least16 GB; available memory and other running apps still matter.
Intel, iPhone/iPad/Catalyst are unsupported. Model weights require separate disk
space and explicit installation. Audio processing supports recordings up to6 hours;
that policy and chunk/checkpoint tests are not evidence of a new6-hour end-to-end
inference acceptance test. Minimum-OS/clean-user acceptance is reported separately.

## Device coverage

| Family | Implementation | Physical evidence |
|---|---|---|
| PLAUD NotePin S | BLE and Fast Transfer adapters | Existing owner-accepted recorder/Mac setup: authenticated transfer, nonempty MP3 import and previous-network restoration |
| PLAUD Note / NotePin / Note Pro | Conservative native descriptors/adapters | No blanket hardware/firmware validation claimed |
| Local audio files | Import, playback/conversion/export | Automated fixtures; codec execution is separate from a hardware test |

The NotePin S result is retained acceptance of the documented setup, not a fresh
physical test of every release or a promise of all firmware/cancellation cases.
Hardware-dependent checks are not replaced with simulated CI success.

## Build from source — one command

Install full Xcode26.0+ (Swift6.2+/Metal tools), Python3.9+, Git, make and curl on
Apple Silicon macOS15+. Select full Xcode as the active toolchain. Then:

```sh
python3 -I Tools/release.py build dist/Vecta-0.1.0 --version 0.1.0 --build 64
```

Use a NEW output path. This builds and tests the native app, Speech and MLX workers,
packages a verified DMG, SHA256SUMS, matching source/LAME relink kit and notices.
It never uses an installed app as an input, installs Vecta, downloads model weights,
operates a device or publishes anything. **No CMake, llama.cpp or VectaQwen required.**
Source dependency downloads need Internet. See [build instructions](docs/BUILD.md)
for prerequisites, clean isolated builds, individual gates and development builds.

```sh
python3 -I Tools/release.py clean .build/clean-release --version 0.1.0 --build 64
python3 -I Tools/release.py check
```

## Installation

Open `Vecta-0.1.0-macOS-arm64.dmg`, drag Vecta to Applications, and eject the image.
The preview is **ad-hoc signed, not Developer ID signed or notarized**. Gatekeeper
may block it. Verify the release origin/checksum, then use only Apple's documented
Privacy & Security > Open Anyway route if you choose to trust it. Never disable
Gatekeeper or bypass malware warnings. Back up before replacing an existing app
or migrating a library. See [installation and first use](docs/INSTALL.md).

## Authorization and network/privacy boundaries

A first modern-device connection requires **your own authorized PLAUD Partner
credentials**. Vecta does not embed shared credentials or promise Partner account
access to every recorder owner. Guided enrollment is explicitly user-triggered.
Pairing/unbinding conditions in onboarding do not authorize destructive repair.

| Operation | Network / metadata | Local data boundary |
|---|---|---|
| Initial Partner provisioning | HTTPS to PLAUD Partner endpoints: client ID/secret, requested user identity/IDs for access tokens; RSA key provisioning and device serial/type for `gen-key` / `sn-sign` | No recording audio, transcript, summary, embeddings or document upload |
| Cached reconnect | Valid Keychain-cached device identity; local BLE signed handshake | Does not automatically refresh Partner credentials or fall back online |
| BLE import | Local selected-recorder link; recording inventory and file bytes | Writes verified local files; no cloud inference |
| Fast Transfer | Local recorder Wi-Fi, authenticated encrypted handshake/inventory/transfer | Temporarily changes Wi-Fi; restores prior network or disconnects recorder AP; no Internet inference |
| Model install | User-triggered HTTPS downloads from pinned Hugging Face model revisions | Size/SHA256 verified; no user recording content sent |
| Transcription, diarization, all AI modes | Local worker processes launched with deny-network policy | No cloud fallback; outputs and voice profiles remain local |
| Viewing/history/playback/export | Local filesystem and user-selected export destinations | Export shares data only where the user explicitly chooses |

New credentials/device identities are stored in the login Keychain. Temporary
access tokens are kept in memory. Compatibility credential reading is isolated
for inherited installations; it does not start the old backend. Developers may
use `bash Tools/configure-auth.sh` to enter their own credentials interactively;
the secret is hidden and must never be pasted into issues or committed.

Location permission for Fast Transfer is used to identify/restore the Wi-Fi
network; coordinates are not requested or transmitted. App Sandbox entitlement
is not claimed: the native app uses macOS permissions and filesystem/bookmark
boundaries, while inference workers have a separate deny-network sandbox policy.
No application-update service is implemented/advertised by this release pipeline.

## Architecture and models

SwiftUI/AppKit → local recording store / analysis mailbox → serial resource-gated
workers. Speech uses pinned WhisperKit and SpeakerKit with Core ML resources;
text/visual/assistant/library modes use **MLX only**, with packaged Metal resources.
Native C audio codecs (Opus/Ogg/Vorbis/LAME) are statically linked. The independent
transport is in Packages/VectaTransport; no PLAUD SDK/iOS target or hosted backend.

Production model registry: Whisper, SpeakerKit, Whisper tokenizer, MLX Qwen4B and
MLX Qwen9B. Model files are separately user-installed, pinned by revision/size/hash,
and have their own licenses. Qwen2B/GGUF and experimental retired identifiers remain
Codable solely for history. Unfinished old requests are preserved with an explicit
unavailable-backend explanation. Choose4B/9B and create a NEW summary version;
models are not silently substituted and archived weights are not automatically deleted.

## Development / release process

Main branch: `main`; development: `develop`. Read [CONTRIBUTING](CONTRIBUTING.md),
[security policy](SECURITY.md), [code of conduct](CODE_OF_CONDUCT.md) and
[CHANGELOG](CHANGELOG.md). CI separates fast model-free regression from full ARM64
build/package checks. Tags/manual runs prepare a release kit; public publication
requires the owner's separate explicit action/approval. No large models in PR CI.
Establish a verified private reporting contact before public launch; when the repository becomes public, enable and test GitHub Private Vulnerability Reporting before announcing the launch. See SECURITY.md.

Known limits: Partner credential availability, hardware/firmware coverage, clean-user
Gatekeeper/permission acceptance, minimum-OS testing, long-recording inference and
quality across arbitrary languages remain distinct acceptance gates. Existing
synthetic/fixture checks are not substitutes for those outcomes.

## Origin and licenses

The existing main-project license is [Apache-2.0](LICENSE); it has not been changed.
Vecta retains adaptations from the Apache-2.0 PinPoint baseline, with [NOTICE](NOTICE),
[provenance](docs/PROVENANCE.md) and import/rename ledgers. Historical branding and
serialization aliases remain where legally or technically required. No clean-room
claim is made. PLAUD is a third-party platform/device name, not an endorsement.

See [dependencies and license obligations](docs/DEPENDENCIES.md). MLX and Argmax
frameworks have separate notices; SpeakerKit weight attribution is retained. Every
DMG must travel with matching source, license artifacts and a working **LAME3.100
source/object/relink kit**, not just copied COPYING. Technical checks are evidence,
not a legal guarantee or a full independent authorship/CVE audit.
