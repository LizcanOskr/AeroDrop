# AeroDrop

AeroDrop is an experimental, open-source file-transfer app for Linux and Android. It is intended to make nearby sharing feel simple: open the app on both devices, select a nearby receiver, and approve the incoming transfer.

## Beta status

This is an early beta. Devices discover one another over the local Wi-Fi network. The current transfer transport is **not encrypted** and should only be used on a trusted network with non-sensitive files. Keep AeroDrop open while receiving. Do not expose its receive port to the internet.

The beta transfers individual files only. Browsing selected folders, Bluetooth proximity discovery, background receiving, and encrypted pairing are not implemented yet.

## Install

Download the latest release from [GitHub Releases](https://github.com/LizcanOskr/AeroDrop/releases).

- **Linux x86_64:** download `aerodrop-linux-x64.tar.gz` and run the included installer:

  ```sh
  tar -xzf aerodrop-linux-x64.tar.gz
  ./aerodrop/install.sh
  ```

  The installer checks for missing runtime libraries and, only after confirmation, uses the detected system package manager to install them. It installs AeroDrop under `~/.local/opt` and adds a desktop launcher.
- **Android:** download `aerodrop-android.apk`, open it, and approve Android's standard installation prompt. Android may ask you to allow installs from the app used to open the APK.

The Linux install script downloads the latest public release directly from this repository and verifies its SHA-256 checksum. It does not need root privileges to install AeroDrop itself.

## Build from source

Requirements: Flutter stable, Android SDK (for Android builds), and the Linux Flutter build dependencies (`clang`, `cmake`, `ninja`, `pkg-config`, GTK 3 development files).

```sh
tool/build.sh
```

Artifacts are written to `build/dist/`. The build helper generates the Flutter platform scaffolding in a temporary directory, so generated Android/Linux project files are not maintained by hand.

## Use

1. Connect both devices to the same Wi-Fi network.
2. Open AeroDrop on both devices.
3. On the receiving device, turn on **Ready to receive** and share the displayed six-digit code with the sender.
4. On the sending device, select the receiver, enter the code, choose a file, and send it.
5. Accept or reject the transfer on the receiving device.

Incoming files are saved in AeroDrop's application documents directory. The receiver has to keep the app open.

## Privacy and security

AeroDrop currently advertises its name and receive port over the local network while receiving is enabled. File contents and the six-digit transfer code travel over plain HTTP in this beta. The code is a basic access check, not encryption. Use only a trusted Wi-Fi network and do not send private or sensitive files until encrypted transport and authenticated pairing are implemented.

## Development

See [CONTRIBUTING.md](CONTRIBUTING.md) for the development setup and beta roadmap. Report bugs through [GitHub Issues](https://github.com/LizcanOskr/AeroDrop/issues).
