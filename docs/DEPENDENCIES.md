# Dependencies and distribution

The existing main license is Apache-2.0 (LICENSE/NOTICE). It is retained, not chosen
anew by an agent. This is a technical compliance inventory, not legal advice or a
legal guarantee. Retained-source authorship/provenance must not be erased by renaming.

| Component | Pinned source/version | Notices / obligations |
|---|---|---|
| WhisperKit / SpeakerKit / ArgmaxCore | argmax-oss-swift `93a97e32fa8f6cc5ef36ccaf3d139e19f17d0408` | MIT framework plus upstream NOTICES; worker consumes locally installed CoreML/tokenizer files |
| MLX language models | mlx-swift-lm `7eb77efa4e8fb56183b905904d122e66ebdb422e` | MIT; transitive package/vendor notices retained |
| MLX Swift | 0.32.3, `19601207e9a0de51e03ee6ec0c3c5f3784275075` | MIT; Metal resources packaged; embedded mlx/ mlx-c / fmt / JSON / metal-cpp licenses collected separately |
| swift-huggingface / swift-transformers | 0.13.0 / 1.3.5, exact revisions in AI/MLX/Package.resolved | Their own package/vendor license and notice texts are authoritative |
| Opus | 1.5.2, SHA256 authenticated archive | BSD-style COPYING retained; static native audio codec |
| Ogg / Vorbis | 1.3.5 / 1.3.7, SHA256 authenticated archives | BSD-style COPYING retained; reviewed Darwin configure patch recorded |
| LAME | 3.100, SHA256 authenticated archive | LGPL; static encoder, decoder/frontend disabled; matching source/object/relink kit mandatory |
| DMG layout tools (build only) | ds-store1.3.1 / mac-alias2.2.2, wheel SHA256 pins in Tools/create-dmg.py | MIT; fetched into separate empty private tool directories, no global install or app runtime dependency; notices in license artifacts |

llama.cpp / VectaQwen / CMake inference are retired, not production dependencies.
Old provenance entries/hashes are retained with retirement markers; removed
components' old licenses are not repurposed to cover remaining MLX vendor code.
The ignored inherited checkout/cache is neither required nor publicly exported.

## Locked Swift closure

Both Package.resolved files are mandatory, revision-locked and consumed with
automatic version updates disabled. Speech additionally locks swift-argument-parser
1.8.2. MLX locks EventSource1.5.1, swift-asn1 1.7.3, swift-collections1.7.2,
swift-crypto4.5.2, swift-jinja2.5.1, swift-numerics1.1.1, swift-syntax603.0.2 and
yyjson0.12.0, as well as the primary packages above. Their exact revisions and
source URLs are recorded in the lockfile, not inferred from semver ranges.
Swift-crypto/BoringSSL and any retained nested vendor notices are collected from
the actual compiled checkouts alongside the enclosing package license. No license
of a wrapper substitutes for a bundled vendor's own terms.

The worker packager recursively collects LICENSE/COPYING/NOTICE/NOTICES/COPYRIGHT
texts from actual Speech/MLX checkouts (excluding Git/build metadata), rejects
linked notices and fails if Argmax NOTICES or codec notices are missing. The
release verifier checks resource/kit content manifests and actual linker identity.
No PLAUD SDK frameworks or old hosted-processing backend are shipped.

## Models are a separate installation

Whisper, SpeakerKit, Whisper tokenizer, GigaAM v3 and MLX Qwen4B/9B manifests pin immutable
revisions, file sizes and SHA256. Downloads require explicit user action; weights
are not in source/app/DMG. Each model has its own declared license and source URL;
framework MIT does not cover weights. SpeakerKit's CC-BY-4.0 publisher/source/license
attribution is retained in Licenses/SpeakerKit-weights-NOTICE.txt. Whisper/CoreML
and tokenizer/model notices must be checked against their pinned source cards when
updating. Both Qwen3.5 model entries declare Apache-2.0. GigaAM v3 E2E RNN-T weights
(ai-sage/GigaAM-v3, MIT) are installed from the pinned MLX conversion
`al-bo/gigaam-v3-e2e-rnnt-mlx`, which declares the upstream MIT license.

## Static LAME distribution

Every DMG release must include its matching source/object/relink kit. It contains
LAME3.100 source and license, all codec corresponding-source archives,
headers/licenses, application object and non-system transport/audio/codec archives,
exact link/codec/source manifests, build instructions and a working relink command.
The supplied README expressly permits modifying the LGPL library and reverse
engineering for debugging those modifications. Do not call COPYING alone enough.
Actual relink/signature verification is required for the release's exact objects.

The app and matching source are Apache-2.0; downstream distribution must preserve
both Apache obligations and the applicable LGPL terms. Potential alternate
licensing of newly authored material, uncertain upstream attribution or commercial
branding decisions require owner/legal review; no main-license replacement is made.

References: [LAME](https://lame.sourceforge.io/license.txt),
[LGPL2.0](https://www.gnu.org/licenses/old-licenses/lgpl-2.0.html),
[Apache2.0](https://www.apache.org/licenses/LICENSE-2.0),
[Argmax NOTICES](https://github.com/argmaxinc/argmax-oss-swift/blob/93a97e32fa8f6cc5ef36ccaf3d139e19f17d0408/NOTICES).

## Ad-hoc preview distribution

Paid Apple Developer membership is not required for this preview's local ad-hoc
signature/DMG. This is not Developer ID, hardened-runtime notarization or an Apple
identity endorsement. Follow official Gatekeeper installation guidance, never
system-security disabling commands. Developer ID/notarization can be a future
owner-authorized path, not a prerequisite invented for the current preview.
