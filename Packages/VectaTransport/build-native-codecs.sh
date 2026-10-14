#!/bin/bash
set -euo pipefail
# Build-only tools: Xcode command line tools, curl, Python, make.
# Native runtime links these archives statically; no Homebrew/Python/FFmpeg.
task_root="$(cd "$(dirname "$0")/../.." && pwd)"
task_codec_root="${VECTA_CODEC_BUILD_ROOT:-$task_root/.build/native-codecs}"
# Keep lexical spelling until the verifier rejects linked ancestors (including
# cache roots). resolve() alone would hide a symlink before validation.
[[ "$task_codec_root" = /* ]] || task_codec_root="$PWD/$task_codec_root"
task_prefix="$task_codec_root/install"
task_verifier="$task_root/Tools/verify-codec-cache.py"

if [[ -e "$task_prefix/archive-integrity.json" || -L "$task_prefix/archive-integrity.json" ]]; then
    # Read-only reuse: no downloads, header replacement, flag changes or reseal.
    python3 -I "$task_verifier" cache "$task_codec_root"
    task_reuse=1
else
    # A partial or old unsealed root is preserved, not resumed/reinterpreted.
    python3 -I "$task_verifier" prepare "$task_codec_root"
    task_reuse=0
fi
export CC="$(xcrun --find clang)" CXX="$(xcrun --find clang++)"
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
export CFLAGS="-O2 -mmacosx-version-min=13.0 -ffile-prefix-map=$task_codec_root=VectaCodecs -fdebug-prefix-map=$task_codec_root=VectaCodecs"
export CXXFLAGS="$CFLAGS"
if [[ "$task_reuse" = 1 ]]; then
    if [[ "$(cat "$task_prefix/build-flags.txt")" != "$CFLAGS" ]]; then
        printf '%s\n' 'Codec flags differ. Preserve the cache and choose a new VECTA_CODEC_BUILD_ROOT.' >&2
        exit 2
    fi
    printf 'Native codecs verified without changes: %s\n' "$task_prefix"
    exit 0
fi

# Each download/extraction has a separate new directory. Build out-of-tree in
# our own empty work directory; never run Python or make from an extracted tree.
fetch_source() {
    local name="$1" suffix="$2" url="$3"
    local download="$task_codec_root/downloads/$name"
    local extraction="$task_codec_root/sources/$name"
    local archive="$download/$name.$suffix"
    mkdir -p "$task_codec_root/downloads" "$task_codec_root/sources" "$task_codec_root/work"
    mkdir "$download" "$extraction" "$task_codec_root/work/$name"
    curl --fail --location --retry 2 --silent --show-error "$url" -o "$archive.partial"
    mv "$archive.partial" "$archive"
    # Verifier authenticates the hardcoded upstream SHA256 before extraction,
    # validates every path/type and rejects links and duplicate entries.
    python3 -I "$task_verifier" extract "$archive" "$extraction" "$name"
    python3 -I "$task_verifier" source "$archive" "$extraction/$name"
}
fetch_source opus-1.5.2 tar.gz https://downloads.xiph.org/releases/opus/opus-1.5.2.tar.gz
fetch_source lame-3.100 tar.gz https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz
fetch_source libogg-1.3.5 tar.xz https://downloads.xiph.org/releases/ogg/libogg-1.3.5.tar.xz
fetch_source libvorbis-1.3.7 tar.xz https://downloads.xiph.org/releases/vorbis/libvorbis-1.3.7.tar.xz
mkdir "$task_prefix"
task_jobs="$(sysctl -n hw.ncpu)"
(cd "$task_codec_root/work/opus-1.5.2" && bash "$task_codec_root/sources/opus-1.5.2/opus-1.5.2/configure" --prefix="$task_prefix" --disable-shared --enable-static --disable-extra-programs --disable-doc --enable-custom-modes && make -j "$task_jobs" && make install)
(cd "$task_codec_root/work/lame-3.100" && bash "$task_codec_root/sources/lame-3.100/lame-3.100/configure" --prefix="$task_prefix" --disable-shared --enable-static --disable-frontend --disable-decoder && make -j "$task_jobs" && make install)
(cd "$task_codec_root/work/libogg-1.3.5" && bash "$task_codec_root/sources/libogg-1.3.5/libogg-1.3.5/configure" --prefix="$task_prefix" --disable-shared --enable-static && make -j "$task_jobs" && make install)
# libvorbis 1.3.7's legacy Darwin flag is unsupported by modern arm64 ld.
sed -i.bak 's/-force_cpusubtype_ALL//g' "$task_codec_root/sources/libvorbis-1.3.7/libvorbis-1.3.7/configure"
(cd "$task_codec_root/work/libvorbis-1.3.7" && PKG_CONFIG_PATH="$task_prefix/lib/pkgconfig" LDFLAGS="-L$task_prefix/lib" CPPFLAGS="-I$task_prefix/include" bash "$task_codec_root/sources/libvorbis-1.3.7/libvorbis-1.3.7/configure" --prefix="$task_prefix" --with-ogg="$task_prefix" --disable-shared --enable-static --disable-examples && make -j "$task_jobs" && make install)
mkdir "$task_prefix/licenses"
for name in opus-1.5.2 lame-3.100 libogg-1.3.5 libvorbis-1.3.7; do
    label="${name%-*}"
    cp "$task_codec_root/sources/$name/$name/COPYING" "$task_prefix/licenses/$label-COPYING"
done
printf '%s\n' "$CFLAGS" > "$task_prefix/build-flags.txt"
python3 -I "$task_verifier" seal "$task_prefix" --built-from "$task_codec_root"
python3 -I "$task_verifier" cache "$task_codec_root"
printf 'Native codecs built and sealed: %s\n' "$task_prefix"
