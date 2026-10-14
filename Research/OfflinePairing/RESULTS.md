# Fully offline first-pairing research

12 October 2026; owned NotePin S, firmware advertisement 66055, protocol 20.
After owner-confirmed restoreFactory, passive scan observed bindState=0 and a changed CoreBluetooth UUID. Product Vecta remains closed so it cannot restore the old Partner identity.

The separate app is built from current transport Core sources excluding PartnerPlatform.swift. VectaAuthorization.swift is not compiled. A replacement creates RSA-2048 locally. The entrypoint creates a random local 32-character owner in a private directory. Existing selected-device metadata supplies only target serial/model/protocol; no inherited authentication is read. Symbol inspection found no URLSession or SecItemCopyMatching/SecItemAdd references. This is source/binary dependency evidence, not an OS network-denial test.

Physical attempts completed:

| Mode | Observed result |
|---|---|
| Direct local RSA via FE12, no serial signature | Five GATT writes acknowledged; no bootstrap notifications; timeout at 45 seconds |
| Empty FE10 (one empty fragment) | GATT reached, immediate disconnect, no bootstrap notification |
| Unencrypted Apple-format local owner handshake | Write acknowledged; no response; timeout at 45 seconds |
| Unencrypted Android-format local owner handshake | No owner response; timeout at 45 seconds |
| Read-only full GATT enumeration | Services 1910, 180F, 1804 and 87290102-3C51-43B1-A1A9-11B9DC38478B observed; no authentication attempted |

None of these attempts establishes impossibility for all firmware paths. None reached authenticated file listing. No keys from PLAUD services were requested or reused in these probes. Protocol boundary tests are individually selected experiments, not production retries.
