# Cached vendor identity reconnect

This is not autonomous first authorization: initial provisioning still calls PLAUD Partner token, `gen-key` and `sn-sign` endpoints. The owner authorized this route after resetting their NotePin S and confirming pairing mode on 12 October 2026.

`build.py` builds a separate macOS executable from the production CoreBluetooth driver, replacing only audio conversion with a failure stub. The checker targets the exact previously selected NotePin S serial, reads state/list, and has no call sites for recording, download, deletion, reset, unbinding or FE20 recovery. It refuses to run alongside production Vecta.

- `--provision`: reuse the owner's existing credential adapter, perform online provisioning and save identity in Keychain only after authenticated state/list success. Refuses to replace an existing cached identity.
- No flag: load only the per-device Keychain identity, with no API token or Partner credential lookup, then reconnect using a fresh device-produced session.

Private reports live outside the repository in Application Support/VectaOfflineReconnectCheck. They contain no RSA keys, signatures, tokens or Partner credentials.

## Physical evidence, 12 October 2026

- 17:51:29 UTC: NotePin S, protocol 20, completed online authorization and state/list read (0 recordings). Long-term identity saved in Keychain.
- 17:52:21 UTC: a new checker process completed state/list using the cached identity under `sandbox-exec -p '(version 1)(allow default)(deny network-outbound)'`. No Partner preparation occurred. A curl control under the same profile failed DNS resolution (exit 6), confirming outbound networking was denied.

This verifies a fresh-process cached-identity connection on this device, not durability after a physical power cycle, firmware update, reset, arbitrary new devices or recording downloads. Empty inventory means audio transfer cannot be tested without an existing recording or the owner's explicit authorization to create one.

Synthetic protocol checks are recorded separately in `Research/OfflineAuthorization/README.md`. This reconnect check does not establish readiness for public consumer release.
