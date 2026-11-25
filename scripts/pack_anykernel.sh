#!/usr/bin/env bash
# Wrap the compiled kernel into an AnyKernel3 flashable zip.
# AnyKernel3 replaces kernel+dtb only and keeps ramdisk intact, so the
# installed Kitsune Magisk survives the flash.
set -euo pipefail

OUT=${1:?usage: pack_anykernel.sh <out> <flashable>}
FLASH=${2:?}
mkdir -p "$FLASH"
rm -rf "$FLASH/AnyKernel3"

git clone --depth 1 https://github.com/osm0sis/AnyKernel3.git "$FLASH/AnyKernel3"
rm -rf "$FLASH/AnyKernel3/.git"
cp "$OUT/Image.gz-dtb" "$FLASH/AnyKernel3/"

sed -i \
  -e 's|^kernel.string=.*|kernel.string=s0ppSU for Redmi K40 Gaming (ares)|' \
  -e 's|^do.devicecheck=.*|do.devicecheck=0|' \
  -e 's|^do.modules=.*|do.modules=0|' \
  "$FLASH/AnyKernel3/anykernel.sh"

cd "$FLASH/AnyKernel3"
zip -r9q "$FLASH/soppSU-kernel-ares.zip" .
echo "packed: $FLASH/soppSU-kernel-ares.zip"
