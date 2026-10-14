# Vecta 0.1.0 developer-preview verification

Updated: 15 October 2026. Apple Silicon, macOS 15+, build 65 published developer preview.

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

- Clean public-source build 64 and its local DMG verification passed. The earlier
  DMG and matching kits are retained, but are not the binary binding for this
  changed source revision.
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
