# Data migration

New application identity: `app.vecta.mac`. New service state: `Application Support/VectaServices`. New recording store: `Application Support/Vecta/Users/<SHA256 identity>`. Fresh local profiles use `VectaNative`, preserving the existing separate local identity convention.

Migration reads the previous session from the login Keychain without deleting it. The archived library must match that exact identity. Several matching libraries require an explicit folder selection. Existing external recording-folder bookmarks are retained. The old backend is never started.

A library is copied to a unique staging directory. Every regular file is hashed; symlinks and special files are rejected. Source and copy inventories must match before the staging directory is renamed to the Vecta destination. A versioned manifest records the source snapshot. Originals are never deleted. A destination without the corresponding manifest, or a later change to the source snapshot, stops migration instead of overwriting either library. A repeat run preserves new files in the destination.

macOS may enumerate `/var` as `/private/var`; inventory uses filesystem canonical paths with an explicit common-root check. Synthetic checks exercise that behavior through the system temporary directory.

Service migration copies only the recording root/bookmark, selected library bookmark, selected-device identity and analysis queue. It does not copy backend.env, databases, logs or client secrets. Old Partner credentials are read in memory through the compatibility adapter. New credentials belong in Keychain. Defaults from the previous application domain are copied when the corresponding new values are absent; provider/export keys are mapped to Vecta prefixes.

Legacy model weights are reused without copying gigabytes or triggering downloads. New model directories use Vecta/Models. A shared heavy-AI lock continues to coordinate with predecessor workers when the old service directory exists. Compatibility names are confined to `App/VectaMigration.swift`; do not replace historical hashes, JSON keys or model IDs by a global text substitution.

Quit the predecessor application before a real migration. Return to it by launching the retained old bundle: its original library remains available. Do not run both copies against the same external inference mailbox. The new recording repository does not expose cloud upload/transcription mutations or backend binding operations.

Physical migration, first-run OS permissions and credentials for people without a Partner account remain separate acceptance checks; synthetic fixture success is not evidence of those outcomes.

## Signing identity and folder grants

Bookmarks created by the predecessor can fail to resolve under the new application identity. The optional library bookmark then falls back to exact-owner discovery; ambiguity still requires the system folder picker. For the export folder, the saved path is used only when ordinary macOS filesystem access succeeds. This path does not transfer a security grant. If the OS denies access, select the existing library using Settings and the system folder picker. Source bookmarks are never overwritten.

Partner credentials are loaded only when refreshing device authorization. Opening a migrated library and its local inference state does not require a network request or a successful Partner credential lookup.
