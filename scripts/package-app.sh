#!/usr/bin/env bash
# Assemble dist/OpenRecord.app from `swift build` and codesign with a local
# "OpenRecord Dev" identity. Never uses xcodebuild.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CONFIGURATION="${CONFIGURATION:-release}"
ARCH="${ARCH:-arm64}"
IDENTITY="${CODESIGN_IDENTITY:-OpenRecord Dev}"
APP="$ROOT/dist/OpenRecord.app"
ENTITLEMENTS="$ROOT/Resources/OpenRecord.entitlements"
INFO_PLIST="$ROOT/Resources/Info.plist"
BUNDLE_ID="app.openrecord.desktop"

login_keychain() {
  if [[ -f "$HOME/Library/Keychains/login.keychain-db" ]]; then
    echo "$HOME/Library/Keychains/login.keychain-db"
  else
    echo "$HOME/Library/Keychains/login.keychain"
  fi
}

identity_installed() {
  security find-identity -p codesigning 2>/dev/null | grep -F "$IDENTITY" >/dev/null
}

ensure_codesign_identity() {
  if identity_installed; then
    echo "Using existing codesign identity: $IDENTITY"
    return
  fi

  echo "Creating local self-signed codesign certificate: $IDENTITY"
  local tmp
  tmp="$(mktemp -d /tmp/openrecord-codesign.XXXXXX)"
  umask 077

  cat > "$tmp/cert.cnf" <<EOF
[req]
distinguished_name = req_distinguished_name
x509_extensions = v3_ext
prompt = no

[req_distinguished_name]
CN = ${IDENTITY}
O = OpenRecord

[v3_ext]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

  openssl req -new -x509 -days 3650 -nodes -newkey rsa:2048 \
    -keyout "$tmp/key.pem" -out "$tmp/cert.pem" \
    -config "$tmp/cert.cnf" -extensions v3_ext

  # macOS `security import` still expects legacy PKCS#12 (3DES/RC2/SHA1).
  # Homebrew OpenSSL 3 defaults to AES-256/SHA256, which fails with
  # "MAC verification failed during PKCS12 import".
  local p12_ok=0
  if openssl pkcs12 -help 2>&1 | grep -q -- '-legacy'; then
    openssl pkcs12 -export -legacy \
      -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
      -out "$tmp/cert.p12" -passout pass:openrecord \
      -name "$IDENTITY" && p12_ok=1
  fi
  if [[ "$p12_ok" -ne 1 ]]; then
    /usr/bin/openssl pkcs12 -export \
      -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
      -out "$tmp/cert.p12" -passout pass:openrecord \
      -name "$IDENTITY" && p12_ok=1
  fi
  if [[ "$p12_ok" -ne 1 ]]; then
    echo "warning: could not create a PKCS#12 identity; will ad-hoc sign" >&2
    rm -rf "$tmp"
    return 0
  fi

  local keychain
  keychain="$(login_keychain)"

  if ! security import "$tmp/cert.p12" -k "$keychain" \
    -P openrecord -A \
    -T /usr/bin/codesign -T /usr/bin/security >/dev/null; then
    echo "warning: could not import '$IDENTITY' into the login keychain" >&2
    rm -rf "$tmp"
    return 0
  fi

  # Best-effort: let codesign use the key without a prompt on later runs.
  # May fail if the login keychain is locked or has a non-empty password;
  # the user can click Allow on the Keychain dialog instead.
  security set-key-partition-list \
    -S apple-tool:,apple:,codesign: -s -k "" "$keychain" >/dev/null 2>&1 || true

  rm -rf "$tmp"

  if ! identity_installed; then
    echo "warning: imported '$IDENTITY' but it is not yet visible to codesign" >&2
  fi
}

sign_app() {
  local app="$1"
  if codesign --force --sign "$IDENTITY" \
    --entitlements "$ENTITLEMENTS" \
    --identifier "$BUNDLE_ID" \
    --timestamp=none \
    "$app"; then
    return
  fi

  echo "warning: codesign with '$IDENTITY' failed; falling back to ad-hoc signing" >&2
  echo "warning: TCC grants may reset on every rebuild until '$IDENTITY' works" >&2
  codesign --force --sign - \
    --entitlements "$ENTITLEMENTS" \
    --identifier "$BUNDLE_ID" \
    "$app"
}

echo "Building OpenRecord ($CONFIGURATION, $ARCH)…"
swift build -c "$CONFIGURATION" --arch "$ARCH"

BIN_DIR="$(swift build -c "$CONFIGURATION" --arch "$ARCH" --show-bin-path)"
# Product name is OpenRecord; executable target is OpenRecordApp (library holds contracts).
BIN=""
for candidate in OpenRecord OpenRecordApp; do
  if [[ -x "$BIN_DIR/$candidate" ]]; then
    BIN="$BIN_DIR/$candidate"
    break
  fi
done

if [[ -z "$BIN" ]]; then
  echo "error: expected OpenRecord binary under $BIN_DIR" >&2
  exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/OpenRecord"
chmod +x "$APP/Contents/MacOS/OpenRecord"
cp "$INFO_PLIST" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

ensure_codesign_identity
sign_app "$APP"

echo "Built $APP"
codesign --verify --verbose=2 "$APP" 2>&1 | sed 's/^/  /' || true
