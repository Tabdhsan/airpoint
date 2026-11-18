#!/bin/bash
# Builds build/AirPoint.apk with the Android SDK tools directly (no Gradle).
set -euo pipefail
cd "$(dirname "$0")"

SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
BT="$SDK/build-tools/$(ls "$SDK/build-tools" | sort -V | tail -1)"
PLATFORM="$SDK/platforms/$(ls "$SDK/platforms" | sort -V | tail -1)/android.jar"
if [ -z "${JAVA_HOME:-}" ]; then
  JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
fi
export JAVA_HOME
JAVAC="$JAVA_HOME/bin/javac"
KEYTOOL="$JAVA_HOME/bin/keytool"

rm -rf build
mkdir -p build/gen build/classes build/dex

"$BT/aapt2" compile --dir res -o build/res.zip
"$BT/aapt2" link -I "$PLATFORM" --manifest AndroidManifest.xml \
  --min-sdk-version 33 --target-sdk-version 34 \
  --java build/gen -o build/unsigned.apk build/res.zip

"$JAVAC" --release 17 -Xlint:-options -classpath "$PLATFORM" -d build/classes \
  $(find src build/gen -name '*.java')
"$BT/d8" --min-api 33 --lib "$PLATFORM" --output build/dex $(find build/classes -name '*.class')

cp build/unsigned.apk build/with-dex.apk
(cd build/dex && zip -q ../with-dex.apk classes.dex)
"$BT/zipalign" -f 4 build/with-dex.apk build/aligned.apk

KEYSTORE="$HOME/.android/debug.keystore"
if [ ! -f "$KEYSTORE" ]; then
  mkdir -p "$HOME/.android"
  "$KEYTOOL" -genkeypair -keystore "$KEYSTORE" -storepass android -keypass android \
    -alias androiddebugkey -keyalg RSA -keysize 2048 -validity 10000 -dname "CN=Android Debug,O=Android,C=US"
fi
"$BT/apksigner" sign --ks "$KEYSTORE" --ks-pass pass:android --key-pass pass:android \
  --out build/AirPoint.apk build/aligned.apk

echo "Built $(pwd)/build/AirPoint.apk"
