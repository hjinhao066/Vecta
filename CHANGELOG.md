# Changelog

## 0.1.0 — unreleased developer preview

- Native macOS recording library, independent BLE and Wi-Fi Fast Transfer,
  local audio import/playback/conversion/export and historical-library migration.
- Local WhisperKit/SpeakerKit speech, voice identity confirmation/merge,
  processing history, cancellation and checkpoint recovery.
- MLX-only Qwen3.5 4B/9B text/visual summaries, recording assistant and library answers.
- Optional GigaAM v3 (Sber, MIT) speech recognition on MLX for Russian speech, selectable
  next to Whisper; SpeakerKit diarization, checkpoints and all later stages are shared.
- English/Russian UI and prompt language snapshots, light/dark native appearance.
- Removed legacy VectaQwen, C++ inference helpers, CMake and mandatory llama.cpp
  checkout from production builds/tests/packaging. No archived model-weight deletion.
- Preserved old Codable model IDs and completed results. Unfinished legacy jobs
  retain original requests/results and require explicit MLX reselection/new version.
- One-command source build, clean explicit public export, regression/full-build CI,
  ad-hoc DMG verification, SHA256 assets and matching LAME source/object/relink kit.
- Updated authorization/privacy, device acceptance, provenance and security policy.

Not published. Not Developer ID signed or notarized. Public private-reporting
activation, repository protections and clean-user acceptance remain separate
owner gates. See RELEASE_READINESS_REPORT.md for actual evidence and limits.
