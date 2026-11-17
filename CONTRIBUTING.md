# Contributing

## Development setup

Install Flutter stable and run:

```sh
tool/build.sh
```

The script creates a temporary Flutter project, overlays `app/`, and builds the Linux bundle and Android APK. To iterate interactively, create a platform project with:

```sh
flutter create --platforms=linux,android --org io.github.lizcanoskr --project-name aerodrop /tmp/aerodrop-dev
cp app/pubspec.yaml app/analysis_options.yaml /tmp/aerodrop-dev/
cp -R app/lib /tmp/aerodrop-dev/
python3 tool/configure_android.py \
  /tmp/aerodrop-dev/android/app/src/main/AndroidManifest.xml /tmp/aerodrop-dev
cd /tmp/aerodrop-dev && flutter pub get
```

## Beta roadmap

- Encrypt transfers and authenticate paired devices.
- Add Bluetooth-assisted discovery and improve discovery across Wi-Fi access points.
- Add a user-granted folder browser without publishing directories as network shares.
- Add share-sheet integration on Android and file-manager integration on Linux.
- Support resumable transfers and background receiving.

Security issues should be reported privately through GitHub's security advisory feature, not in public issue reports.
