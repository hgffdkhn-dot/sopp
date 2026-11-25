#!/usr/bin/env bash
# Build the Kotlin manager APK without Gradle (CI-friendly, no daemon).
set -euo pipefail

REPO=${1:?usage: build_app.sh <repo> <ko> <out> <kotlinc>}
KO=${2:?}
OUT=${3:?}
KOTLINC=${4:?}

SDK=${ANDROID_HOME:-${ANDROID_SDK_ROOT:?set ANDROID_HOME}}
BT="$SDK/build-tools/34.0.0"
AJAR="$SDK/platforms/android-34/android.jar"
KHOME=$(dirname "$(dirname "$KOTLINC")")
KSTDLIB="$KHOME/lib/kotlin-stdlib.jar"
SRC="$REPO/app/app/src/main"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK"/{classes,dex,apk,gen}

echo "=== aapt2 compile/link ==="
"$BT/aapt2" compile --dir "$SRC/res" -o "$WORK/res.zip"
python3 - "$SRC/AndroidManifest.xml" "$WORK/AndroidManifest.xml" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src, encoding="utf-8").read()
head = s.split(">", 1)[0]
if "package=" not in head:
    s = s.replace("<manifest", '<manifest package="com.sopp.su"', 1)
open(dst, "w", encoding="utf-8").write(s)
PY
"$BT/aapt2" link -o "$WORK/apk/base.apk" -I "$AJAR" \
  --manifest "$WORK/AndroidManifest.xml" -R "$WORK/res.zip" \
  --java "$WORK/gen" --auto-add-overlay \
  --version-code 3 --version-name 1.2.0 \
  --min-sdk-version 26 --target-sdk-version 34

echo "=== javac R.java ==="
find "$WORK/gen" -name '*.java' > "$WORK/gen.txt"
javac -source 17 -target 17 -cp "$AJAR" -d "$WORK/classes" @"$WORK/gen.txt"

echo "=== kotlinc ==="
mapfile -t KT < <(find "$SRC/java" -name '*.kt')
"$KOTLINC" -jvm-target 17 -cp "$AJAR:$KSTDLIB:$WORK/classes" \
  -d "$WORK/classes" "${KT[@]}"

echo "=== d8 ==="
"$BT/d8" --lib "$AJAR" --min-api 26 --output "$WORK/dex" \
  $(find "$WORK/classes" -name '*.class') "$KSTDLIB"

echo "=== assemble ==="
cd "$WORK/apk"
cp "$WORK/dex/classes.dex" .
mkdir -p lib/arm64-v8a assets
cp "$SRC/jniLibs/arm64-v8a/libsoppsu.so" lib/arm64-v8a/
cp "$KO" assets/soppsu.ko
zip -qr base.apk classes.dex lib assets

echo "=== zipalign + sign ==="
"$BT/zipalign" -f 4 base.apk aligned.apk
keytool -genkeypair -keystore "$WORK/sopp.jks" -storepass sopp1234 \
  -keypass sopp1234 -alias sopp -keyalg RSA -keysize 2048 \
  -validity 10000 -dname 'CN=s0ppSU,O=s0ppSU,C=CN' >/dev/null 2>&1
"$BT/apksigner" sign --ks "$WORK/sopp.jks" --ks-pass pass:sopp1234 \
  --key-pass pass:sopp1234 --min-sdk-version 26 aligned.apk
"$BT/apksigner" verify aligned.apk

mkdir -p "$OUT"
cp aligned.apk "$OUT/s0ppSU-v1.2.0.apk"
echo "=== APK ==="
ls -lh "$OUT/s0ppSU-v1.2.0.apk"
