#!/usr/bin/env bash
set -euo pipefail

OWNER="LizcanOskr"
REPO="AeroDrop"
API="https://api.github.com/repos/$OWNER/$REPO/releases/latest"
DEST="$HOME/.local/opt/aerodrop"
BIN="$HOME/.local/bin"
APPS="$HOME/.local/share/applications"

for command in curl tar sha256sum; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "Missing required installer tool: $command" >&2
    exit 1
  fi
done

ARCH="$(uname -m)"
if [[ "$ARCH" != "x86_64" ]]; then
  echo "This beta currently provides Linux builds for x86_64, not $ARCH." >&2
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
RELEASE_JSON="$TMP/release.json"
curl -fsSL "$API" -o "$RELEASE_JSON"
ASSET_URL="$(python3 - "$RELEASE_JSON" <<'PY'
import json, sys
release = json.load(open(sys.argv[1], encoding="utf-8"))
for asset in release.get("assets", []):
    if asset["name"] == "aerodrop-linux-x64.tar.gz":
        print(asset["browser_download_url"])
        break
else:
    raise SystemExit("Latest release has no Linux x86_64 archive")
PY
)"
CHECKSUM_URL="$(python3 - "$RELEASE_JSON" <<'PY'
import json, sys
release = json.load(open(sys.argv[1], encoding="utf-8"))
for asset in release.get("assets", []):
    if asset["name"] == "SHA256SUMS":
        print(asset["browser_download_url"])
        break
else:
    raise SystemExit("Latest release has no SHA256SUMS file")
PY
)"
curl -fsSL "$ASSET_URL" -o "$TMP/aerodrop-linux-x64.tar.gz"
curl -fsSL "$CHECKSUM_URL" -o "$TMP/SHA256SUMS"
(cd "$TMP" && grep ' aerodrop-linux-x64.tar.gz$' SHA256SUMS | sha256sum -c -)
tar -xzf "$TMP/aerodrop-linux-x64.tar.gz" -C "$TMP"

APP="$TMP/aerodrop/aerodrop"
if [[ ! -x "$APP" ]]; then
  echo "The release archive does not contain an executable AeroDrop app." >&2
  exit 1
fi

MISSING="$(ldd "$APP" | sed -n 's/.*=> not found.*/&/p')"
if [[ -n "$MISSING" ]]; then
  echo "AeroDrop is missing Linux runtime libraries:"
  printf '%s\n' "$MISSING"
  echo
  if command -v dnf >/dev/null 2>&1; then
    MANAGER="dnf"
    PACKAGES=(gtk3 glib2 libstdc++ libgcc mesa-libGL)
  elif command -v apt-get >/dev/null 2>&1; then
    MANAGER="apt-get"
    PACKAGES=(libgtk-3-0 libglib2.0-0 libstdc++6 libgcc-s1 libgl1)
  elif command -v pacman >/dev/null 2>&1; then
    MANAGER="pacman"
    PACKAGES=(gtk3 glib2 gcc-libs mesa)
  elif command -v zypper >/dev/null 2>&1; then
    MANAGER="zypper"
    PACKAGES=(gtk3 glib2 libstdc++6 libgcc_s1 Mesa-libGL1)
  else
    echo "No supported package manager found. Install the listed runtime libraries and retry." >&2
    exit 1
  fi
  read -r -p "Install the runtime dependencies using $MANAGER? [y/N] " ANSWER
  if [[ ! "$ANSWER" =~ ^[Yy]$ ]]; then
    echo "Installation cancelled; no system packages were changed." >&2
    exit 1
  fi
  case "$MANAGER" in
    dnf) sudo dnf install -y "${PACKAGES[@]}" ;;
    apt-get) sudo apt-get update && sudo apt-get install -y "${PACKAGES[@]}" ;;
    pacman) sudo pacman -S --needed --noconfirm "${PACKAGES[@]}" ;;
    zypper) sudo zypper --non-interactive install "${PACKAGES[@]}" ;;
  esac
  MISSING="$(ldd "$APP" | sed -n 's/.*=> not found.*/&/p')"
  if [[ -n "$MISSING" ]]; then
    echo "Some runtime libraries are still unavailable:" >&2
    printf '%s\n' "$MISSING" >&2
    exit 1
  fi
fi

mkdir -p "$(dirname "$DEST")" "$BIN" "$APPS"
mkdir -p "$DEST"
cp -a "$TMP/aerodrop/." "$DEST/"
cat > "$BIN/aerodrop" <<EOF
#!/usr/bin/env bash
exec "$DEST/aerodrop" "\$@"
EOF
chmod +x "$BIN/aerodrop"
cat > "$APPS/aerodrop.desktop" <<EOF
[Desktop Entry]
Name=AeroDrop
Comment=Nearby file sharing
Exec=$BIN/aerodrop
Terminal=false
Type=Application
Categories=Network;FileTransfer;
EOF
echo "AeroDrop installed. Launch it from your application menu or run: $BIN/aerodrop"
