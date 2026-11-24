#!/usr/bin/env bash
# =============================================================================
#  VPN app builder (RocketMM engine) — all-in-one for macOS (also works on Linux
#  with an Android SDK / JDK 17 / Go already installed, e.g. CI).
#
#  What it does:
#    1. installs the build tools (JDK 17, Go, Android SDK) with Homebrew
#    2. downloads/updates the app source (private GitHub repo, via `gh`)
#    3. asks for your brand (name, logo, backend, Telegram) — saved for next time
#    4. creates the signing key (once per brand — BACK IT UP)
#    5. builds the signed release APK
#    6. optionally publishes it to a public GitHub repo so apps get the in-app update popup
#
#  Usage:   bash vpn-builder.sh                 (new brand or pick an existing one)
#           bash vpn-builder.sh "Thunder VPN"   (rebuild that brand with its saved settings)
#  Brands live in ~/VPNBuilder/<brand>/  (settings, signing key, APKs).
#  Compatible with macOS's bash 3.2.
# =============================================================================
set -euo pipefail

REPO="${VPN_REPO:-neymaruu123-gif/GreenVPN}"
BRANCH="${VPN_BRANCH:-ui/connect-page}"
HOME_DIR="${VPN_BUILDER_HOME:-$HOME/VPNBuilder}"
SRC="$HOME_DIR/source"
DEFAULT_BACKEND="https://yethiha101.dpdns.org"
DEFAULT_KEY="4PBtsHiTK/11J++++78D2Ts8AQvcIH2p4JKy2qDDXeI="   # public key of the default backend
OS="$(uname -s)"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '\033[32m✔ %s\033[0m\n' "$*"; }
warn() { printf '\033[33m! %s\033[0m\n' "$*"; }
die()  { printf '\033[31m✘ %s\033[0m\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1;35m==> %s\033[0m\n' "$*"; }
ask() { # ask VAR "Question" "default"
  local __v="$1" __q="$2" __d="${3:-}" __a
  if [ -n "$__d" ]; then read -r -p "$__q [$__d]: " __a; else read -r -p "$__q: " __a; fi
  [ -z "$__a" ] && __a="$__d"
  eval "$__v=\$__a"
}
slugify() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-*//; s/-*$//'; }

# ----------------------------------------------------------------------------- 1. tools
setup_tools() {
  step "1/6  Build tools"
  if [ "$OS" = "Darwin" ]; then
    command -v brew >/dev/null || die "Homebrew is not installed. Install it first:  /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
    local pkgs="" p
    for p in openjdk@17 go gh git jq; do brew list --versions "$p" >/dev/null 2>&1 || pkgs="$pkgs $p"; done
    [ -n "$pkgs" ] && { bold "Installing:$pkgs"; brew install $pkgs; }
    brew list --cask android-commandlinetools >/dev/null 2>&1 || brew install --cask android-commandlinetools
    export JAVA_HOME="$(brew --prefix openjdk@17)/libexec/openjdk.jdk/Contents/Home"
    export ANDROID_HOME="$(brew --prefix)/share/android-commandlinetools"
    export PATH="$JAVA_HOME/bin:$(brew --prefix go)/bin:$PATH"
    local sdkm="$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager"
    [ -x "$sdkm" ] || sdkm="$(command -v sdkmanager)"
    if [ ! -d "$ANDROID_HOME/platforms/android-36" ] || [ ! -d "$ANDROID_HOME/build-tools/36.0.0" ]; then
      bold "Installing Android SDK 36 (one time, ~1 GB)…"
      yes | "$sdkm" --sdk_root="$ANDROID_HOME" --licenses >/dev/null 2>&1 || true
      "$sdkm" --sdk_root="$ANDROID_HOME" "platforms;android-36" "build-tools;36.0.0" "platform-tools" >/dev/null
    fi
  else
    : "${ANDROID_HOME:=${ANDROID_SDK_ROOT:-}}"
    [ -n "$ANDROID_HOME" ] || die "Set ANDROID_HOME to your Android SDK"
    export ANDROID_HOME
  fi
  export GOTOOLCHAIN=auto
  command -v java >/dev/null || die "Java 17 not found"
  command -v go >/dev/null || die "Go not found"
  command -v keytool >/dev/null || die "keytool (JDK) not found"
  ok "Java $(java -version 2>&1 | head -1 | cut -d'"' -f2), $(go version | cut -d' ' -f3), Android SDK at $ANDROID_HOME"
}

# ----------------------------------------------------------------------------- 2. source
get_source() {
  step "2/6  App source ($REPO, $BRANCH)"
  mkdir -p "$HOME_DIR"
  if [ -n "${VPN_SOURCE_DIR:-}" ]; then SRC="$VPN_SOURCE_DIR"; ok "Using $SRC"; return; fi
  if [ -d "$SRC/.git" ]; then
    git -C "$SRC" fetch -q origin "$BRANCH"
    git -C "$SRC" checkout -q -B "$BRANCH" "origin/$BRANCH"
    git -C "$SRC" reset -q --hard "origin/$BRANCH"
  else
    command -v gh >/dev/null || die "GitHub CLI (gh) missing"
    gh auth status >/dev/null 2>&1 || die "Log in to GitHub first:  gh auth login"
    gh repo clone "$REPO" "$SRC" -- -q -b "$BRANCH" || die "Could not download $REPO (is this GitHub account allowed to see it?)"
  fi
  git -C "$SRC" clean -qfd   # drop the previous brand's files (keeps build caches)
  ok "Source at $(git -C "$SRC" log -1 --format='%h %s' | cut -c1-70)"
}

# ----------------------------------------------------------------------------- 3. brand
choose_brand() {
  step "3/6  Brand"
  local name="${1:-}"
  if [ -z "$name" ] && [ -d "$HOME_DIR/brands" ] && [ -n "$(ls -A "$HOME_DIR/brands" 2>/dev/null)" ]; then
    echo "Saved brands:"; ls -1 "$HOME_DIR/brands" | sed 's/^/  - /'
    ask name "Brand name to rebuild, or a NEW name" ""
  fi
  [ -z "$name" ] && ask name "App name (e.g. Thunder VPN)" ""
  [ -n "$name" ] || die "An app name is needed"
  SLUG="$(slugify "$name")"
  BRAND_DIR="$HOME_DIR/brands/$SLUG"
  CONF="$BRAND_DIR/brand.conf"
  mkdir -p "$BRAND_DIR/out"
  if [ -f "$CONF" ]; then
    # shellcheck disable=SC1090
    . "$CONF"
    bold "Using saved settings for \"$APP_NAME\" ($CONF)"
    local again; ask again "Change any settings? (y/N)" "N"
    case "$again" in y|Y) edit_brand "$APP_NAME" ;; esac
  else
    edit_brand "$name"
  fi
}

edit_brand() {
  APP_NAME="$1"
  ask APP_NAME "App name" "$APP_NAME"
  local guess; guess="com.$(printf '%s' "$SLUG" | tr -d '-' | cut -c1-20).vpn"
  ask APP_ID "Package id (unique, never change it later)" "${APP_ID:-$guess}"
  printf '%s' "$APP_ID" | grep -Eq '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$' || die "Package id must look like com.brand.vpn (lowercase)"
  ask LOGO "Logo PNG (drag the file here; empty = keep the rocket)" "${LOGO:-}"
  LOGO="$(printf '%s' "$LOGO" | sed "s/^'//; s/'$//; s/\\\\ / /g")"
  if [ -n "$LOGO" ]; then
    [ -f "$LOGO" ] || die "Logo file not found: $LOGO"
    ask LOGO_STYLE "Logo style: 1 = logo on a colour background, 2 = logo fills the whole icon" "${LOGO_STYLE:-1}"
    ask ICON_BG "Icon background colour (hex)" "${ICON_BG:-#2E1065}"
  fi
  ask BACKEND_URL "Backend / dashboard URL" "${BACKEND_URL:-$DEFAULT_BACKEND}"
  BACKEND_URL="${BACKEND_URL%/}"
  ask VIP_URL "Telegram link for buying VIP" "${VIP_URL:-https://t.me/}"
  ask PUBLISH "Publish updates to GitHub (in-app update popup)? (y/n)" "${PUBLISH:-y}"
  if [ "$PUBLISH" = "y" ] || [ "$PUBLISH" = "Y" ]; then
    ask RELEASE_REPO "Public GitHub repo for releases" "${RELEASE_REPO:-$SLUG-releases}"
  fi
  VERSION_NAME="${VERSION_NAME:-1.0.0}"
  ask VERSION_NAME "Version name" "$VERSION_NAME"
  BUILD_NO="${BUILD_NO:-0}"
  save_conf
}

save_conf() {
  {
    printf 'APP_NAME=%q\nAPP_ID=%q\nLOGO=%q\nLOGO_STYLE=%q\nICON_BG=%q\n' "$APP_NAME" "$APP_ID" "${LOGO:-}" "${LOGO_STYLE:-1}" "${ICON_BG:-#2E1065}"
    printf 'BACKEND_URL=%q\nVIP_URL=%q\nPUBLISH=%q\nRELEASE_REPO=%q\nVERSION_NAME=%q\nBUILD_NO=%q\n' \
      "$BACKEND_URL" "$VIP_URL" "${PUBLISH:-n}" "${RELEASE_REPO:-}" "$VERSION_NAME" "$BUILD_NO"
  } > "$CONF"
}

# ----------------------------------------------------------------------------- 4. key
signing_key() {
  step "4/6  Signing key"
  KEYSTORE="$BRAND_DIR/release.p12"
  if [ ! -f "$KEYSTORE" ]; then
    local pass; pass="BR$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"
    keytool -genkeypair -keystore "$KEYSTORE" -storetype PKCS12 -alias app -keyalg EC -groupname secp256r1 \
      -validity 10000 -dname "CN=$APP_NAME" -storepass "$pass" -keypass "$pass" >/dev/null 2>&1
    printf '%s\n' "$pass" > "$BRAND_DIR/release.password"
    chmod 600 "$KEYSTORE" "$BRAND_DIR/release.password"
    warn "NEW signing key: $KEYSTORE (password in release.password)."
    warn "BACK UP BOTH FILES NOW (e.g. Google Drive). Without them you can never update this app again."
  else
    ok "Using $KEYSTORE"
  fi
  KEYPASS="$(cat "$BRAND_DIR/release.password")"
}

# ----------------------------------------------------------------------------- 5. build
apply_brand() {
  local res="$SRC/android/app/src/main/res"
  if [ -n "${LOGO:-}" ]; then
    mkdir -p "$res/drawable-nodpi"
    rm -f "$res/drawable/brand_logo.xml"
    if command -v sips >/dev/null; then sips -s format png -Z 512 "$LOGO" --out "$res/drawable-nodpi/brand_logo.png" >/dev/null
    else cp "$LOGO" "$res/drawable-nodpi/brand_logo.png"; fi
    local inset="20%"; [ "${LOGO_STYLE:-1}" = "2" ] && inset="0%"
    cat > "$res/drawable/ic_launcher_foreground.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<inset xmlns:android="http://schemas.android.com/apk/res/android" android:drawable="@drawable/brand_logo" android:inset="$inset" />
EOF
    cat > "$res/drawable/ic_launcher_background.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<shape xmlns:android="http://schemas.android.com/apk/res/android" android:shape="rectangle">
    <solid android:color="${ICON_BG:-#2E1065}" />
</shape>
EOF
    BRAND_LOGO=true
  else
    BRAND_LOGO=false
  fi
  printf 'storeFile=%s\nstorePassword=%s\nkeyAlias=app\nkeyPassword=%s\n' "$KEYSTORE" "$KEYPASS" "$KEYPASS" > "$SRC/android/keystore.properties"
  printf 'sdk.dir=%s\n' "$ANDROID_HOME" > "$SRC/android/local.properties"
}

manifest_key() {
  local k
  k="$(curl -fsS --max-time 15 "$BACKEND_URL/api/v1/servers/signing-key" 2>/dev/null | sed -n 's/.*"publicKey":"\([^"]*\)".*/\1/p' || true)"
  if [ -z "$k" ] && [ "$BACKEND_URL" = "$DEFAULT_BACKEND" ]; then k="$DEFAULT_KEY"; fi
  if [ -z "$k" ]; then
    warn "Could not read the server-list signing key from $BACKEND_URL (update the backend, or paste it:"
    warn "dashboard → Publish page shows it, or ask Claude)."
    ask k "Manifest public key (base64)" ""
  fi
  [ -n "$k" ] || die "The app needs the backend's public key to trust its server list"
  MANIFEST_KEY="$k"
}

build_apk() {
  step "5/6  Building $APP_NAME"
  manifest_key
  BUILD_NO=$((BUILD_NO + 1)); save_conf
  local code=$((1000 + BUILD_NO))
  UPDATE_URL=""
  if [ "${PUBLISH:-n}" = "y" ] || [ "${PUBLISH:-n}" = "Y" ]; then
    GH_USER="$(gh api user -q .login)"
    UPDATE_URL="https://raw.githubusercontent.com/$GH_USER/$RELEASE_REPO/main/latest.json"
  fi
  apply_brand
  (cd "$SRC/android" && ./gradlew --no-daemon --console=plain :app:assembleRelease \
      -PappId="$APP_ID" -PappName="$APP_NAME" -PbrandLogo="$BRAND_LOGO" \
      -PbackendUrl="$BACKEND_URL" -PmanifestPublicKey="$MANIFEST_KEY" -PvipContactUrl="$VIP_URL" \
      -PupdateUrl="$UPDATE_URL" -PversionNameOverride="$VERSION_NAME" -PversionCodeOverride="$code")
  rm -f "$SRC/android/keystore.properties"
  APK_NAME="$(printf '%s' "$APP_NAME" | tr -cd 'A-Za-z0-9')-$VERSION_NAME-$code.apk"
  APK="$BRAND_DIR/out/$APK_NAME"
  cp "$SRC/android/app/build/outputs/apk/release/app-release.apk" "$APK"
  SHA="$(shasum -a 256 "$APK" 2>/dev/null | cut -d' ' -f1 || sha256sum "$APK" | cut -d' ' -f1)"
  CODE="$code"
  ok "APK: $APK ($(du -h "$APK" | cut -f1))"
}

# ----------------------------------------------------------------------------- 6. publish
publish() {
  step "6/6  Publish"
  if [ "${PUBLISH:-n}" != "y" ] && [ "${PUBLISH:-n}" != "Y" ]; then ok "Skipped (send the APK file yourself)"; return; fi
  local dir="$BRAND_DIR/releases-repo" url="https://raw.githubusercontent.com/$GH_USER/$RELEASE_REPO/main/$APK_NAME"
  if ! gh repo view "$GH_USER/$RELEASE_REPO" >/dev/null 2>&1; then
    gh repo create "$GH_USER/$RELEASE_REPO" --public -d "$APP_NAME downloads" >/dev/null
    ok "Created public repo $GH_USER/$RELEASE_REPO"
  fi
  if [ -d "$dir/.git" ]; then git -C "$dir" pull -q || true
  else
    rm -rf "$dir"; gh repo clone "$GH_USER/$RELEASE_REPO" "$dir" -- -q 2>/dev/null || { mkdir -p "$dir"; git -C "$dir" init -q -b main; git -C "$dir" remote add origin "https://github.com/$GH_USER/$RELEASE_REPO.git"; }
  fi
  (cd "$dir" && git rm -q --ignore-unmatch ./*.apk >/dev/null 2>&1 || true)
  cp "$APK" "$dir/"
  cat > "$dir/latest.json" <<EOF
{
  "versionCode": $CODE,
  "versionName": "$VERSION_NAME ($CODE)",
  "apkUrl": "$url",
  "sha256": "$SHA",
  "notes": "",
  "mandatory": false
}
EOF
  (cd "$dir" && git add -A && git -c user.name="$GH_USER" -c user.email="$GH_USER@users.noreply.github.com" commit -q -m "$APP_NAME $VERSION_NAME ($CODE)" && git push -q -u origin HEAD:main)
  ok "Published. Download link:"
  echo "    $url"
}

main() {
  bold "VPN app builder"
  setup_tools
  get_source
  choose_brand "${1:-}"
  signing_key
  build_apk
  publish
  echo
  bold "Done: $APP_NAME $VERSION_NAME (build $CODE)"
  echo "  APK:          $APK"
  echo "  Settings:     $CONF"
  echo "  Signing key:  $KEYSTORE  (+ release.password)  ← keep a backup!"
  echo "  Rebuild:      bash $0 \"$APP_NAME\""
}
main "$@"
