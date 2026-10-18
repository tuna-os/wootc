#!/bin/bash
# Build the PE digest/signature verifier independently from target-image ABI.
# Run in Ubuntu 24.04 with build dependencies installed (Containerfile stage).
set -euo pipefail
SOURCE_REV=db731f0c4dd75e112e2abdfbe9443065742e58c3
CCAN_REV=b1f28e17227f2320d07fe052a8a48942fe17caa5
packaging_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
out=${1:?usage: build-sbverify.sh OUTPUT_DIRECTORY}
out=$(realpath -m -- "$out")
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$out"
git -C "$work" init -q
git -C "$work" remote add origin https://git.kernel.org/pub/scm/linux/kernel/git/jejb/sbsigntools.git
git -C "$work" fetch --depth=1 origin "$SOURCE_REV"
git -C "$work" checkout --detach FETCH_HEAD
[[ $(git -C "$work" rev-parse HEAD) == "$SOURCE_REV" ]]
[[ $(git -C "$work" ls-tree HEAD lib/ccan.git | awk '{print $3}') == "$CCAN_REV" ]]
git -C "$work/lib/ccan.git" init -q
git -C "$work/lib/ccan.git" remote add origin https://github.com/rustyrussell/ccan.git
git -C "$work/lib/ccan.git" fetch --depth=1 origin "$CCAN_REV"
git -C "$work/lib/ccan.git" checkout --detach FETCH_HEAD
[[ $(git -C "$work/lib/ccan.git" rev-parse HEAD) == "$CCAN_REV" ]]
cd "$work"
./autogen.sh
# These warnings concern unused debug counters and deprecated signing-engine
# functions. Do not change verification code or suppress other build errors.
./configure CFLAGS='-O2 -Wno-error=unused-but-set-variable -Wno-error=deprecated-declarations'
make -C lib/ccan
make -C src sbverify
gcc -O2 -I. -Isrc -Ilib/ccan "$packaging_dir/sbpehash.c" \
    src/sbverify-image.o src/sbverify-fileio.o lib/ccan/libccan.a -lcrypto \
    -o "$out/sbpehash"
install -m755 src/sbverify "$out/sbverify"
ldd src/sbverify > "$out/ldd.txt"
if grep -q 'not found' "$out/ldd.txt"; then
    echo 'FATAL: incomplete verifier dependency closure' >&2
    exit 1
fi
while IFS= read -r library; do
    install -m755 "$library" "$out/${library##*/}"
done < <(awk '/=> \// {print $3} /^[[:space:]]*\// {print $1}' "$out/ldd.txt")
[[ -x "$out/ld-linux-x86-64.so.2" ]]
install -m644 COPYING "$out/COPYING"
printf 'sbsigntools=%s\nccan=%s\n' "$SOURCE_REV" "$CCAN_REV" > "$out/source-revisions.txt"
"$out/ld-linux-x86-64.so.2" --library-path "$out" "$out/sbverify" --version
(cd "$out" && sha256sum sbverify sbpehash ./*.so* > SHA256SUMS)
