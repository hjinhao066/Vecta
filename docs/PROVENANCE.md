# Source provenance

Upstream experimental starting point: [dans-huang/PinPoint](https://github.com/dans-huang/PinPoint), Apache-2.0, baseline d774b54. The source archive was filtered to the macOS product closure; iOS app, SDK integration, hosted backend, cloud pipeline, experimental probes and historical private development journals are excluded.

`import-ledger.json` records each imported source/resource path and its original SHA-256. `path-renames.json` and `type-renames.json` explain structural mapping. These are provenance records, not claims that renamed code is original.

The local recording repository was replaced with a snapshot-based implementation. The device registry was replaced with a native descriptor table. Old session/config/API classes and the whole Python backend are absent. `VectaAuthorization.swift`, `VectaMigration.swift` and the macOS build/packaging tools were added for this transition.

Serialized recording DTOs, some storage/export/format helpers and compatibility codecs remain adaptations. Their original provenance and Apache notice are retained. Vecta's native user interface, local inference integration, library search and independent Bluetooth implementation are preserved from the existing product. The transport was researched against device behavior and other public protocol references; a source ledger must be reviewed before making any clean-room claim. This project does not make such a claim.

Product authorship and third-party source licenses coexist. Removing a Git remote or starting a new history cannot remove the license obligations of retained code.

## Legacy inference retirement (14 October 2026)

The CMake/QwenWorker and exclusively C++ schema/prompt headers were removed from
future production builds after MLX migration. Import ledger entries keep original
paths/SHA256 and a retirement marker; their absence is not a lost provenance record.
Legacy serialized model IDs/results remain compatible. The inherited ignored
llama checkout/build outputs are not reset, deleted, exported or required.
Remaining MLX embedded vendors retain their own notices independently of the
removed GGUF runtime. Public exports omit internal state/handoff/verification
journals but preserve these origin ledgers and license documents.
