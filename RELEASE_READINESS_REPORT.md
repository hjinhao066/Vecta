# Vecta release readiness — local build verified

Date: 15 October 2026. Version 0.1.0, build64, Apple Silicon/macOS15+,
ad-hoc developer preview. The final clean-source build and local DMG checks pass.
The owner subsequently explicitly authorized protected replacement of their
installed application; that replacement and independent verification are complete.
No public source upload, public release, model download/deletion, owner audio
inference or device operation was performed. The owner subsequently authorized
private source placement, now completed; public launch remains a separate decision.

## Private repository preparation — owner authorized, 15 October 2026

The owner explicitly authorized private GitHub placement of the reviewed source
for preparation. Public visibility, public Release publication and binary upload
remain separate actions, not authorized by the private-source request. Preparation
uses a fresh allowlisted export and a separate Git repository; the internal
working tree, journals, credentials, recordings, models and installation evidence
are not uploaded. GitHub CLI was prepared locally from its official SHA256-verified
archive, without a global installation. Browser authentication completed through
GitHub with credentials stored in the OS keyring, not the source repository.

Private repository: https://github.com/olgvroe/Vecta. GitHub API confirms PRIVATE
visibility and default branch main. Reviewed source was uploaded on main/develop;
all226 remote paths, modes and Git blob identities match the reviewed local commit.
The initial one-commit Git history and source export pass redacted secret scans.
Actions are disabled during initial staging to avoid unsolicited hosted build usage;
no cloud run, tag, binary asset, public Release or public visibility change occurred.
The next step is owner-approved CI execution and release/environment/protection
configuration before reconsidering public launch.

## Final publication audit — 15 October 2026

**Decision: technically prepared for private source-repository staging; not yet
cleared for public GitHub launch under the project's stated release policy.**
The DMG is locally verified, but public binary-release acceptance remains separate.
No public repository or release was published. The later owner-authorized private
source placement is recorded above and does not clear these public-launch gates.

Fresh audit re-ran the current-source release check: public226, packaging60,
core58/UI91/speaker100/runtime52/localization3049/prompt69/legacy117 and host/IPC
checks PASS. The first rerun failed during Swift compilation because the local
filesystem was exhausted (121 MiB free); after removing only this continuation's
own failed-r4 MLX compilation/test scratch, the complete rerun passed. Final r5,
its assets/evidence, earlier inherited work, backups, models and user data were
preserved. The owner independently confirmed that installed64 processing works
after freeing disk space. This is owner-reported setup acceptance, not an
agent-run inference/quality benchmark; the earlier generic error alone did not
prove a disk-full worker exit.

Final corrected public export has226 files and passes redacted gitleaks8.24.3;
workflow actionlint1.7.7 passes. Audit executables match their retained pinned
archives. All five release-asset SHA256 checks pass. The source, license and LAME
archives reject unsafe paths, links/special members and literal owner-home paths.
Actual executable/tool source still matches final64's source manifest. The original local audit preceded Git initialization; the later isolated private
staging index/history was reviewed and scanned. Recheck any subsequent history
before changing repository visibility.

Two documentation defects were fixed: public AGENTS.md no longer requires omitted
private journals, and the security/release procedure no longer assumes GitHub's
private-reporting form is available on a private staging repository. The latter
was checked against official GitHub guidance: establish a verified private contact
for the visibility transition, then enable/test the public-repository form before
launch announcement or asset distribution. These are documentation changes, not
a new executable build. Current exports include them; immutable r5 source/kit
archives retain their build-time documentation checkpoint.

### Remaining public-source launch gates

1. Configure a private staging repository only after owner authorization; review
   its exact index/history. Establish a verified private reporting contact before
   launch. GitHub documents Private Vulnerability Reporting for public repositories;
   enable and externally verify its form after the visibility transition but before
   announcing launch/distributing assets. Do not claim a private staging form is
   already available (see the corrected SECURITY.md and official GitHub guidance).
2. Designate a real security responder/monitoring process and a verified private
   community-reporting contact. Do not invent an email address or publish a fake
   staffed SLA.
3. Run CI on the actual GitHub macOS runner, inspect results, and configure branch/
   tag protection and owner-reviewed release-preparation environment controls.
   Local workflow success is not proof of cloud settings or runner compatibility.

### Additional binary-release gate

Before a public GitHub Release with downloadable DMG, perform and accept first
launch from a downloaded/quarantined image in a clean profile/Mac, including
no-model/no-credential onboarding, relevant permissions and migration limits.
Owner-installed64 success does not substitute for this clean-user test. Developer
ID/notarization is not mandatory for the explicitly disclosed ad-hoc preview;
ordinary consumer distribution claims would require a different acceptance scope.

No unresolved build/package correctness blocker was established by this final
local audit. Storage-full failure still has generic UI messaging and no retained
content-free exit classification; improving that feedback is follow-up usability
work, not evidence that normal processing is broken. This review is not a complete
CVE audit, legal certification or a guarantee of no unknown vulnerability.

## Executive summary

Production inference now uses Speech and MLX only. Archived Codable model IDs,
requests/results and existing weights are preserved; unfinished retired-model
requests require explicit MLX reselection/reprocessing, not silent migration.

The final candidate was built from a new allowlisted public-source export with
fresh dependency, worker, codec and module builds. Its actual nondevelopment
bundle, static-LAME relink kit and DMG passed local verification. This proves the
recorded source/package/native scopes, not clean-user Gatekeeper acceptance,
GitHub-hosted CI, universal model quality or hardware compatibility.

The owner's installed build63 was replaced with this verified build64 after a
fresh verified five-root backup. Build63 is retained for rollback. Independent
post-install checks confirm candidate identity, rollback and backup identity,
four unchanged protected data roots and installed ad-hoc signing. The application
was deliberately not launched by the preparation tooling.

## Completed changes

- Removed VectaQwen, QwenWorker.cpp, exclusive C++ prompt/schema helpers and CMake
  from future production builds. Retired-source provenance remains recorded.
- Fresh pinned Speech/MLX build paths no longer require .vendor/llama.cpp.
- Five-model MLX production registry; legacy IDs remain historical data.
- Source-preserving legacy queue recovery and explicit-new-request regressions.
- Removed automatic retired-model-weight deletion and silent archived preference
  replacement. Model installation remains an explicit user action.
- Model-free prompt checks no longer depend on llama's nlohmann JSON header.
- Public documentation/templates/security and actual dependency/vendor notices.
- Local release entrypoint, clean public export, actual bundle/relink/DMG checks.
- Immutable action pins; fast/security/full-build CI; owner-gated opt-in Actions
  artifact upload and no public publishing command.
- Strict arm64 application/worker checks with an arm64-slice requirement confined
  to Apple's packaged universal Swift compatibility runtime.
- Canonical DMG mountpoint matching and cleanup that does not recursively delete
  a workspace while its image remains mounted.

## Architecture

Native SwiftUI/AppKit + independent BLE/local Wi-Fi transport + source-preserving
local recording store/mailbox. Speech: WhisperKit/SpeakerKit/CoreML. AI: MLX
Qwen4B/9B for text/visual/assistant/library. Static Opus/Ogg/Vorbis/LAME audio codecs.
Model weights are installed separately by user action. Worker launches deny
network. Initial modern Partner authorization is network-dependent; cached
reconnect is local. No cloud inference fallback was added.

## Verification evidence

| Gate | Status | Evidence/scope |
|---|---|---|
| Core/UI/speaker/runtime | PASS |58 core,91 UI policy,100 speaker and52 native-runtime checks |
| Legacy compatibility/recovery/retry | PASS |117 synthetic checks; old request/checkpoint/preference data preserved |
| Packaging regressions | PASS |60 synthetic checks, including SDK-runtime architecture, canonical mount and failed-detach cleanup |
| Prompt language | PASS |69 actual model-free Swift checks; no retired C++ dependency |
| Localization | PASS |3049 checks;1001 catalog entries; no owner-preference changes |
| Host/local-AI IPC typecheck/cache | PASS |Actual host source typecheck and bounded mailbox/ownership/progress fixtures |
| Compiled native app | PASS |13 executable regressions on isolated synthetic data; not owner-library use |
| Transport and speech policy | PASS |153 transport tests;55 speech configuration checks; no physical commands |
| Actual MLX tests | PASS |18 compiled XCTest checks in the final clean build; no model inference |
| Native GUI | PASS, LIMITED |Actual synthetic transcript navigation in en/ru and light/dark; all four retained screenshots inspected; development fixture only |
| Public source/security | PASS, LIMITED |226 allowlisted files; final local gitleaks8.24.3 export scan clean; not a full CVE or privacy proof |
| Workflow YAML/contract/lint | PASS, LOCAL |Parsed workflows, pinned actions and actionlint1.7.7; not GitHub execution |
| Clean full build | PASS |Final clean64-r5 public-source build; fresh workers, dependencies and codecs on this Mac |
| Actual release bundle/relink | PASS |Nondevelopment64, source/link/codec identity,41 LocalAI/36 kit hashes, localization, privacy/runtime, strict ad-hoc signatures, worker missing-input exits1/1, actual LAME relink |
| Actual DMG | PASS, LOCAL |hdiutil verify, mount/detach, Finder layout data, matching mounted bundle, temporary Applications copy and signatures; all five asset checksums verified |
| Protected owner installation | PASS |Fresh five-root557 file/link identities; installed51 identities match candidate;63 rollback matches; four protected live data roots unchanged; independent verification; no launch |
| Real model/Speech inference | OWNER-REPORTED SETUP PASS / NO NEW AGENT TEST |Owner confirms installed64 works after freeing disk space; no newly executed agent inference or universal model-quality claim |
| Physical device rerun | NOT TESTED |No device commands here; earlier owner-accepted NotePinS setup retained, not universal coverage |
| Clean-user downloaded Gatekeeper | BLOCKED |Requires separate clean profile/Mac and owner acceptance |
| GitHub private vulnerability reporting | BLOCKED |Repository/settings/contact activation remains an owner action |
| Actual GitHub Actions/protections | PENDING |Private source repository created and verified; Actions held disabled; no hosted run/protections verified |

The final r5 pipeline completed successfully. Earlier r3/r4 failures were packaging
verification/tooling defects, retained as diagnostics, and are not final candidates.
The build-time source/relink archives retain their report checkpoint; this final
acceptance report was updated after testing and installation. Artifacts and their
checksums were not rewritten to claim later or broader acceptance.

## License/security boundaries

Main LICENSE remains Apache-2.0; NOTICE/provenance/retired-source hashes are retained.
Actual nested MLX/Swift vendor notices are included. Static LAME3.100 requires the
matching source/object/relink kit alongside every distributed DMG; actual relinking
was verified. Technical inventory is not legal certification or a full CVE audit.

Initial Partner service receives authorization/device metadata and returns an RSA
pair/signature; no audio/text/embedding/documents are sent for inference. The
source allowlist and redacted secret scan are defense in depth, not a formal
no-secret guarantee. Only the separate226-file source export was initialized and uploaded to the
explicitly authorized private repository. Its initial index/history was checked
and secret-scanned; the internal working directory and private evidence were not
initialized or uploaded.

## Release statuses

- LOCAL SOURCE BUILD: VERIFIED — clean public-source build and local source/security
  checks pass. Public distribution still requires the owner decisions below.
- LOCAL DMG: VERIFIED — ad-hoc signed developer-preview assets exist and pass local
  package/image/copy checks; clean-user Gatekeeper acceptance remains unverified.
- OWNER INSTALLED APP: UPDATED — build64 installed,63 retained for rollback, fresh
  backups and independent protected-data checks pass; app left closed.
- PUBLIC GITHUB: NOT READY / NOT PUBLISHED — owner repository, private reporting,
  protection/contact and explicit publication decisions remain required.
- AUTOMATED RELEASE: LOCALLY VERIFIED / CLOUD UNVERIFIED — workflow commands
  exercised locally; actual cloud execution and environment protection pending.
  Public publishing is intentionally absent from the workflow.

## Local assets

Final artifact directory: `.build/release-clean-64-r5/release/artifacts/`.

- `Vecta-0.1.0-macOS-arm64.dmg` —12,339,908 bytes.
- `Vecta-0.1.0-source.tar.gz` — matching build-time public-source archive.
- `Vecta-0.1.0-LAME-relink-kit.tar.gz` — matching source/object/relink kit.
- `Vecta-0.1.0-licenses.tar.gz` — component and project license archive.
- `RELEASE_NOTES.md`, `SHA256SUMS`, `artifact-verification.json`.

DMG SHA-256:
`85ab73982e41dff3c739ad1e034dd327813c40024b32056383fa088db7f45fea`.

These paths are local evidence locations, not uploaded/download URLs. Keep the
matching LAME kit with any separately authorized distribution. Internal histories,
private installation evidence/backups, recordings, credentials and model weights
must not be exported. See `docs/RELEASE_PROCESS.md` for remaining owner actions.
