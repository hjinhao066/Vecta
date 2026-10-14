# Contributing to Vecta

Vecta is a macOS-only, local-AI project. The main line is `main`; ongoing development
uses `develop`. Open focused pull requests with reproduction steps, tests and a
clear description of the behavior changed. Do not create more long-lived branches
without a need. Read [build instructions](docs/BUILD.md) and [provenance](docs/PROVENANCE.md).

## Non-negotiable boundaries

- Preserve independent transport and local-only inference. No UIKit/iOS targets,
  cloud fallback, hosted processing or proprietary SDK wrapper.
- Never automatically download/delete models, reset/unbind a recorder or begin a
  recording. Device/destructive/publishing actions need explicit authorization.
- Preserve originals, historical Codable identifiers/results and copy-first
  migration. Do not cosmetically rename old hashes, storage keys or filenames.
- Keep cancellation/resource ownership, cross-process heavy-AI lease and network
  denial on workers. Switching models must not silently mutate historical jobs.
- New dependencies require immutable pins, license/notices and provenance review.
  A rename does not establish clean-room authorship.
- Never commit recordings, credentials, tokens, Keychain exports, weights, private
  logs, model outputs, databases, machine-specific paths or editor/assistant settings.

## Required verification

```sh
python3 -I Tools/release.py check
python3 -I Tools/release.py clean .build/contributor-clean --version 0.1.0 --build 64
```

Describe each check as PASS, FAIL, BLOCKED or NOT TESTED and state its scope:
source/static, model-free fixture, actual native executable, real model inference,
physical hardware, or clean-user installation. A mocked package test or successful
compile does not prove physical BLE/Wi-Fi, real6-hour speech or Gatekeeper acceptance.
No large model downloads in pull-request CI. Use synthetic fixtures in new tests;
real devices/models require separate explicit authorization and private evidence.

Use a new output path; failed/inherited build work must not be reset/deleted as a
shortcut. Keep project state/handoff evidence incrementally, but do not include
private diagnostic history in public source archives. Update public docs and the
release report for changed acceptance limits. Run the allowlist gate after adding
new files and review the exact export, not just `.gitignore`.

For vulnerabilities, follow [SECURITY.md](SECURITY.md), not a public issue. Community
behavior is covered by [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).
