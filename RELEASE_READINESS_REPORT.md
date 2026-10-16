# Vecta 0.1.0 developer-preview verification

## Build78 portable model-free validation

The shipped application code is unchanged from77. The library-search fixture now respects the existing8/16GiB host admission rules instead of unconditionally expecting4B/9B acquisition on a7GB standard hosted runner. It logs actual physical memory, asserts rejection for incompatible models, and always verifies both synthetic model directories and corrupt/missing-file rejection. Successful host/stale-status paths remain tested on compatible hardware, with explicit coverage limits on low-memory machines. No production memory policy, permission check or CI gate is removed.

All20 revised native executable regressions passed locally on synthetic data. Package, protected installation and public availability are separate evidence: consult the matching release notes/artifact-verification.json and [required hosted checks](https://github.com/olgvroe/Vecta/pull/1/checks). Source or local fixture success alone is not a public-release or installation claim. Build77 hosted packaging compiled both apps but failed on the old fixture; builds76/77 remained unpublished. The prior build77 installation evidence below is historical, not a claim that changed test sources match its frozen build snapshot.


## Build79 recording-safety correction — 16 October 2026

Build79 supersedes build78 for future distribution. It corrects a reviewed recording
failure mode: when a real-time `AVAssetWriterInput` briefly reports that it is not
ready for more media data, Vecta drops that individual sample rather than treating
the temporary backpressure as a fatal encoding error and stopping the recording.
A failed append while ready remains fatal. It also restores the UI control to create
or retry an optional visual summary from an existing saved text summary; the retry
preserves the saved transcript/text and runs only that optional stage.

Fresh full nondevelopment build79 passed the public-source/security gates, 92 core,
121 UI-state,100 speaker,71 native-runtime,73 prompt-language,123 legacy,18 download
and Mac-recording policy checks; 20 actual compiled native executable regressions,
63 Speech configuration,18 model-free MLX and163 transport tests passed. Package
verification passed source/link identity, worker missing-input rejection, actual
LAME relinking, 41 packaged resource and36 relink-kit hashes, Apple Development
signature, DMG verification/read-only mount/Finder layout/mounted identity and
temporary Applications-copy integrity. No model weights were downloaded and no
owner data, recording, device or real inference operation was exercised.

The build is signed by Apple Development team `X5L2952RH6`, not Developer ID or
notarized. Its DMG SHA256 is
`f1fc9b1dea8114b356a89514812b7e0ac3237f8be34902843b68286f2bfeb70b`.
Same-user protected installation passed after a fresh nine-root backup; installed
build79 executable SHA256 is
`170dba2f0a8015f08770b1da559e46363d13228745c8a476a3cba803a1e46809`.
Build78 is the sole local rollback. The app was not launched during replacement.

**Build79 is not public yet.** Public `main` now identifies its exact reviewed
source commit `5f9bd14d2242b7782df1af39207a32e0dfc234c3`; hosted macOS run
`38902858240` is in progress. Tag `v0.1.0-build78` remains the earlier source and
no build78/79 release assets have been uploaded. Before public distribution, the
matching hosted checks must pass, then create a build79 tag and upload the matching
DMG, source, licenses, LAME relink kit, SHA256SUMS, release notes and
artifact-verification report. Clean-user Gatekeeper, Developer ID/notarization,
physical-device, real-inference and minimum-OS acceptance remain unresolved.


## Build77 compiler-compatibility correction — 16 October 2026

Build77 is installed after a fresh verified backup and atomic replacement; executable SHA256 `83eb930a7472b6645c51cbc91c102b754e2a419ee56f7342e96560b6f6941961`. Candidate/installed/rollback inventories, strict/deep signatures, all protected data/model/settings and backup bytes/modes match. The app was not launched by installation. Build76 is retained for rollback.

Build76 was not published: hosted Swift6.3.1 failed twice to type-check the model-download confirmation expression, although local Swift6.4 compiled it. Build77 decomposes that same confirmation message into intermediate strings and an explicitly typed Int64 total, outside the SwiftUI expression. Consent, wording, capture, permissions and data behavior are unchanged. No compiler check or security gate was removed.

Build77 full local source checks, 20 compiled native regressions, 31 isolated settings assertions, 163 transport tests, compiled Speech configuration/protocol checks and 18 model-free MLX tests passed. Exact source/link/resource/signature verification and actual LAME relinking passed, with41 resource/36 kit hashes. DMG verification, read-only mount/detach, Finder layout, bundle identity and temporary Applications-copy integrity passed. DMG SHA256 `a9035e6a883a5c095b60830041c318cb2a3b6cc90fc7addc0b69b2bdefb98304`.

Hosted verification is tracked in the [release pull request checks](https://github.com/olgvroe/Vecta/pull/1/checks), independently of these local results; public publication requires all mandatory checks to succeed. Public availability is recorded on the [Releases page](https://github.com/olgvroe/Vecta/releases). The unpublished76 draft is not a public release, and existing public65/tag/assets remain unchanged. The six refreshed English screenshots use genuine native views with fictional fixtures, not owner content or inference benchmarks.

Apple Development team X5L2952RH6 is verified, not Developer ID/notarization. Clean-user/quarantined first launch, minimum-OS acceptance, actual TCC persistence, reboot/login, real inference and physical-device coverage remain separate/unresolved. No owner data inspection, capture, model download or device operation was performed during packaging or installation.

## Corrected permission-flow build76 — 16 October 2026

Owner-authorized full0.1.0/build76 is installed; executable SHA256 `f09f8a8e829984fb05099cb944ab9de10566bee33f47e594c92fc5b0ebb02758`. Conferences entry no longer requests Screen Recording/microphone/notification access. Already authorized microphones are reused; denied/restricted states are not re-requested. Automatic recording waits for current permissions instead of requesting from a background timer. No permission-state Boolean, TCC reset, or bypass is used. All75 settings/Formats/local-only features remain included.

The installed app and workers use the owner-selected Apple Development identity. The app has a certificate-based designated requirement, verified against two distinct signed test binaries, rather than an ad-hoc code-hash requirement. It is NOT Developer ID signed/notarized; a first grant after changing identity may be necessary, and actual TCC persistence/revocation/OS reminders are not overridden or established by this test.

Source/permission/settings checks,163 transport tests,20 compiled native regressions,63 Speech configuration checks,12 raw/packaged protocol checks and18 model-free MLX tests passed. Exact source/link/codec/resources/runtime/privacy/signature and actual LAME relinking passed (41 resources/36 kit files). A host rebuild after correcting obsolete native-test references reused only the freshly compiled workers whose source/build inputs, binary hashes and pinned dependencies were reverified unchanged; no failed host artifact was accepted. Independent clean-source/user/minimum-OS, real capture/inference and physical-device acceptance remain separate.

Fresh verified backup protected atomic replacement; installed/candidate/rollback signatures/inventories and protected data/model/settings/backup bytes+modes passed after cleanup. Only rollback75 remains; generated app/compiler copies removed, matching kits/caches/backups/evidence retained. No production launch, capture, model download or device operation was performed during installation. The owner's fix→install prerequisite is complete. The release source and screenshots use a separately reviewed public export; publication evidence is distinct from installation/package evidence. Previous public65/tag/assets remain unchanged.

## Build76 release-package verification

The distribution DMG contains the exact installed build76 executable. DMG checksum verification, read-only mount/detach, Finder layout, mounted bundle identity and a temporary Applications-copy signature/inventory comparison passed. DMG SHA256: `c8090c0a4fb99e64a9ef170d8409fb25d865762d677ca422a8af507a6b35cba0`. This copy test is not a clean-user/quarantined-DMG first launch. The source and matching LAME relink kit bind all compiled inputs to build76; presentation-only docs/images may be refreshed without replacing the signed executable. Release checksums cover all six companion files, excluding the checksum list itself.

## Historical corrected permission-flow build76 preparation — 16 October 2026

Publication is held until the corrected build is verified and installed. Conferences page entry no longer requests Screen Recording, microphone or notification access. An authorized microphone is reused without requesting again; denied/restricted access is not re-requested. Unattended conference capture checks current required grants non-interactively and falls back to a manual suggestion instead of prompting from the background. No permission grant is inferred from a saved Boolean or repaired by resetting TCC.

The owner selected a stable Apple Development signing identity for local builds/public distribution. Two distinct harmless binaries have valid signatures and identical certificate-based designated requirements, unlike the prior ad-hoc code-hash identity. This does not establish actual TCC grant persistence or Developer ID/notarization; moving identities may need a one-time OS grant, and revocation/OS reminders remain effective. Release tooling now reports the actual signature category/team/requirement rather than assuming ad-hoc signing.

Current source/permission logic and163 transport checks passed. All20 compiled native checks passed; no actual capture/owner-data access was performed. Full production/package/DMG and remote gates remain pending. The installed app remains75 until protected replacement; release65 is unchanged and no75/76 publication has occurred.

## Historical local login/background settings build75 — 16 October 2026

Owner-authorized full nondevelopment0.1.0/build75 is installed, retaining fast transcription and permanent format deletion. Settings adds default-on Launch at login through SMAppService.mainApp and default-on background operation. First normal launch attempts registration once; subsequent launches respect login items disabled in macOS. System approval/error/notFound states are shown accurately with localized recovery instructions. No login registration is performed by tests or installation; actual owner registration, approval and logout/login behavior remain untested until first normal use.

Closing the main window keeps existing work alive when background mode is on; off uses the existing safe termination lifecycle. The same retained window reopens from Dock, status menu and Settings; Quit/CmdQ remain explicit termination actions. Source checks,28 fake-login settings assertions plus3 verification-isolation assertions,163 transport tests and20 compiled native regressions passed. Separate synthetic deny-network SIGTERM-to-normal-delegate termination exited cleanly. Native coverage verifies repeated window close/reopen and the background-off termination policy, not every off-close/CmdQ event route end-to-end. Fresh compiled Speech63, raw/packaged protocol12 and model-free MLX18 tests passed.

Full source/link/codec/resource/runtime/privacy/signature checks and actual LAME relinking passed, including41 resource and36 kit hashes. Executable SHA256 `1600da296c4cadcf6fbdab1bc625bd0d4e4126c80d50ebe10bdb5e6fe1398b06`. Fresh verified backup protected atomic installation; exact installed/candidate/rollback inventories and protected data/model/settings/backup hashes passed after installation and cleanup. Only rollback74 remains; generated app copies/redundant compiler products were removed while preserving matching kits, source caches, backups and evidence. Production app was not launched; no owner audio inspection, inference, model download, recording, device operation or publication. Real-owner/physical-device/clean-user/minimum-OS/DeveloperID/notarization gates remain separate. Published65 unchanged.

## Historical local permanent-format-deletion build74 — 16 October 2026

Owner-authorized full nondevelopment0.1.0/build74 is installed, retaining build73 fast transcription and custom Formats. Deleted formats UI and restoration APIs are removed. Newly deleted custom definitions are physically removed from the catalog; saved summaries and queued/request/result snapshots are preserved. Inherited version1 tombstones remain readable and hidden without automatic purging. Recording Trash is unchanged.

Fresh current-source checks,163 transport tests,19 compiled native regressions,63 Speech configuration checks,12 raw/packaged Speech protocol checks and18 model-free MLX tests passed. Native coverage includes deletion after reopen, stale-editor rejection, immutable snapshots, bounded catalog growth and builtin protection. Full source/link/resource/runtime/privacy/signature checks and actual LAME relinking passed, including41 resource and36 relink-kit hashes.

Fresh verified backup protected atomic installation; exact installed/candidate/rollback inventories and protected data/model/settings/backup hashes passed after installation and cleanup. Installed executable SHA256: `a6815eb10e1b35e560cce89159ea46f413636e2b0022c967079a902490ec068e`. Only rollback73 remains; redundant generated app copies were removed, with backups, source caches, matching relink kits and evidence retained. No production launch, owner audio inspection, real inference, model download, recording, device operation or publication. This same-user update does not satisfy physical-device, real-owner quality, clean-user/minimum-OS, DeveloperID or notarization gates. Published65 is unchanged.

## Historical local fast-transcription and custom-formats build73 — 16 October 2026

The owner-authorized full nondevelopment0.1.0/build73 is installed. It includes the previously uninstalled custom-formats72 feature: dedicated Formats sidebar screen, revisioned user text instructions, immutable queued recipe snapshots and manual/Settings/Conferences selection. Adds a default-enabled Fast transcription checkbox; disabling preserves the existing one-shot Speech worker path. Enabled mode retains an unloaded two-policy WhisperKit/process cache while Vecta is open, with heavy-AI lease ownership during warm/processing, unload-before-diarization/MLX, bounded background preparation and safe cancellation/shutdown. Only already-installed verified models are prepared; the setting never downloads models. The helper describes approximately700MB additional memory and explicitly notes initial preparation still takes time; this is not a universal hard memory cap.

Fresh load/unload-only, deny-network tests on the existing pinned weights measured157.430seconds for a cold default encoder load,0.961seconds repeated in the same process; first GPU-policy load in that process4.109seconds, repeated0.681seconds; default-policy reload after GPU0.895seconds. Observed idle process RSS after unload245–284MiB. These are model-loading/cache measurements with no audio/inference, not end-to-end transcription throughput, peak-memory or representative quality acceptance.

Current-source gates passed, including new isolated preference/framed-worker/cancellation checks,66 packaging tests,92 core/121 UI assertions,100 speaker,71 runtime,73 prompt,123 legacy checks and localization/audio/downloader guards. Transport163 and compiled model-free MLX18 passed with zero failures; compiled Speech configuration63 and raw/packaged Speech protocol12 passed. Final19 compiled native executable regressions passed, including49 export and635 composition/PDF checks. Two earlier keyboard-fixture runs trapped during concurrent builds; subsequent diagnostic and complete uninstrumented rerun passed with unchanged source/binary. The exact readiness/focus/timing cause is unproven; intermittent GUI-fixture robustness remains a verification limitation, not a claimed production fix.

Full production source/link/codec/resource binding,41 worker-resource and36 relink-kit hashes, portable runtime, deny-network missing-input rejection, strict/deep ad-hoc signatures and actual LAME relinking passed. A fresh complete verified private backup protected atomic replacement; installed/candidate inventories and the sole rollback71 match, with all protected data/models/settings and backup hashes unchanged after installation and cleanup. Superseded/staging app copies and redundant compiler/helper products were removed while retaining matching71/73 source/relink kits and evidence. No production launch, owner-audio inspection, real inference, model download, capture/device operation, DMG or public release was performed. This is a protected same-user update, not clean-user/minimum-OS, physical-hardware, DeveloperID or notarization acceptance. Published65 assets remain unchanged.

## Published result — 15 October 2026

[Vecta 0.1.0 developer preview, build 65](https://github.com/olgvroe/Vecta/releases/tag/v0.1.0)
is public. The tag and all binary/source/relink assets bind to commit
`6bb777beaf9535fb769221e479328a421c6939d2`, not later documentation-only updates.

- [Independent CI 38648615369](https://github.com/olgvroe/Vecta/actions/runs/38648615369):
  all three source/security, model-free Mac and full ARM64 package gates **PASS**.
- [Clean release preparation 38648614542](https://github.com/olgvroe/Vecta/actions/runs/38648614542):
  **PASS**, including 66 packaging tests, 13 native executable regressions,
  55 Speech configuration checks, 153 transport tests, 18 MLX tests,
  production source/bundle binding, actual LAME relinking and DMG mount/copy checks.
- Downloaded kit hashes independently checked; all 234 archived source files
  match the release commit byte-for-byte. Local DMG integrity, read-only mount,
  build 65/arm64 identity and deep/strict signature checks **PASS**; no launch/install.
- DMG SHA-256: `920befcfc88f180e42458b7254428227c5d56e86d69a670cf5207b5da88c7d8b`.
- Seven release assets: DMG, matching source, LAME relink kit, component licenses,
  SHA256SUMS, build release notes and artifact-verification.json. The latter's
  `published: false` records its preparation-time state, not current visibility.
- GitHub Private Vulnerability Reporting enabled; the anonymous security page
  shows **Report a vulnerability** and the form route returns HTTP 200/sign-in.
  No test vulnerability report was submitted.
- Main/develop require the three CI checks with strict updates; force-push and
  deletion disabled. Version-tag update/deletion rules active. Release preparation
  requires owner review and is restricted to main/v* refs. Owner/admin bypass and
  self-review remain enabled for this single-maintainer repository; independent
  reviewer approval is not claimed. Issues/Discussions are disabled.

The preparation chronology below records earlier failures and fixes. Statements
that a hosted rerun or release is pending describe those earlier source snapshots;
the completed evidence above supersedes them. Installation, signing and hardware
limits in **Not claimed** remain unchanged.

## Local repair candidate 66 — 15 October 2026

The owner requested a local replacement, not a new public release. Candidate 66
adds bounded recovery of isolated invalid recorder Opus packets, native Mac
system/microphone recording, Conferences preferences and Mac-only permanent Trash
deletion. PLAUD originals are not deleted. Automatic recording defaults off;
application audio activity is only a heuristic, not a participant-count API.
Unknown participant count requires confirmation when the participants-only option
is enabled; unavailable activity information pauses automation.

Current source gates passed, including 156 transport/audio tests, 14 compiled
native-app regressions, 71 isolated runtime checks and synthetic audio-track
mixing. No real microphone/system capture, physical recorder re-download, real
model inference, third-party conference acceptance or clean-user installation has
been performed for this candidate. Full production assembly, source/bundle
binding, both packaged worker startup checks, deep/strict ad-hoc signature checks
and actual LAME relinking passed. The owner-authorized local installation replaced
build 64 atomically with build 66; installed bundle hashes match the verified
candidate, the single rollback matches the prior installed app, and local user
state remained byte-for-byte unchanged during replacement. The compiled Speech
configuration suite passed 55 checks; compiled model-free MLX tests passed all
18 cases. Generated app/worker/test build trees were removed after retaining
verification logs and manifests; only the installed app and one rollback app
are retained.
This local work does not update the published build 65 assets or establish
notarization/Developer ID signing.

## Local UX revision 67 — 15 October 2026

The owner requested a white menu-bar recording popover with a source selector,
red REC/frame/timer state, and a gear opening Conferences; no blue keyboard-focus
halos on app controls; Space playback/pause and arrow-key phrase navigation in
recording detail. Existing playback/seek and AI-generated-title storage paths
are reused. Local event handling excludes text editing, modified shortcuts,
other windows and modal sheets. Actual posted-key tests passed on a generated
silent fixture, not owner audio.

Adds microphone + selected running application using an inclusion-only
ScreenCaptureKit filter. Missing/closed targets fail rather than falling back
to system-wide audio. Per-browser-tab isolation is **not implemented**; the owner
explicitly selected application-only scope. Choosing a browser includes its tabs.
No real application-audio isolation capture has been performed.

Opening Conferences prepares microphone, screen/system-audio and applicable
notification permissions without starting recording. Verification fixtures skip
permission requests. New preference defaults enable automation with confirmation
and participant checks, transcription, text and visual summaries; saved explicit
choices remain preserved. The owner retracted the two-minute-silence suggestion;
existing 45-second audio-I/O inactivity auto-stop remains unchanged.

Global library answers and the recording assistant use the same selected 4B/9B
model as processing, without an additional answer model or automatic download.
Answer admission now verifies/acquires that exact model through the existing
manager rather than rejecting a stale UI status. Missing/corrupt model files
remain rejected; there is no silent model switch or speech-model prerequisite.
Hybrid retrieval adds Russian case-ending prefix matching and е/ё normalization,
keeps original source text/timestamps, and applies visibility before the lexical
candidate limit. Unavailable optional system embeddings do not disable lexical
retrieval. Index revisions rebuild derived search data, not recordings/results.

Current source/synthetic gates, 156 transport tests and all 16 native executable
regressions passed, including inflected participant/topic questions, 90 invisible
decoys, English, source navigation metadata, budgets, deletion, stale model status
and corruption rejection on tiny synthetic files. Current native library-answer
UI, fitted white popover, Conferences navigation and clearing an answer were
visually/interaction checked on synthetic data without capture or inference.

Full production assembly, source/link binding, all 41 packaged worker resource
hashes, 36 relink-kit hashes, deny-network worker startup rejection, actual LAME
relink and deep/strict ad-hoc signatures passed. Compiled Speech checks passed 55;
compiled model-free MLX tests passed 18. The authorized local installation replaced
build 66 atomically with build 67; the installed inventory matches the verified
candidate, protected user-state hashes remained unchanged, and the single rollback
is now build 66. Private pre-install backups and evidence were retained; generated
app/worker/test trees and the redundant historical build64 DMG were removed.

Real model answers on the owner's library have not been tested. The active model
status snapshot reports unavailable model files in the standard install locations;
this work does not establish their presence or infer a need for a separate search
model. No model download was authorized or started. Real capture/application-audio
isolation, physical-device acceptance and clean-user first launch remain untested.
This is local owner work, not a new publication or notarized release.

## Local visual-summary revision 70 — 15 October 2026

Owner-authorized local installation replaced build69 with a fresh full production,
nondevelopment build70. The presentation uses a fixed1200×840 canvas, seven
composition families, the existing128-symbol catalog and shared app/PDF rendering;
historical schemas and full saved content remain preserved.

Fresh source gates passed, including66 packaging,92 core,121 UI,163 transport,
19 compiled native regressions (49 export/snapshot and535 composition checks),
55 compiled Speech configuration and18 model-free MLX tests. Production verification
passed current source/link/codec binding,41 packaged resource hashes,36 retained
relink-kit hashes, both deny-network worker missing-input rejection checks,
actual LAME relinking and deep/strict ad-hoc signatures.

A new complete private SHA256-verified state backup was created and reverified.
The atomic replacement's installed inventory exactly matches the verified candidate;
protected data/models remain byte-identical and rollback69 exactly matches the prior
installation. The app was already closed and remains closed to avoid automatic
synchronization/processing. No production launch, real inference, capture, device
operation, model download or publication occurred.

**Cleanup remains blocked by a permission denial.** No deletion was executed or
retried: superseded rollback68, the candidate and four frontend development bundles
remain alongside installed70 and rollback69. The one-rollback cleanup requirement
is not yet satisfied. Matching source/link/codec manifests, relink kit and private
evidence remain retained. Physical-device acceptance, real inference/owner-library
UI, clean-user installation, minimum-OS hardware acceptance, Developer ID signing
and notarization remain separate unresolved gates. No DMG/public release was made.

## Custom text formats — source work in progress, 15 October 2026

The owner approved a sidebar Formats catalog, user-authored instructions and custom-format selection for manual summaries, automatic Settings and Conferences. Settings and Conferences share the existing automatic-format default; conference capture/visual options remain independent of post-sync automation. Existing format/template storage and historical request schemas are retained. New queued jobs will snapshot selected recipe contents to isolate waiting work from later catalog edits/deletions. Implementation and verification are pending; no new build installation, production launch, model inference/download, capture, device action or publication has occurred for this feature. Real custom-prompt adherence and long-input fidelity require separate inference acceptance.

## Distribution scope

The maintainer authorized a public developer preview, including the source
repository and matching DMG/source/LAME-relink/license kit. This is **ad-hoc
signed, not Developer ID signed and not notarized**. It is not a claim of
production readiness or independent clean-user Gatekeeper acceptance.

The source export uses an explicit file allowlist. Internal journals, private
installation evidence, owner recordings, credentials and model weights are
excluded. Public screenshots and the sample PDF are isolated fictional meeting
fixtures rendered by the native development app, not inference-quality evidence.
The development fixture is excluded from production binaries.

## Evidence available before build 65

- Clean public-source build 64 and its local DMG verification passed. That evidence
  is historical, not the binary binding for this changed source revision. Matching
  source/relink/license archives remain retained; the redundant local build64 DMG
  was removed after verified build67 installation under the one-rollback policy.
- Local source/security, packaging, core storage/migration, speaker identity,
  native runtime, localization, prompt-language, local-AI IPC and legacy checks
  passed in the preceding release audit. Re-run the current revision before
  distributing build 65; old passes are not a substitute for its own checks.
- The installed build 64 was replaced with protected backups and independent
  data/hash verification. The owner subsequently reported working local processing
  after freeing disk space. Publication work does not operate that installed app
  or inspect/process owner recordings.
- BLE and Wi-Fi Fast Transfer were accepted on an existing owner NotePin S/Mac
  setup. This does not establish all recorder/firmware compatibility.
- Local synthetic executable UI checks were performed on actual development
  binaries, without production library access, model inference or device actions.

## Hosted checks and build 65

Initial GitHub Actions run [38639331882](https://github.com/olgvroe/Vecta/actions/runs/38639331882)
passed source/security/workflow checks but failed model-free Swift 6.2 compilation
on a large numeric expression. The full build was skipped. The expression is now
split into typed intermediate values; exact reservation parity and 8/16 GB model
policy regressions were added. Local core/UI-state checks passed after that fix.

The next run [38644518982](https://github.com/olgvroe/Vecta/actions/runs/38644518982)
passed source/security and the source-level Mac checks, then hit a second Swift 6.2
expression limit in the transport test fixture builder. Its byte concatenation
has been split into appends without changing the fixture. All 153 transport tests
pass locally. Release preparation [38644698458](https://github.com/olgvroe/Vecta/actions/runs/38644698458)
failed because Go was absent on the macOS runner; a SHA-pinned setup-go step now
installs the compiler for the pinned secret scanner. Neither failed run produced
a releasable kit. Current local automated checks pass; hosted retries are pending.

Further hosted checks exposed two build-environment assumptions. Run
[38645146251](https://github.com/olgvroe/Vecta/actions/runs/38645146251) hit libogg's
default maintainer-mode regeneration, which depended on an unavailable Automake.
All four codec configure calls now explicitly disable maintainer mode, using the
SHA-verified release tarballs' generated build files. A fresh local codec build
and integrity seal passed. Run [38645146429](https://github.com/olgvroe/Vecta/actions/runs/38645146429)
reached MLX resolution but its pinned mlx-swift requires Swift 6.3, not 6.2.
Production CI/preparation now use macos-26 with Xcode 26.4.1; macOS 15 remains the
application deployment target and model-free runner. Dependency revisions were
not changed. Hosted retries remain required.

Runs [38646079756](https://github.com/olgvroe/Vecta/actions/runs/38646079756) and
[38646081179](https://github.com/olgvroe/Vecta/actions/runs/38646081179) compiled
Speech, MLX and the native app; source/security, model-free tests and all 13 native
executable regressions passed. The subsequent Speech configuration test launcher
assumed Xcode's flat module/object layout instead of SwiftPM's Modules/target.build
layout and stopped both pipelines. It now supports both exact layouts and rejects
missing modules or empty object sets before compilation. Three synthetic launcher
regressions and all 66 packaging checks pass. A fresh pinned local Speech build
and actual 55 model-free Speech configuration checks pass with the corrected
launcher. This fixes verification tooling; it does not change inference behavior.
A final current-source hosted pass and complete DMG kit are still pending.

**Build 65 publication requires a successful current-source hosted rerun and a
matching verified production kit.** Check the commit/tag's Actions runs and the
release's artifact-verification report for completed gates. This source report
records preparation evidence, not a future pass. Release preparation itself never
publishes a public Release; artifact upload is explicitly opted into.

## Not claimed

| Gate | Status / limit |
| --- | --- |
| Downloaded, quarantined DMG first launch on a clean user/Mac | NOT TESTED |
| Developer ID signature / Apple notarization | NOT AVAILABLE |
| macOS 15 minimum-OS hardware acceptance | NOT independently tested |
| 8 GB hardware workload/quality benchmark | NOT performed; 4B minimum-memory policy tested |
| 9B on 8 GB | Unsupported; minimum is 16 GB unified memory |
| Every recorder/firmware | NOT tested |
| Long-recording/model-quality benchmark on owner audio during publication | NOT performed |
| Formal no-secret proof / legal certification / complete CVE audit | NOT claimed |

## Privacy and licensing

Inference is local-only and workers use a deny-network policy. Initial authorized
Partner provisioning exchanges credentials/device authorization metadata, not
recording content. User-triggered model installation uses the Internet. BLE and
recorder Wi-Fi are direct local transport. The main app is not claimed to carry
an App Sandbox entitlement. Automatic synchronization runs while Vecta is open.

Apache-2.0 LICENSE, NOTICE, source provenance and import/rename ledgers are retained.
No clean-room claim is made. Static LAME distribution requires the matching
source/object/relink kit beside the DMG. Packaging checks exercise actual relinking
and retain separate dependency/model license obligations.

The release assets must include the DMG, SHA256SUMS, source archive, LAME relink kit,
license archive, release notes and artifact-verification report. Never distribute
an old source/relink archive as if it matched a newly built executable.

Before distributing assets, make the repository public, enable and externally
verify GitHub Private Vulnerability Reporting, and configure branch/tag protections
and the release-preparation environment where the account plan supports them.
See [release procedure](docs/RELEASE_PROCESS.md) and [security policy](SECURITY.md).


## A4 export and summary presentation correction — 15 October 2026

Current source uses uniform portrait A4 pages, a recording title followed by the
intact visual summary and saved text starting two body-line advances below on
that page when space permits. Omitted visual facts follow the saved summary,
without losing their selectable content. Summary headings are explicitly bold
in native UI and both PDF routes; body text stays regular. TXT/copy and persisted
schemas are unchanged. Visible panels use distinct muted pastel surfaces in both
light and dark native themes; PDF retains the printable light appearance.

Synthetic source verification: 49 export/snapshot and 635 composition/geometry/
contrast/preservation/PDF checks PASS; 92 core and 121 UI-state checks PASS;
163 transport tests PASS / zero failures. Actual text-only PDF writer compiled
in an isolated synthetic harness passes A4 and heading/body font-trait checks.
Full final native app source typecheck PASS, not a packaged app rebuild. Rendered
A4 and light/dark synthetic proofs were inspected. Initial old landscape-size
assertion was updated to the explicitly requested portrait requirement and rerun.

These changes are **not installed or package-verified**: installed build70 remains
unchanged. Full rebuilt-bundle/native executable acceptance and protected owner-
authorized replacement remain pending, as do physical-device, owner-library UI,
clean-user installation and existing release gates. No model download, recording,
owner-data inspection or publication was performed; no extra app bundle created.


## A4 correction installed locally as build71 — 15 October 2026

This supersedes the preceding source-only/not-installed note for the A4/headings/
pastel correction. A full nondevelopment0.1.0/build71 was built from the current
source and installed through an owner-authorized protected atomic replacement.
Installed/staged/candidate inventories and signatures match; the full data/model/
settings backup and protected-source SHA256 inventories remain unchanged after
installation and cleanup. Exactly one prior app build70 remains for rollback;
explicitly approved obsolete application copies and new temporary compiler
products were removed. Source caches, evidence, all backups and matching relink
kits were preserved. The prior cleanup denial was resolved by fresh user approval.

Fresh verification: current source/link/codec identities, all41 packaged worker
resource hashes and36 relink-kit hashes, actual LAME relink, ad-hoc signatures,
portable runtime and deny-network worker missing-input rejection PASS. Native19
executable regressions PASS, including49 export snapshot and635 composition/PDF
checks. Current core/UI/source/packaging gates PASS; compiled Speech55, MLX18 and
transport163 tests PASS with zero failures. Matching build71 relink/source kit
retained locally. No extra app bundle remains beyond installed71 and rollback70
in the controlled output locations.

This is a same-user update, **not** clean-user installation or a notarized public
release. The production app was not launched after replacement; owner-library
visual acceptance, physical device/real inference, minimum-OS hardware, DeveloperID
and notarization remain separate gates. No recordings were started, model weights
downloaded, owner audio played, transcripts inspected, or assets published.
