# Bilingual architecture and implementation checkpoint

Scope: 14 October 2026. The owner requests complete English/Russian UI, English on the first launch, a language choice on the welcome screen and in Settings, application restart to apply a change, localized local-model prompts, testing and protected replacement of installed build61.

## Architectural assessment

Vecta separates its native SwiftUI/AppKit interface, main-actor presentation model, library/export storage, independent transport package, local AI host and separate speech/MLX/archived GGUF executables. Keep those boundaries; localization must not introduce a hosted dependency or tie transport to the app module. Existing orderly termination through `NativeMacDelegate.applicationShouldTerminate` and `NativeMacModel.stop()` should own restart cleanup rather than forcibly killing a process. The previous responsiveness fixes and generation/ownership guards remain required.

Strings are distributed across views, menus, domain presentation properties, error descriptions, exports, model metadata and model prompts. There is no existing complete localization catalog. Persisted built-in format/template definitions and historical result text are also Russian: these are data, not mutable UI resources. Do not translate them in place or change canonical identities/revisions to match a display language. User-written names, transcripts, summaries, custom instructions and literal quotes remain user content.

At the initial assessment, the speech worker forced `language: "ru"` and MLX prompts explicitly required Russian. English functionality therefore required a new-job language policy as well as translated UI, not a model-weight change. Release62 implements that policy while preserving historical absent-language behavior.

## Recommended implementation

- Central, bounded English/Russian resource catalog with interpolation preserved as data; freeze the interface language for the process. Missing/invalid preferences choose English, independently of the macOS language.
- Localize strings at presentation boundaries, including AppKit menus, accessibility, errors, status messages, built-in catalog display names, exported headings, dates and units. Preserve identifiers, protocol strings, regexes, filesystem paths and stored user content.
- Add a welcome surface before production runtime initialization. Choose a language there or in Settings; confirm a normal restart. Block restart during transfers, recordings, imports and active inference. Persist only language/welcome preferences; retain the existing runtime and storage policies.
- Add an optional output-language snapshot to new requests. Absent language retains historical Russian behavior. New bilingual speech jobs use supported automatic language detection rather than forcing English on Russian audio. Capture language in summary/visual/chat/library inputs and checkpoint identity; do not reinterpret queued historical jobs.
- Keep the evaluated Russian prompt path unchanged. Add equivalent English instructions and model-free prompt/schema coverage, then synthetic native worker checks for both languages. Never process owner recordings for acceptance.

## Verification and installation gates

Catalog/interpolation coverage, default-English and persisted-language behavior, unchanged historical request/format/template round trips, native restart ownership and busy guards, synthetic English/Russian UI including the welcome screen and compact windows, local prompt/speech checks, core/domain/export/cache/native/transport/package/public-tree gates, full nondevelopment package signatures/resources/relinking. Source checks, executable/UI checks, physical devices and clean-user installation are distinct scopes.

Before replacement: fresh verified five-root backup, atomic installation, keep61 rollback, independently verify installed identities and protected roots. No automatic production launch, downloads, recording/device operations or publication.

## Release62 outcome

Full nondevelopment bilingual62 is installed after owner-confirmed app closure, a fresh five-root backup (547 verified file/link identities), atomic replacement and independent candidate/installed/61-rollback/backup/protected-root checks. Installed62 was not automatically launched; owner recordings were not read or processed, no model weights downloaded and no device commands or publication performed.

Verified scope: catalog997/literal938/localization3037, Swift69/C++80 model-free language/prompt/task checks, actual MLX XCTest18, seven retained Russian prompt-byte comparisons, current core/native/transport/cache/package/public gates, complete worker/resource/signature/relink checks, retained source-matching isolated compact welcome/Settings/en→ru→en restart UI, and five packaged-MLX existing-model synthetic-text cases (summaries en/ru; assistant/semantic/library en with original Russian evidence preserved). Known model hashes/shared-lease bytes remain unchanged. See `CURRENT_PROJECT_STATE.md`, `VERIFICATION.md` and `AGENT_HANDOFF.md` for exact evidence.

This is an ad-hoc local release, not Developer ID signed/notarized or published. Actual new bilingual ASR, long-input generation, archived GGUF inference, universal/owner-recording linguistic quality, new physical-device and clean-user/minimum-OS acceptance remain separate scopes.
