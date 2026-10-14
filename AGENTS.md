# Vecta agent rules

- Before substantial changes, read docs/BUILD.md, docs/MIGRATION.md, docs/PROVENANCE.md and RELEASE_READINESS_REPORT.md. In the internal development tree, also read docs/CURRENT_PROJECT_STATE.md, docs/AGENT_HANDOFF.md and docs/VERIFICATION.md when present; these private journals are deliberately omitted from the public source export. Inspect git status/diff/log when Git is initialized.
- This product supports macOS only. Preserve independent transport and local-only AI. Do not add UIKit/iOS targets, hosted processing or cloud inference fallbacks.
- Preserve user data and historical schemas. Back up before installation or migration changes; never reset inherited work or commit credentials, recordings, model weights or private diagnostic evidence.
- Keep third-party notices and retained-source provenance. A rename does not establish clean-room origin.
- Model downloads require explicit user action. Publishing, device deletion/unbinding and starting a recording require explicit user authorization.
- Verify core behavior, transport and relevant native executable checks. Distinguish source/package checks, physical device checks and clean-user installation.
- Keep current-state and handoff documents up to date when present, with precise evidence and unresolved work. In the public source tree, record verification limits and unresolved release gates in RELEASE_READINESS_REPORT.md instead.
