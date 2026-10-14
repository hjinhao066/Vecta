# Native macOS fast-transfer research

12 October 2026. Read-only research; no WiFi association, device commands, authorization, recording, downloads or reset were performed for this investigation. The owner will personally complete fresh onboarding after their separately authorized factory reset. Do not reconnect/provision hardware automatically.

## Product requirement

During an active recording download, offer **Fast transfer** in the bottom transfer strip. An explicit click may switch this Mac temporarily to the recorder AP, transfer the active and queued recordings, then attempt to restore the previous network. If restoration is unavailable, disconnect the recorder AP only if the Mac is still associated with it; do not disconnect a network the user selected meanwhile.

The warning includes a persistent **Больше не показывать** checkbox. Save only the app warning preference. Cancellation changes neither BLE transfer nor WiFi association. A saved preference suppresses the warning on later explicit clicks, never enables automatic switching, and never suppresses macOS permissions or destructive factory-reset confirmation.

## Evidence and limits

Official reference: PLAUD public SDK revision `d532d5a4ddff3714bc153f51467589cfd6b12f4c`, reviewed as documentation/interfaces/sample source, not linked into the product. The sample stops BLE download before opening the AP, forwards the full SSID and password, waits for WiFi handshake status 0, then lists/downloads files. Completed local conversion should finish before switching. The iOS Hotspot API is not a macOS joining solution.

The retained independent emulator and its WiFi protocol report are AGPL-3.0 external research, not part of Vecta. Do not copy its code/tests into this differently licensed tree without a provenance/licensing decision. Its reported Android-SDK synthetic unencrypted AVD transfer is not physical recorder or modern-encrypted acceptance; the underlying bytecode pin evidence is missing from that retained checkout. Protocol details below are investigation leads from the retained report, not hardware-verified guarantees or a clean-room claim.

- Stop BLE stream: `01 1d 00`, protocol response `01 1e 00`. ATT acknowledgment alone is insufficient.
- Open AP: candidate fast-transfer payload `01 0a 00 00`. Last byte is a mode, not an on/off Boolean; firmware meaning requires verification.
- Open response: `01 0a 00 status`, optional eight ASCII password bytes. Full SSID is not demonstrated in this raw response; the SDK can derive it.
- Close AP: `01 0d 00`; response behavior remains uncertain.
- Mac is the binary WebSocket server on TCP 8081. Recorder creates the AP and connects to the Mac; URLSessionWebSocketTask alone has the wrong role.
- Candidate envelope: u24le total size, u8 version, s16le type, s16le JSON size, UTF-8 JSON, optional binary tail. Strict bounds and state validation are necessary.
- Recorder SayHello type 2 precedes host Handshake type 1 (token/stamp); ready status is 0. Heartbeat type 3.
- List type 11 uses uid/start/single; file entries are u32 session, u32 size, u16 scene, unlike BLE entries.
- Download type 12 uses session/scene/start/end. File content type 13 uses session/offset/length/last plus bytes; last=1 and verified total bytes terminate a file, not BLE's tail semantics.
- Modern WiFi may reuse BLE session material and select AES-GCM by a capability bit, otherwise ChaChaPoly. Cached BLE success does not establish cached WiFi-token acceptance, sequence interoperability or encrypted WiFi success.

## macOS implementation direction

Use CoreWLAN's actual interface, directed SSID scan, associate(to:password:) and disassociate(), on a serial worker rather than the main thread. Current SSID/BSSID and scan metadata require Location Services authorization according to the inspected current Apple SDK headers. Do not extract stored WiFi passwords, rewrite preferred-network configuration or delete network profiles. A remembered secure/enterprise network is not guaranteed to restore through password:nil.

Use NWListener/NWProtocolWebSocket for the host server. Bind to the device-network interface/address and validate the expected authenticated recorder, frame sizes and sequence/transfer state. Firewall prompts and sandbox server entitlement are distinct from local-network privacy; accepting TCP alone does not necessarily trigger local-network authorization.

Integrate with NativeBluetoothSession and the existing transfer strip, but do not use ordinary stop()/disconnect() for handover: they clear crypto and queue state. Add an explicit bounded state machine preserving the recording identity/queue, stopping BLE by protocol acknowledgment, opening/joining AP, authenticating WiFi, restarting the interrupted file from byte zero, receiving sequential files, converting/publishing through existing verified native audio helpers, and cleaning up on success/cancel/error. Do not splice partial BLE/WiFi data or automatically delete recorder files.

Physical gates after owner onboarding: confirmed capability, exact AP mode/name/password, cached authenticated WiFi handshake, real AP addressing/dial timing, modern encrypted nonempty transfer, cancellation/timeout, previous-network restoration/fallback and no Partner requests. Until these pass, no hardware-verified Fast transfer claim is warranted.

## Public references

- https://github.com/Plaud-AI/plaud-sdk-public/blob/d532d5a4ddff3714bc153f51467589cfd6b12f4c/README.md
- https://github.com/Plaud-AI/plaud-sdk-public/blob/d532d5a4ddff3714bc153f51467589cfd6b12f4c/ios/PlaudTemplateApp/Managers/SyncManager.swift
- https://github.com/Plaud-AI/plaud-sdk-public/blob/d532d5a4ddff3714bc153f51467589cfd6b12f4c/android/app/src/main/java/com/plaud/template/managers/SyncManager.kt
- https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy
- https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.network.server

## Optional-password compatibility evidence, 13 October 2026

Read-only inspection of the same pinned iOS SDK binary (SHA-256 `d52ec6a815b9c4e8fbf5502a4b53af8a97a7b4926b62b51204e9d0376832d5b6`) confirms `onStickWiFiOpen(status:wifiPass:)` at `0x51bcc` accepts an optional string. At `0x51e98–0x51eac`, a nil argument becomes an empty Swift string before forwarding the callback. There is no hard-coded fallback password in this path. `operateWiFi(open:isOTA:hotspotPassword:)` and the payload builder also permit an explicit eight-ASCII-byte password, but Vecta retains its existing AP-open request and handles the recorder's reply rather than changing AP configuration. No SDK code or binary is linked/shipped.

The owner's installed42 failure reached `wifiOpening` and rejected a 24-byte encrypted BLE notification before any WiFi scan/association. The sequence prefix and AEAD tag account for 20 bytes; the remaining four-byte reply was excluded by the twelve-byte-only product parser. The new parser accepts the documented optional-password forms. CoreWLAN selection uses nil only for an open AP reported by the authenticated recorder; nonempty credentials still require WPA Personal. WiFi session authentication/encryption and exact network restoration remain mandatory. Source/synthetic evidence is not yet physical nonempty-transfer acceptance.

## Optional feature announcement and visibility evidence, 13 October 2026

The same pinned iOS SDK initializes `wifiUseAes` to false at `0x3f114–0x3f118`, and sets it from bit3 of the first feature byte at `0x4cf9c–0x4cfa0`. `onGetFeatureResult` forwards all bytes after the three-byte command header; trailing feature bytes do not invalidate the first-byte selection. Therefore absent `8A` preserves ChaChaPoly, while an announced bit3 selects AES-GCM. No third-party implementation was copied or shipped. Vecta now retains this baseline per session, acknowledges the first valid announcement once, accepts extensions/duplicates, and prevents a conflicting late announcement from silently replacing the active cipher after AP readiness.

The supported-device transfer button is kept visible separately from readiness and disabled while the command queue or capability gate is unavailable. Encryption, confirmed WiFi capability, serial/model/version checks and explicit user action remain prerequisites. The owner must still verify real association/handshake/transfer/cancellation after installation.

## Physical scan throttling and official startup timing, 13 October 2026

The owner authorized agent-driven physical synchronization/Fast transfer. Installed48 authenticated BLE, obtained WiFi capability, stopped BLE transfer and received AP-open success, then showed recorder-not-found before any network association. The expected exact SSID appeared in macOS WiFi settings later. airportd completed the first live directed scan in 2.70 seconds; a second request 0.0125 seconds later explicitly received cached results under its ten-second scan throttle. The product now waits 10.5 seconds after an empty scan before its second bounded scan, checks cancellation/deadline during the wait, and revalidates current-network ownership. This does not bypass system scan throttling.

The pinned public iOS sample's SyncManager.swift lines 414–419 explicitly waits three seconds for AP startup and invokes connectWifi with 180 seconds/retries. These are timing evidence, not macOS APIs to import. The retained SDK binary's onWiFiOpen at 0x82108–0x82254 passes nil for a reply shorter than twelve bytes; onStickWiFiOpen forwards an empty string for nil. The sample comment claiming an SN-derived default is not sufficient to establish that algorithm in the inspected binary; no guessed password was added. Absence of an echoed password is not independent physical proof of the AP's actual security. Corrected physical association/handshake/nonempty transfer remains pending. No SDK code/binary or automatic recorder deletion behavior is shipped.

## Protected-AP short reply and explicit password request, 13 October 2026

Installed49 physical retest found the AP after the fresh-scan interval, then correctly rejected open-security selection because the recorder AP is protected. The earlier short-reply/open-AP interpretation is superseded: missing echo is not proof of open security. The pinned SDK validates an explicitly supplied eight-ASCII-byte hotspot password at 0x471a8–0x471c4 and appends it to the non-OTA `01 0a 00 00` request at 0x916f0–0x91704. Vecta configures a per-attempt random password through authenticated BLE and retains it for short success; any echoed value must match. No SN-default algorithm is guessed, and no open-network fallback is taken. Synthetic transport147 passes; candidate50 physical acceptance is pending.

## Official Android serial-default evidence supersedes explicit-password attempt, 13 October 2026

Installed50 physical association failed with the explicitly supplied random password. Read-only retained official classes.jar inspection proves WifiAgentImpl.access$calculateWifiPassword returns Kotlin takeLast(serial,8), and IotaStateTracker.onCallback uses it when BleDevice.getWiFiPwd is nil (bytecode offsets76–98). This confirms the documented SN-derived default rather than guessing it. Current source uses that default for four-byte success, and returned password for twelve-byte success; the AP-open request is restored to its original four-byte form. No BLE/RSA Keychain secret is involved or exposed. Transport144 passes; full51/physical WiFi association and transfer are pending.

## Version2 and per-device naming compatibility, 13 October 2026

Installed53 physically authenticated/decrypted an 82-byte WiFi message but rejected envelope version2. Android BaseWifiResponse verifies the same eight-byte header layout and reads the version; BaseWifiRequest emits version1. Vecta now decodes/preserves versions1/2 while retaining the SDK-compatible outbound version1 default. BleDevice.getWiFiName bytecode verifies Plaud/PLAUD case variants for project881/882, selected by firmware/protocol state. Current NotePin S transfer chooses only exact serial-suffix-derived candidates, not arbitrary names or user display labels, and scans both together. Transport148/synthetic naming/security/restore checks pass; corrected physical handshake/nonempty transfer remains pending. No SDK source or binary is linked/shipped.

## Independent SDK identity/acknowledgement/correlation review, 14 October 2026

Retained Android legacy p5 parses token/pVer without mandatory serial. x7.a(p5) verifies case-insensitive selected-serial MD5 using s7 UTF-8 digest helpers before command1 owner-token handshake. The newer serial-bearing hello can carry an opaque token; these identity forms must not be conflated. Current implementation requires exact nonempty serial or, if absent/empty, a matching32hex serial digest after AEAD. WiFi pVer is metadata (signed/string forms included), not an extra numeric20 gate.

Legacy command12 w1 contains session/status without total; newer FileSyncStatusResponse uses total only when positive. Current file state checks requested session/success and, when supplied positive, exact inventory total, while retaining every chunk/full-size constraint. Legacy list s5 correlates response uid with its request; the live collector now requires the echoed per-request id. Transport153 includes a complete synthetic encrypted v2 hello through nonempty file for both ciphers; physical conversion/publication/cancel/network restoration remains unverified. No SDK implementation is linked or shipped.
