# Offline authorization investigation — 12 October 2026

This is an isolated synthetic harness, not a product authorization implementation.
Run `Research/OfflineAuthorization/run.sh` from the repository. It compiles the
current Core sources with the research entrypoint into a temporary directory and
removes the executable afterward. Requires macOS, Swift, Security and CryptoKit.
No Bluetooth, network, Keychain access, recordings, persisted keys or device writes.
The app's explicit source list does not include this directory.

## Independently established

- NativeBluetoothSession.start always prepares modern-device identity through
  PartnerPlatform before it creates its CBCentralManager. Existing user JWTs can
  avoid a token refresh, but do not avoid gen-key and sn-sign on a new session.
- PartnerPlatform.prepare requests gen-key without a body and sn-sign with only
  device type and serial in the JSON body. No RSA public key is explicitly sent
  in sn-sign. This is a useful clue, NOT proof of signature/key independence:
  the service could retain state associated with the bearer identity.
- The current modern owner handshake uses config.userID unless a handshakeToken
  override is provided. NativeMacApp supplies an override only for legacy devices.
  Removing HTTPS alone would therefore still leave an owner identity dependency.
- FE20 changes the signature command marker; it still carries the same kind of
  server-issued serial signature. It is not an implemented factory-reset command.
  The cited protocol ledger and pinned SDK README are absent from this export;
  comments about vendor behavior are not independent verification of that SDK.
- Hardware has not been reset or unbound in this investigation. The owner reports
  the recorder is connected only to Vecta on Mac, not to the phone.

## Synthetic results (run successfully on 12 October 2026)

1. Locally generated ephemeral 2048-bit and 3072-bit RSA private keys can be wrapped
   in PKCS8 and imported by the existing PartnerRSAKey implementation. Their SPKI
   public PEMs pass the existing BLE packet builder. Synthetic RSA PKCS1-encrypted
   bootstrap bytes decrypt correctly. This establishes host-format compatibility
   only: no assertion about the recorder accepting either key size or key origin.
2. Two SessionMaterial packets with DIFFERENT sequence numbers reuse the same
   keystream. XOR(ciphertext1, ciphertext2) == XOR(plaintext1, plaintext2), excluding
   authentication tags. This is reproducible evidence of nonce reuse in Vecta,
   not a demonstration of an attack on a live recorder or independent proof of
   the vendor firmware's design.

## Reset evidence and blocker

Official vendor instructions retrieved directly from the public help-center API:

- [NotePin S reset](https://support.plaud.ai/hc/en-us/articles/53693803255193-How-to-reset-the-Plaud-NotePin-S):
  holding record for 12 seconds restarts the recorder; it does not erase data or
  restore factory settings. Do not describe this as a factory reset.
- [Unbind device](https://support.plaud.ai/hc/en-us/articles/50938789884953-Unbind-device):
  the official app offers Disconnect or remove device / Remove device, followed
  by Erase & remove. This removes account linkage and permanently deletes unsynced
  recorder files. The article permits removal of an already listed device even
  while disconnected. This does not establish what happens for a device linked
  only to a Partner identity or absent from that app's device list.

No verified full factory-reset command was found in this source tree. No phone
control is available. Web search failed with HTTP 503; computer control failed
with `unsupported Codex auth method: apikey`; direct public HTTPS fetch worked.
A reset request is authorized by the owner, but authorization does not establish
which command performs it. No guessed opcode, recording deletion, owner change,
FE20 recovery, keychain deletion or firmware update was performed.

## Next experiments and acceptance criteria

Before changing recorder ownership or storage, inventory the live recorder and
verify local copies of every wanted recording. Historical migration verification
is not a fresh backup of the recorder. Preserve existing pairing until a known
reset/unbind path and current data inventory are available.

Keep future physical probes outside the app build, with explicitly selected
recorder identity, bounded timeouts and redacted reports. Never auto-fallback to
HTTPS. Separate the following experiments:

1. Existing-owner offline reconnect: obtain a legitimate signature baseline in
   a separate explicitly online preparation step; store any necessary signature
   and owner identifier privately. Retry with no URLSession/PartnerPlatform code
   in the probe, same RSA key first. Repeat after app restart and device restart.
2. Substitute a locally generated RSA key while holding signature, owner identity,
   firmware and BLE sequence constant. Record the exact stage of rejection or
   success. A failed new key does not by itself prove server generation required.
3. Repeat across signature age and independent authorized preparations to test
   signature stability, expiry and possible key binding. Do not publish signatures.
4. Only after a verified reset/unbind, test fresh locally generated owner identity
   without developer credentials or any cached server signature. Do not claim
   “any user” based on this developer-owned device's reconnect test.
5. FE20 is a separate state-changing experiment with unknown preservation effects;
   do not use it as an automatic retry or an assumed factory reset.

Full success requires a clean local profile, absent Partner credentials, absent
inherited signature/owner state, networking denied, first pairing plus reconnect
and recording listing/download on real hardware. Replicate with another owner's
NotePin S before claiming general consumer compatibility. App-local authorization
cannot substitute for a firmware trust anchor unless the firmware supports it.

Unresolved: signature format/verification, first-owner provisioning, firmware
trust anchors, offline signature reuse, hardware key compatibility and true reset.
No production code, installed bundle, credentials or user library changed.
