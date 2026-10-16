# Install Vecta on macOS

Developer preview for Apple Silicon, macOS 15 or later. Intel/iOS are unsupported.
Models are not inside the DMG: install the models you need explicitly in Settings.
Qwen4B requires at least 8 GB unified memory; Qwen9B at least 16 GB. Keep free disk
space for recordings, model downloads and temporary processing.

## Developer-preview distribution — important

Build 76 is signed with an Apple Development certificate for a stable local
identity. It is NOT Developer ID signed and NOT notarized by Apple. Earlier
preview builds were ad-hoc signed; ordinary source/CI builds still default to
ad-hoc unless a signing identity is explicitly supplied. A valid development
signature does not establish Gatekeeper acceptance. Only proceed if you
independently trust the source and release origin.

1. Obtain the DMG and SHA256SUMS from the same owner-authorized release. Compare
   the downloaded file with `shasum -a 256 Vecta-0.1.0-build76-macOS-arm64.dmg`.
2. Open the DMG in Finder. Drag Vecta.app to Applications. If Vecta already exists,
   quit it and back up the app/library before explicitly choosing replacement.
3. Open Vecta in Applications. macOS may refuse an unidentified/unnotarized app.
   After attempting to open it, go to System Settings > Privacy & Security and,
   only after checking the source, use the available **Open Anyway** action and
   confirm **Open**. Administrative approval may be required. Wording differs
   by macOS version; a managed Mac may prohibit this. A backup protects your
   library; it does not make this Gatekeeper decision or bypass any warning.
4. If macOS reports malware, a revoked app or unexpected damage, stop. Re-download
   from a verified source and report privately; do not bypass that warning.
5. Eject the mounted DMG after copying. The app should run from Applications.

Do not disable Gatekeeper, remove quarantine to suppress warnings, or change
system-wide security policies. Official Apple guidance:
https://support.apple.com/guide/mac-help/open-a-mac-app-from-an-unknown-developer-mh40616/mac
and https://support.apple.com/102445.

The available automated checks verify mount/detach, bundle hashes/signatures and
a copy into a temporary Applications directory. They do NOT prove downloaded,
quarantined first-launch acceptance on a clean user profile. That remains a
separate owner acceptance check; do not treat local unquarantined launch as it.

## First use

Back up an existing library before replacing the app or starting a migration.
Keep that backup separate from the DMG; it does not replace source verification
or macOS's security decision.

### Recording permissions after updating

Opening Conferences no longer requests screen or microphone access. Manual Start
checks the selected source; background automatic recording waits for already
granted permissions. macOS may ask once when moving from the old ad-hoc identity
to build 76's stable Apple Development identity. Allow access using macOS controls
if you want that capture source; do not reset TCC or disable security protections.
This is not Developer ID signing/notarization and does not suppress OS revocation
or periodic permission reminders.

### Startup and background settings

On the first normal launch, **Launch at login** is enabled by default and Vecta
asks macOS to register it once. macOS may require approval or report that login
items are managed. Follow the status and recovery instructions shown in Settings;
do not change Gatekeeper settings to address a login-item approval.

**Keep running in background** is enabled by default. Closing Vecta's main window
keeps the app and any current work open; reopen it from the Dock, Settings or the
status menu. **Command-Q** or **Quit Vecta** explicitly terminates the app. If
you turn background operation off, closing the window quits Vecta instead.

Fast transcription is enabled by default and may use approximately 700 MB more
RAM while Vecta stays open, including in background mode. Its first preparation
can still be slow. Turn it off to return to the earlier per-recording mode.

### Device, model and recording setup

- Local audio import and viewing stored results do not require PLAUD credentials.
- For a modern PLAUD's first authorization, use your own authorized PLAUD Partner
  account/credentials. They are not bundled or guaranteed available to everyone.
  Device enrollment is explicit; do not reset/unbind/delete recordings to repair
  a connection. Follow the app's pairing-mode/onboarding guidance.
- Valid cached identity reconnect is local BLE; it does not automatically refresh
  Partner authorization online. See the README's setup and network boundaries.
- Allow Bluetooth when needed. Fast transfer may require Location permission to
  identify/restore the Wi-Fi network, and local-network access. No coordinates
  are requested or uploaded. Device Wi-Fi temporarily interrupts Internet access.
- For manual Mac recording, select a source and explicitly choose **Start**.
  Automatic conference recording requires a separate explicit opt-in in Settings;
  enabling login startup or background operation does not enable it.
  Allow the microphone or system-audio permission requested by macOS for that
  source. The optional menu-bar control can start and stop an explicitly selected
  recording; it does not start recording on launch.
- Install Speech and either MLX4B/9B only when you explicitly choose Install. Network
  is used to download authenticated model files; inference stays on this Mac.

## Historical libraries

Back up before your first migration. Source libraries/results are retained and
verified copies are used; ambiguous ownership requires folder selection. Older
Qwen model identifiers remain readable. Unfinished legacy Qwen tasks preserve
the original request, transcript/checkpoints/results and explain that the retired
backend cannot run. Select MLX4B or MLX9B explicitly and create a NEW summary
version. The app does not silently substitute models or delete archived weights.
