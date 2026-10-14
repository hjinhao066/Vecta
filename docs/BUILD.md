# Build Vecta

## Supported build environment

Full product: native Apple Silicon (arm64), macOS 15 or later, full Xcode 26.0+
with Swift 6.2+, accepted Xcode license, Python 3.9+, Git, make and curl. Xcode
Command Line Tools alone are insufficient: MLX needs the Metal compiler and
resource bundles. Select Xcode in Settings > Locations > Command Line Tools.
The local release check records the exact Xcode/Swift versions used; CI selects
Xcode 26.3 on the standard ARM64 `macos-15` runner and fails on the wrong platform.
At least 8 GB RAM and 8 GB free build space are recommended; larger builds need
more headroom. Real 9B inference requires at least 16 GB unified memory.

No Homebrew, CMake, llama.cpp checkout, Python runtime inside the app, PLAUD SDK,
Partner credentials or model weights are required to build. Dependency-source
fetches require network access. They do not upload the source tree. Codec source
archives and build-only DMG tools are SHA256-pinned; Swift package revisions are
locked in both Package.resolved files. Neither builder downloads model weights.

## One command

From the source root, using a NEW output directory:

```sh
python3 -I Tools/release.py build dist/Vecta-0.1.0 --version 0.1.0 --build 65
```

This checks prerequisites, public source, core/UI-state/speaker/localization/
prompt/local-AI/legacy compatibility and packaging guards, compiles Speech and
MLX workers plus the native app and static codecs, runs transport and compiled
Speech/MLX tests, verifies the actual bundle, exercises matching LAME relink,
creates and mounts/verifies the DMG, simulates copying the app into a temporary
Applications directory, and writes release assets and checksums.

Outputs:

- `dist/Vecta-0.1.0/build/Vecta.app`
- `dist/Vecta-0.1.0/artifacts/Vecta-0.1.0-macOS-arm64.dmg`
- matching source archive, LAME source/object/relink kit, license archive,
  release notes and SHA256SUMS in the same artifacts directory.

The command never installs/replaces an app, starts a recording, operates a device,
reads owner audio, deletes models or publishes/uploads anything. Existing output
paths are refused. Preserve failed outputs for diagnosis; use a new path to retry.
The generated DMG is ad-hoc signed, not notarized. See [installation](INSTALL.md).

## Clean public-source build

```sh
python3 -I Tools/release.py clean .build/clean-release --version 0.1.0 --build 65
```

Copies only explicitly approved public files into a NEW isolated directory, then
builds there. No `.vendor`, previous worker/object/codec/module artifacts or owner
configuration are copied. Speech uses a fresh scratch path and disables the
shared dependency/manifest cache; MLX resolves into fresh SourcePackages with
repository-cache reuse disabled. Codec sources are fetched and authenticated
again. This is a same-machine clean-source test, not a second-Mac or clean-user
first-launch test, and does not imply bit-for-bit identical DMGs across toolchains.

## Individual gates

```sh
python3 -I Tools/release.py doctor
python3 -I Tools/release.py check
python3 -I Tools/release.py check --heavy  # after a full worker build
python3 -I Tools/release.py export .build/public-source
python3 -I Tools/verify-release.py dist/Vecta-0.1.0/build
```

Heavy checks do not fetch model weights. Model-free MLX tests require Xcode's
Metal build route; `swift build` alone is not a substitute for packaged MLX
resource verification. Real inference/physical device tests are separate,
explicitly authorized acceptance checks, not simulated by CI.

Frontend-only and development harness builds are available through Tools/build.py
for contributors; neither qualifies as a release. Full bundles require macOS15;
frontend-only builds retain the historical macOS13 deployment floor.

## LAME modification / corresponding source

Distribute the matching `Vecta-<version>-LAME-relink-kit.tar.gz` alongside every
DMG, not just notices. It includes authenticated LAME3.100 source, codec source
archives/headers/licenses, application object, transport/audio archives,
non-system linker inputs, exact link/codec manifests and a working relink script.
Its README explicitly permits modifications and reverse engineering for debugging
LGPL-covered modifications. See [dependency obligations](DEPENDENCIES.md).
