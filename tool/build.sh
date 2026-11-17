#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT="${1:-$ROOT/build/dist}"
TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT

if ! command -v flutter >/dev/null 2>&1; then
  echo "Flutter stable is required. Install it from https://docs.flutter.dev/get-started/install" >&2
  exit 1
fi

PROJECT="$TEMP/project"
flutter create --no-pub --platforms=linux,android \
  --org io.github.lizcanoskr --project-name aerodrop "$PROJECT"
cp "$ROOT/app/pubspec.yaml" "$ROOT/app/analysis_options.yaml" "$PROJECT/"
cp -R "$ROOT/app/lib/." "$PROJECT/lib/"
python3 "$ROOT/tool/configure_android.py" \
  "$PROJECT/android/app/src/main/AndroidManifest.xml" "$PROJECT"

cd "$PROJECT"
flutter pub get
rm -rf "$PROJECT/test"
flutter analyze
flutter build linux --release
flutter build apk --release

mkdir -p "$OUTPUT"
PACKAGE="$TEMP/aerodrop"
mkdir -p "$PACKAGE"
cp -R build/linux/x64/release/bundle/. "$PACKAGE/"
cp "$ROOT/tool/install-linux.sh" "$PACKAGE/install.sh"
chmod +x "$PACKAGE/install.sh"
tar -C "$TEMP" -czf "$OUTPUT/aerodrop-linux-x64.tar.gz" aerodrop
cp build/app/outputs/flutter-apk/app-release.apk "$OUTPUT/aerodrop-android.apk"
(
  cd "$OUTPUT"
  sha256sum aerodrop-linux-x64.tar.gz aerodrop-android.apk > SHA256SUMS
)
echo "Build artifacts: $OUTPUT"
