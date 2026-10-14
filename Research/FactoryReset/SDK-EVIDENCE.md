# Factory reset protocol evidence

Official repository: https://github.com/Plaud-AI/plaud-sdk-public
Pinned revision: d532d5a4ddff3714bc153f51467589cfd6b12f4c

Read-only inspection of vendor SDK; no SDK binary is linked or shipped.
Downloaded binaries and disassembly stay in ignored .build/reset-research.

iOS PlaudBleSDK symbols and ARM64 disassembly:

- restoreFactory at 0x49ed0 calls dataOfRestoreFactory at 0x93a40 through the normal connected-device writer.
- dataOfRestoreFactory appends byte 1, then UInt16 little-endian 0x0066. Payload: 01 66 00.
- dataOfDepair at 0x90844 appends byte 1, UInt16 5 and a Boolean byte. Payload: 01 05 00 clear.
- Official iOS sample DeviceManager.unpair uses cloudUnbind followed by depair(clear: true). Recovery uses depair(clear: false). Cloud linkage and device-local pairing are distinct.
- Official sample blePenState recognizes state 4099 as recording. The probe requires state exactly 1; keyState is recorded separately and is not assumed to be an idle Boolean (observed value 4 while state is 1).
- The probe checks exact serial/model from fresh BLE advertisement and matches that peripheral to the authenticated connection. Existing-owner reconnect may not produce a separate serial-number response.

Vendor file SHA256:

- PlaudBleSDK: `d52ec6a815b9c4e8fbf5502a4b53af8a97a7b4926b62b51204e9d0376832d5b6`
- sdk.swiftinterface: `2272aee1f8883b6ed48039fe4dd6cba7e2095e6d666587e11963ba591aad901d`
- sdk.aar: `041a6f8814d350dbc8bcd4a515487136529bb8bb4368fc88c9b36c9a386aedce`
