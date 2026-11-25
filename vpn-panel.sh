#!/usr/bin/env bash
# =============================================================================
#  All-in-one VPN server installer (Ubuntu 22.04 / 24.04, Debian 12)
#
#  One run on a fresh VPS sets up, under YOUR VPN's name and YOUR domains:
#    - the admin panel (servers, VIP codes, free plan, popup message, app updates, backups)
#    - V2ray: VLESS + VMess over WebSocket on 443 (TLS) and 80 — on the CDN domain (Cloudflare ok)
#    - SSH: WebSocket payload on 443 (TLS) and 80, plain SSH on 22, and a payload proxy on 8080
#    - adds all of these to the panel and publishes them to the app
#    - builds your Android app on YOUR GitHub (private repo) and hosts it at https://<panel>/download/
#    - nightly encrypted backups (signing key, settings, database): panel → Backup, and Telegram
#
#  Run as root:   bash vpn-panel.sh            (asks a few questions)
#  Re-run it later to update; your data, keys and settings are kept.
#  Non-interactive (tests): VPN_NAME, PANEL_DOMAIN, VPN_DOMAIN, ADMIN_EMAIL, VIP_URL or TG_USER, COUNTRY,
#  LOGO, GH_REPO, GITHUB_TOKEN, TG_BOT, BUNDLE_KEY (or BUNDLE_FILE + IMAGE_FILE), CADDY_TLS, VPN_TLS,
#  ASSUME_YES=1.
# =============================================================================
set -euo pipefail

CONF=/etc/vpn-panel.conf
BUNDLE_URL=${BUNDLE_URL:-https://raw.githubusercontent.com/neymaruu123-gif/rocketmm-releases/main/backend-bundle.enc}
IMAGE_BASE=${IMAGE_BASE:-https://raw.githubusercontent.com/neymaruu123-gif/rocketmm-releases/backend-image}
APP_REPO=${APP_REPO:-neymaruu123-gif/GreenVPN}
APP_REF=${APP_REF:-ui/connect-page}
API_PORT=${API_PORT:-18080}
INSTALLER_URL=${INSTALLER_URL:-https://raw.githubusercontent.com/neymaruu123-gif/rocketmm-releases/main/vpn-panel.sh}

say()  { printf '\n\033[1;35m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[32m✔ %s\033[0m\n' "$*"; }
warn() { printf '\033[33m! %s\033[0m\n' "$*"; }
fail() { printf '\n\033[31m✘ %s\033[0m\n' "$*" >&2; exit 1; }
tty_ok() { [ -z "${ASSUME_YES:-}" ] && [ -r /dev/tty ]; }
ask() { # ask VAR "question" [default]   (env value wins; reads the terminal even when piped)
  local __v="$1" __q="$2" __d="${3:-}" __a=""
  if [ -n "${!__v:-}" ]; then return; fi
  if tty_ok; then
    if [ -n "$__d" ]; then read -r -p "$__q [$__d]: " __a </dev/tty; else read -r -p "$__q: " __a </dev/tty; fi
  fi
  [ -z "$__a" ] && __a="$__d"
  printf -v "$__v" '%s' "$__a"
}
yesno() { local a=""; if tty_ok; then read -r -p "$1 (y/N): " a </dev/tty; else a="${ASSUME_YES:+y}"; fi; [ "$a" = y ] || [ "$a" = Y ]; }
hint() { tty_ok || return 0; printf '\033[2m'; printf '   %s\n' "$@"; printf '\033[0m'; } # grey help lines under a question
norm_domain() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's#^https\?://##; s#/.*$##; s/ //g'; }
is_domain() { printf '%s' "$1" | grep -Eq '^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$|^([a-z0-9-]+\.)*localhost$'; }
rand() { openssl rand -hex 32 | cut -c1-"$1"; }
slugify() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9'; }

[ "$(id -u)" = 0 ] || fail "Run as root (sudo -i first)."
# read the distro in a subshell: os-release also sets LOGO, NAME, VERSION… which must not leak into our settings
OS_ID="$( . /etc/os-release 2>/dev/null; echo "${ID:-}")"; OS_NAME="$( . /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}")"
case "$OS_ID" in ubuntu|debian) ;; *) fail "Ubuntu or Debian is required (found: $OS_NAME)." ;; esac
export DEBIAN_FRONTEND=noninteractive
command -v curl >/dev/null && command -v openssl >/dev/null && command -v jq >/dev/null || {
  apt-get update -qq && apt-get install -y -qq curl openssl jq ca-certificates unzip >/dev/null; }
command -v unzip >/dev/null || apt-get install -y -qq unzip >/dev/null
command -v git >/dev/null || apt-get install -y -qq git >/dev/null

# ----------------------------------------------------------------------------- settings
UPDATE=0
if [ -f "$CONF" ]; then
  # shellcheck disable=SC1090
  . "$CONF"; UPDATE=1
  # shellcheck disable=SC1091
  . "$DIR/settings.env"
  say "Updating $VPN_NAME (settings kept in $DIR)"
else
  printf '\n\033[1mVPN server setup\033[0m — answer a few questions, the rest is automatic.\n\n'
  hint "The name of your app, panel and server commands."
  ask VPN_NAME "1. VPN app name (e.g. Light VPN)"
  VPN_NAME="$(printf '%s' "$VPN_NAME" | tr -d '"\\$`' | sed 's/^ *//; s/ *$//')"
  [ -n "$VPN_NAME" ] || fail "A name is needed."
  SLUG="$(slugify "$VPN_NAME")"; [ -n "$SLUG" ] || fail "The name needs at least one letter or digit."
  case "$SLUG" in [a-z]*) ;; *) SLUG="vpn$SLUG" ;; esac
  SLUG="$(printf '%s' "$SLUG" | cut -c1-24)"
  if [ -z "${VIP_URL:-}" ]; then
    hint "Users buy VIP and get help here (shown in the app and on the privacy page)." "Your username only, e.g. johnterryh"
    ask TG_USER "2. Telegram username"
    TG_USER="$(printf '%s' "$TG_USER" | sed 's#^https\?://##; s#^t\.me/##; s#^@##; s#/.*$##' | tr -cd 'A-Za-z0-9_')"
    [ -n "$TG_USER" ] && VIP_URL="https://t.me/$TG_USER" || VIP_URL=""
  fi
  VIP_URL="$(printf '%s' "$VIP_URL" | sed 's#t\.me/@#t.me/#')"
  hint "You log in to the admin panel with it (the password is made for you)."
  ask ADMIN_EMAIL "3. Admin login email"
  printf '%s' "$ADMIN_EMAIL" | grep -Eq '^[^@ ]+@[^@ ]+\.[^@ ]+$' || fail "\"$ADMIN_EMAIL\" is not an email address."
  hint "Admin panel + app API. In Cloudflare → DNS → Add record:" \
       "Type A · Name: panel · IPv4: this server's IP · Proxy status: DNS only (grey cloud)"
  ask PANEL_DOMAIN "4. Admin panel subdomain (e.g. panel.example.com)"
  PANEL_DOMAIN="$(norm_domain "$PANEL_DOMAIN")"
  is_domain "$PANEL_DOMAIN" || fail "\"$PANEL_DOMAIN\" is not a domain name."
  hint "VPN servers (VLESS / VMess / SSH WebSocket). Cloudflare → DNS → Add record:" \
       "Type A · IPv4: this server's IP · Proxy status: Proxied (orange cloud)" \
       "and Cloudflare → SSL/TLS → mode: Full.   Press Enter to use the panel domain for the VPN too."
  ask VPN_DOMAIN "5. VPN (CDN) domain (e.g. vpn.example.com)" "$PANEL_DOMAIN"
  VPN_DOMAIN="$(norm_domain "$VPN_DOMAIN")"
  is_domain "$VPN_DOMAIN" || fail "\"$VPN_DOMAIN\" is not a domain name."
  guess="$(curl -fsS --max-time 5 https://ipinfo.io/country 2>/dev/null | tr -cd 'A-Z' | cut -c1-2 || true)"
  COUNTRY="${COUNTRY:-${guess:-SG}}"
  COUNTRY="$(printf '%s' "$COUNTRY" | tr '[:lower:]' '[:upper:]' | tr -cd 'A-Z' | cut -c1-2)"
  if [ -z "${LOGO+x}" ]; then
    hint "1 = default icon" "2 = your own logo: a PNG link (https://…, e.g. from Telegram / Google Drive / imgur), best 1024×1024"
    ask LOGO_CHOICE "6. App logo (1 or 2)" "1"
    LOGO=""
    if [ "$LOGO_CHOICE" = 2 ]; then ask LOGO "   Logo PNG link (https://…)"; fi
  fi
  if [ -z "${GH_REPO+x}" ]; then
    hint "Your Android app is built on YOUR GitHub, in an empty PRIVATE repository:" \
         "→ https://github.com/new  ·  Repository name: $(slugify "$VPN_NAME")-app  ·  Private  ·  Create repository" \
         "Then type it here as  your-github-name/$(slugify "$VPN_NAME")-app      (Enter = skip, build later)"
    ask GH_REPO "7. GitHub repository"
  fi
  GH_REPO="$(printf '%s' "${GH_REPO:-}" | sed 's#^https\?://github\.com/##; s#\.git$##; s#/$##' | tr -d ' ')"
  if [ -n "$GH_REPO" ]; then
    printf '%s' "$GH_REPO" | grep -Eq '^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$' || fail "\"$GH_REPO\" is not owner/name."
    if [ -z "${GITHUB_TOKEN:-}" ]; then
      hint "→ https://github.com/settings/personal-access-tokens/new" \
           "Token name: $(slugify "$VPN_NAME") · Expiration: the longest you can" \
           "Repository access: Only select repositories → $GH_REPO" \
           "Permissions → Actions: Read and write · Contents: Read and write · Workflows: Read and write" \
           "Generate token → copy it → paste here (it is not shown while you paste)"
      if tty_ok; then read -r -s -p "8. GitHub token: " GITHUB_TOKEN </dev/tty; echo; fi
    fi
    GITHUB_TOKEN="$(printf '%s' "${GITHUB_TOKEN:-}" | tr -d ' \r\n')"
  fi
  if [ -z "${TG_BOT+x}" ]; then
    hint "Optional: a Telegram bot sends you the nightly backup file and alerts." \
         "→ open @BotFather in Telegram → /newbot → copy the token.   Enter = skip"
    ask TG_BOT "9. Telegram bot token"
  fi
  TG_BOT="$(printf '%s' "${TG_BOT:-}" | tr -d ' ')"
  DIR="/opt/$SLUG"
  CLI="$SLUG"; if command -v "$CLI" >/dev/null 2>&1 && ! grep -q 'vpn-panel' "$(command -v "$CLI")" 2>/dev/null; then CLI="$SLUG-panel"; fi
fi
DOMAIN="$PANEL_DOMAIN"
VPN_DOMAIN="${VPN_DOMAIN:-$PANEL_DOMAIN}"
PROXY_PORT="${PROXY_PORT:-8080}"
compose() { docker compose --project-directory "$DIR" -p "$SLUG" --env-file "$DIR/.env" -f "$DIR/compose.yml" "$@"; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# ----------------------------------------------------------------------------- backups
# One encrypted file with everything needed to rebuild this server and keep updating the app:
# the app signing key, settings + keys (.env, settings.env), the logo and the database.
tg_send() { # message [file]
  [ -n "${TG_BOT:-}" ] && [ -n "${TG_CHAT:-}" ] || return 0
  if [ -n "${2:-}" ]; then
    curl -fsS --max-time 120 "https://api.telegram.org/bot$TG_BOT/sendDocument" --form-string "chat_id=$TG_CHAT" \
      --form-string "caption=$1" -F "document=@$2" >/dev/null 2>&1 || warn "Telegram: could not send the file."
  else
    curl -fsS --max-time 30 "https://api.telegram.org/bot$TG_BOT/sendMessage" --form-string "chat_id=$TG_CHAT" \
      --form-string "text=$1" >/dev/null 2>&1 || true
  fi
}
make_backup() {
  local b="$tmp/bk/backup" name
  name="backup-$(date +%Y%m%d-%H%M%S).tar.gz.enc"
  rm -rf "$tmp/bk"; mkdir -p "$b"
  compose exec -T db pg_dump -U vpn vpn | gzip > "$b/db.sql.gz" || { warn "Database backup failed."; return 1; }
  cp "$DIR/.env" "$DIR/settings.env" "$DIR/VERSION" "$b/"
  [ -d "$DIR/app" ] && mkdir -p "$b/app" && cp "$DIR/app/"release.* "$b/app/" 2>/dev/null || true
  [ -f "$DIR/downloads/logo.png" ] && cp "$DIR/downloads/logo.png" "$b/"
  tar -czf "$tmp/bk/b.tgz" -C "$tmp/bk" backup
  BACKUP_PASS="$BACKUP_PASS" openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt -pass env:BACKUP_PASS -in "$tmp/bk/b.tgz" -out "$DIR/backups/$name"
  chmod 644 "$DIR/backups/$name"; rm -rf "$tmp/bk"
  ls -1t "$DIR"/backups/backup-*.tar.gz.enc 2>/dev/null | tail -n +15 | xargs -r rm -f   # keep the newest 14
  BACKUP_FILE="$DIR/backups/$name"
  ok "Backup saved: $BACKUP_FILE (panel → Backup → Download)"
  tg_send "$VPN_NAME backup $(date '+%Y-%m-%d %H:%M') — open with the backup password" "$BACKUP_FILE"
}
if [ -n "${BACKUP_ONLY:-}" ] && [ $UPDATE = 1 ]; then
  [ -n "${BACKUP_PASS:-}" ] || fail "Run \"$CLI update\" once first (it turns on encrypted backups)."
  mkdir -p "$DIR/backups"
  [ -f "$DIR/.github-token" ] && GITHUB_TOKEN="$(cat "$DIR/.github-token")"
  make_backup || exit 1
  if [ "${BACKUP_MODE:-}" = nightly ] && [ -n "${GITHUB_TOKEN:-}" ] && [ -n "${GH_REPO:-}" ]; then
    exp="$(curl -sSI -H "Authorization: Bearer $GITHUB_TOKEN" "https://api.github.com/repos/$GH_REPO" | tr -d '\r' | sed -n 's/^github-authentication-token-expiration: //Ip' | head -1)"
    if [ -n "$exp" ] && [ "$(date -d "$exp" +%s 2>/dev/null || echo 0)" -lt "$(( $(date +%s) + 7*86400 ))" ]; then
      tg_send "$VPN_NAME: the GitHub token expires on $exp. Make a new one and run: $CLI set-token"
    fi
  fi
  exit 0
fi

if [ -n "${RESTORE_FROM:-}" ] && [ $UPDATE = 1 ]; then
  say "Restoring $RESTORE_FROM"
  pass="${BACKUP_PASS_RESTORE:-}"
  if [ -z "$pass" ] && tty_ok; then read -r -s -p "Backup password: " pass </dev/tty; echo; fi
  mkdir -p "$tmp/rs"
  BP="$pass" openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -pass env:BP -in "$RESTORE_FROM" 2>/dev/null | tar -xz -C "$tmp/rs" 2>/dev/null \
    || fail "Wrong backup password or not a backup file."
  r="$tmp/rs/backup"; [ -f "$r/settings.env" ] && [ -f "$r/db.sql.gz" ] || fail "This backup is incomplete."
  [ "$( . "$r/settings.env"; echo "$SLUG")" = "$SLUG" ] || fail "This backup is for another VPN ($( . "$r/settings.env"; echo "$VPN_NAME")). Install with that name first."
  yesno "This REPLACES the panel data, keys and app signing key here with the backup. Continue?" || fail "Nothing was changed."
  keep="$(grep -E '^(POSTGRES_PASSWORD|BACKEND_IMAGE|API_PORT)=' "$DIR/.env")"
  grep -vE '^(POSTGRES_PASSWORD|BACKEND_IMAGE|API_PORT)=' "$r/.env" > "$DIR/.env"; printf '%s\n' "$keep" >> "$DIR/.env"
  cp "$r/settings.env" "$DIR/settings.env"
  mkdir -p "$DIR/app"; cp "$r/app/"release.* "$DIR/app/" 2>/dev/null || true
  [ -f "$r/logo.png" ] && cp "$r/logo.png" "$DIR/downloads/logo.png"
  chmod 600 "$DIR/.env" "$DIR/settings.env" "$DIR/app/"release.* 2>/dev/null || true
  compose stop backend >/dev/null
  compose exec -T db psql -U vpn -d vpn -qc 'drop schema public cascade; create schema public;' >/dev/null
  gunzip -c "$r/db.sql.gz" | compose exec -T db psql -U vpn -d vpn -v ON_ERROR_STOP=1 -q >/dev/null || fail "Database restore failed."
  touch "$DIR/.setup-done" "$DIR/.proxy-added"
  ok "Restored. Applying the settings…"
  exec env -u RESTORE_FROM BUNDLE_KEY="${BUNDLE_KEY:-}" bash "$DIR/vpn-panel.sh"
fi


# ----------------------------------------------------------------------------- checks
if [ $UPDATE = 0 ]; then
  say "Checking this server"
  MYIP="$(curl -fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
  DNSIP="$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk 'NR==1{print $1}' || true)"
  if [ "$DOMAIN" != localhost ] && [ -n "$MYIP" ] && [ "$DNSIP" != "$MYIP" ]; then
    warn "$DOMAIN points to ${DNSIP:-nothing}, but this server is $MYIP."
    warn "Set the domain's A record to $MYIP (HTTPS starts working a few minutes after that)."
    yesno "Continue anyway?" || fail "Stopped. Fix the DNS record and run the script again."
  fi
  for p in 80 443; do
    owner="$(ss -Hltnp "sport = :$p" 2>/dev/null | sed -n 's/.*users:(("\([^"]*\)".*/\1/p' | head -1)"
    [ -z "$owner" ] && continue
    case "$owner" in docker-proxy) fail "Port $p is used by another Docker app. Use a fresh VPS." ;; esac
    warn "Port $p is used by \"$owner\" (another website or VPN script on this VPS)."
    if yesno "Stop and disable \"$owner\" so this VPN can use ports 80/443?"; then
      systemctl disable --now "$owner" >/dev/null 2>&1 || systemctl stop "$owner" 2>/dev/null || true
      sleep 1
      [ -z "$(ss -Hltn "sport = :$p")" ] || fail "Port $p is still busy. Stop that program and run again."
      ok "Stopped $owner"
    else
      fail "Ports 80 and 443 are needed. Nothing was changed."
    fi
  done
  ss -Hltn 'sport = :22' | grep -q . || fail "No SSH server on port 22 (install openssh-server)."
  if [ -n "$(ss -Hltn "sport = :$PROXY_PORT" 2>/dev/null)" ]; then PROXY_PORT=8880; warn "Port 8080 is busy; the payload proxy uses $PROXY_PORT."; fi
  # VPN domain: same as the panel, straight to this server, or behind the Cloudflare CDN
  VPN_TLS="${VPN_TLS-}"
  if [ "$VPN_DOMAIN" != "$DOMAIN" ] && [ -z "${VPN_TLS:-}" ]; then
    VIP_IP="$(getent ahostsv4 "$VPN_DOMAIN" 2>/dev/null | awk 'NR==1{print $1}' || true)"
    if [ -n "$MYIP" ] && [ "$VIP_IP" = "$MYIP" ]; then
      ok "$VPN_DOMAIN points to this server (no CDN)"
    elif curl -fsS --max-time 8 "http://$VPN_DOMAIN/cdn-cgi/trace" 2>/dev/null | grep -q '^fl='; then
      VPN_TLS="tls internal"  # Cloudflare talks to us; its SSL mode must be "Full"
      ok "$VPN_DOMAIN is behind Cloudflare — set Cloudflare → SSL/TLS → Full"
    else
      warn "$VPN_DOMAIN does not point to this server (${VIP_IP:-no address}) and is not behind Cloudflare."
      yesno "Continue anyway?" || fail "Stopped. Fix the DNS record of $VPN_DOMAIN and run the script again."
    fi
  fi
  # GitHub: the repo must be reachable with the token, and private
  if [ -n "${GH_REPO:-}" ] && [ -n "${GITHUB_TOKEN:-}" ]; then
    info="$(curl -sS -H "Authorization: Bearer $GITHUB_TOKEN" -H 'Accept: application/vnd.github+json' "https://api.github.com/repos/$GH_REPO" || true)"
    if [ "$(printf '%s' "$info" | jq -r '.full_name // empty' 2>/dev/null)" = "" ]; then
      warn "GitHub: the token cannot open $GH_REPO. Check the repository name and that the token has access to it."
      yesno "Continue without building the app now? (later: <command> set-token)" || fail "Stopped."
      GITHUB_TOKEN=""
    elif [ "$(printf '%s' "$info" | jq -r .private)" != true ]; then
      warn "$GH_REPO is PUBLIC — your app's source would be visible to everyone."
      yesno "Make it private on GitHub first (Settings → Danger Zone). Continue anyway?" || fail "Stopped."
    else ok "GitHub repository $GH_REPO (private)"; fi
  fi
  # Telegram bot: find the owner's chat (they press Start in the bot once)
  TG_CHAT="${TG_CHAT:-}"
  if [ -n "${TG_BOT:-}" ] && [ -z "$TG_CHAT" ]; then
    bot="$(curl -fsS --max-time 10 "https://api.telegram.org/bot$TG_BOT/getMe" 2>/dev/null | jq -r '.result.username // empty' || true)"
    if [ -z "$bot" ]; then warn "Telegram: that bot token does not work; skipping the bot."; TG_BOT=""
    elif tty_ok; then
      printf '   Open https://t.me/%s in Telegram and press START, then press Enter here.' "$bot"; read -r _ </dev/tty
      for i in 1 2 3 4 5 6; do
        TG_CHAT="$(curl -fsS --max-time 10 "https://api.telegram.org/bot$TG_BOT/getUpdates" | jq -r '[.result[].message.chat.id // empty] | last // empty' || true)"
        [ -n "$TG_CHAT" ] && break; sleep 5
      done
      [ -n "$TG_CHAT" ] && ok "Telegram bot @$bot connected" || { warn "No START message found; skipping the bot (later: re-run with TG_BOT)."; TG_BOT=""; }
    fi
  fi
  mem=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
  if [ "$mem" -lt 1900 ] && [ -z "$(swapon --show --noheadings 2>/dev/null)" ]; then
    say "Adding 2 GB swap (this VPS has ${mem} MB RAM)"
    fallocate -l 2G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none
    chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile
    grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  fi
fi
[ -n "${BUNDLE_FILE:-}" ] || [ -n "${BUNDLE_KEY:-}" ] || fail "BUNDLE_KEY is required (the download key you were given)."

# ----------------------------------------------------------------------------- docker
if ! command -v docker >/dev/null || ! docker compose version >/dev/null 2>&1; then
  say "Installing Docker"
  apt-get update -qq
  apt-get install -y -qq docker.io docker-compose-v2 >/dev/null 2>&1 || curl -fsSL https://get.docker.com | sh >/dev/null
  systemctl enable --now docker >/dev/null 2>&1 || true
fi
docker compose version >/dev/null 2>&1 || fail "Docker Compose could not be installed."

# ----------------------------------------------------------------------------- code
say "Downloading the panel"
mkdir -p "$DIR/xray" "$DIR/downloads" "$DIR/app"; chmod 700 "$DIR"
if [ -n "${BUNDLE_FILE:-}" ]; then cp "$BUNDLE_FILE" "$tmp/bundle.tgz"
else
  curl -fsSL --retry 3 "$BUNDLE_URL" -o "$tmp/bundle.enc" || fail "Download failed (check the internet connection)."
  BUNDLE_KEY="$BUNDLE_KEY" openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -pass env:BUNDLE_KEY -in "$tmp/bundle.enc" -out "$tmp/bundle.tgz" 2>/dev/null \
    || fail "BUNDLE_KEY is wrong."
fi
tar -xzf "$tmp/bundle.tgz" -C "$tmp" || fail "The download is corrupted. Run again."
[ -d "$tmp/bundle/allinone" ] || fail "This download is too old for the all-in-one setup."
cp "$tmp/bundle/allinone/compose.yml" "$tmp/bundle/allinone/sshws.py" "$DIR/"
[ -f "$DIR/settings.env" ] && VPN_DOMAIN="$(. "$DIR/settings.env"; echo "${VPN_DOMAIN:-$PANEL_DOMAIN}")"
if [ "$VPN_DOMAIN" != "$DOMAIN" ] && [ -f "$tmp/bundle/allinone/Caddyfile.cdn" ]; then cp "$tmp/bundle/allinone/Caddyfile.cdn" "$DIR/Caddyfile"
else cp "$tmp/bundle/allinone/Caddyfile" "$DIR/Caddyfile"; fi
mkdir -p "$DIR/backups"; chmod 755 "$DIR/backups"
APP_SRC_NEW="$(cat "$tmp/bundle/APP_SRC_VERSION" 2>/dev/null || true)"
[ -f "$tmp/bundle/app-src.tgz" ] && cp "$tmp/bundle/app-src.tgz" "$DIR/app/app-src.tgz"
VER="$(cat "$tmp/bundle/VERSION")"; echo "$VER" > "$DIR/VERSION"
cp "$0" "$DIR/vpn-panel.sh" 2>/dev/null || true; chmod 700 "$DIR/vpn-panel.sh" 2>/dev/null || true

IMAGE="$SLUG-panel:$VER"
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  say "Downloading the panel image ($VER)"
  if [ -n "${IMAGE_FILE:-}" ]; then gunzip -c "$IMAGE_FILE" | docker load >/dev/null
  else
    : > "$tmp/image.enc"
    for p in aa ab ac ad ae af ag ah; do
      curl -fsL --retry 3 "$IMAGE_BASE/rocketmm-backend-$VER.enc.part-$p" >> "$tmp/image.enc" 2>/dev/null || break
    done
    [ -s "$tmp/image.enc" ] || fail "The panel image for version $VER is not published yet. Try again later."
    BUNDLE_KEY="$BUNDLE_KEY" openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -pass env:BUNDLE_KEY -in "$tmp/image.enc" 2>/dev/null \
      | gunzip -c | docker load >/dev/null || fail "The panel image could not be loaded."
    rm -f "$tmp/image.enc"
  fi
  docker tag "rocketmm-backend:$VER" "$IMAGE" && docker rmi "rocketmm-backend:$VER" >/dev/null 2>&1 || true
fi
docker image inspect "$IMAGE" >/dev/null 2>&1 || fail "Panel image missing."

# ----------------------------------------------------------------------------- secrets & VPN settings (once)
if [ ! -f "$DIR/settings.env" ]; then
  say "Creating keys"
  umask 077
  ssh_user="$SLUG"; id "$ssh_user" >/dev/null 2>&1 && ! grep -q "^$ssh_user:.*:/usr/sbin/nologin$" /etc/passwd && ssh_user="${SLUG}vpn"
  cat > "$DIR/settings.env" <<EOF
VPN_NAME="$VPN_NAME"
SLUG=$SLUG
CLI=$CLI
PANEL_DOMAIN=$DOMAIN
ADMIN_EMAIL=$ADMIN_EMAIL
VIP_URL="$VIP_URL"
COUNTRY=$COUNTRY
XRAY_UUID=$(cat /proc/sys/kernel/random/uuid)
VLESS_PATH=/vl-$(rand 10)
VMESS_PATH=/vm-$(rand 10)
SSH_PATH=/ws-$(rand 10)
SSH_USER=$ssh_user
SSH_PASS=$(rand 16)
APP_ID=com.$SLUG.vpn
APP_BUILD=0
SYS_EMAIL=installer@$SLUG.vpn
SYS_PASS=$(rand 32)
VPN_DOMAIN=$VPN_DOMAIN
PROXY_PORT=$PROXY_PORT
GH_REPO=${GH_REPO:-}
APP_SRC_VER=
UI_STYLE=clean
TG_BOT=${TG_BOT:-}
TG_CHAT=${TG_CHAT:-}
BACKUP_PASS=$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-16)
EOF
  cat > "$DIR/.env" <<EOF
VPN_NAME="$VPN_NAME"
DOMAIN=$DOMAIN
ADMIN_EMAIL=$ADMIN_EMAIL
CADDY_TLS=${CADDY_TLS:-}
VPN_TLS=${VPN_TLS:-}
POSTGRES_PASSWORD=$(rand 40)
JWT_SECRET=$(rand 64)
SECRETS_KEY=$(openssl rand -base64 32)
MANIFEST_SIGNING_KEY=$(openssl rand -base64 32)
EOF
  printf 'DIR=%s\nSLUG=%s\n' "$DIR" "$SLUG" > "$CONF"
fi
chmod 600 "$DIR/settings.env" "$DIR/.env"
# settings added by newer versions of this script (older installs get them on update)
addset() { grep -q "^$1=" "$DIR/settings.env" || printf '%s=%s\n' "$1" "$2" >> "$DIR/settings.env"; }
addset VPN_DOMAIN "$PANEL_DOMAIN"; addset PROXY_PORT "$PROXY_PORT"; addset GH_REPO ""; addset APP_SRC_VER ""
addset UI_STYLE clean; addset TG_BOT ""; addset TG_CHAT ""
grep -q '^BACKUP_PASS=' "$DIR/settings.env" || { printf 'BACKUP_PASS=%s\n' "$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-16)" >> "$DIR/settings.env"; NEW_BACKUP_PASS=1; }
# shellcheck disable=SC1091
. "$DIR/settings.env"
[ -n "${GITHUB_TOKEN:-}" ] && { umask 077; printf '%s' "$GITHUB_TOKEN" > "$DIR/.github-token"; }
[ -z "${GITHUB_TOKEN:-}" ] && [ -f "$DIR/.github-token" ] && GITHUB_TOKEN="$(cat "$DIR/.github-token")"
for k in BACKEND_IMAGE VLESS_PATH VMESS_PATH SSH_PATH API_PORT VIP_URL VPN_DOMAIN PROXY_PORT; do sed -i "/^$k=/d" "$DIR/.env"; done
printf 'BACKEND_IMAGE=%s\nVLESS_PATH=%s\nVMESS_PATH=%s\nSSH_PATH=%s\nAPI_PORT=%s\nVIP_URL=%s\nVPN_DOMAIN=%s\nPROXY_PORT=%s\n' \
  "$IMAGE" "$VLESS_PATH" "$VMESS_PATH" "$SSH_PATH" "$API_PORT" "$VIP_URL" "$VPN_DOMAIN" "$PROXY_PORT" >> "$DIR/.env"
grep -q '^VPN_TLS=' "$DIR/.env" || printf 'VPN_TLS=%s\n' "${VPN_TLS:-}" >> "$DIR/.env"

cat > "$DIR/xray/config.json" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    { "listen": "0.0.0.0", "port": 10001, "protocol": "vless",
      "settings": { "clients": [ { "id": "$XRAY_UUID" } ], "decryption": "none" },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "$VLESS_PATH" } } },
    { "listen": "0.0.0.0", "port": 10002, "protocol": "vmess",
      "settings": { "clients": [ { "id": "$XRAY_UUID" } ] },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "$VMESS_PATH" } } }
  ],
  "outbounds": [ { "protocol": "freedom" } ]
}
EOF

# ----------------------------------------------------------------------------- SSH account for the app
if ! id "$SSH_USER" >/dev/null 2>&1; then useradd -M -s /usr/sbin/nologin "$SSH_USER"; fi
echo "$SSH_USER:$SSH_PASS" | chpasswd
mark="# vpn-panel: $SSH_USER"
if ! grep -qF "$mark" /etc/ssh/sshd_config; then
  cp /etc/ssh/sshd_config /etc/ssh/sshd_config.vpn-panel.bak
  printf '\n%s (tunnel only, no shell)\nMatch User %s\n    PasswordAuthentication yes\n    KbdInteractiveAuthentication yes\n    AllowTcpForwarding yes\n    PermitTTY no\n    X11Forwarding no\n' "$mark" "$SSH_USER" >> /etc/ssh/sshd_config
  if sshd -t 2>/dev/null; then systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
  else cp /etc/ssh/sshd_config.vpn-panel.bak /etc/ssh/sshd_config; warn "Could not adjust the SSH server; SSH servers may not log in."; fi
fi

# ----------------------------------------------------------------------------- start
if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q 'Status: active'; then ufw allow 80/tcp >/dev/null; ufw allow 443/tcp >/dev/null; ufw allow 22/tcp >/dev/null; ufw allow "$PROXY_PORT/tcp" >/dev/null; fi
say "Starting $VPN_NAME"
compose up -d --remove-orphans
for i in $(seq 1 60); do
  [ "$(docker inspect -f '{{.State.Health.Status}}' "$(compose ps -q backend)" 2>/dev/null)" = healthy ] && break
  [ "$i" = 60 ] && { compose logs --tail 40 backend; fail "The panel did not start. The log above shows why."; }
  sleep 3
done
ok "Panel running"

API="http://127.0.0.1:$API_PORT/api/v1"
api() {
  local auth=(); [ -n "${TOKEN:-}" ] && auth=(-H "Authorization: Bearer $TOKEN")
  curl -fsS -H 'X-Forwarded-Proto: https' -H 'Content-Type: application/json' "${auth[@]}" "$@"
}
# The installer's own panel account (password only in settings.env, root-only): sets up servers and app releases.
sys_login() {
  TOKEN="$(api -X POST "$API/admin/login" -d "$(jq -nc --arg e "$SYS_EMAIL" --arg p "$SYS_PASS" '{email:$e,password:$p}')" | jq -r .token)"
  [ -n "$TOKEN" ] && [ "$TOKEN" != null ] || fail "Could not log in to the panel."
}

# SSH through the payload proxy (CONNECT on $PROXY_PORT → this server's SSH only), on the panel domain
# (DNS only: a CDN does not carry it).
add_proxy_server() {
  local pl pid
  pl='CONNECT [host_port] HTTP/1.1[crlf]Host: [host][crlf]X-Online-Host: [host][crlf][crlf]'
  pid="$(api -X POST "$API/admin/payloads" -d "$(jq -nc --arg p "$pl" --arg h "$DOMAIN" --argjson port "$PROXY_PORT" \
    '{name:"Payload proxy",transport:"payload",payload:$p,proxyHost:$h,proxyPort:$port}')" | jq -r .id)"
  api -X POST "$API/admin/servers" -d "$(jq -nc --arg n "SSH Proxy · $PROXY_PORT" --arg h "$DOMAIN" --arg c "$COUNTRY" --argjson o "$1" \
    --arg pid "$pid" --arg u "$SSH_USER" --arg pw "$SSH_PASS" \
    '{name:$n,host:$h,port:22,group:"free",country:(if $c=="" then null else $c end),sortOrder:$o,protocol:"ssh",
      ssh:{transport:"payload"},payloadId:$pid,secrets:{username:$u,password:$pw}}')" >/dev/null && ok "SSH Proxy · $PROXY_PORT"
}

# ----------------------------------------------------------------------------- admin + servers (first run)
if [ ! -f "$DIR/.setup-done" ]; then
  pw="$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-16)"
  compose exec -T -e ADMIN_PASSWORD="$pw" backend node dist/scripts/create-admin.js "$ADMIN_EMAIL" admin >/dev/null
  umask 077
  printf 'Panel:     https://%s/admin\nEmail:     %s\nPassword:  %s\n' "$DOMAIN" "$ADMIN_EMAIL" "$pw" > "$DIR/ADMIN-LOGIN.txt"
  compose exec -T -e ADMIN_PASSWORD="$SYS_PASS" backend node dist/scripts/create-admin.js "$SYS_EMAIL" admin >/dev/null
  sys_login

  say "Adding the VPN servers to the panel"
  payload='GET '"$SSH_PATH"' HTTP/1.1[crlf]Host: [host][crlf]Upgrade: websocket[crlf]Connection: Upgrade[crlf][crlf]'
  p80="$(api -X POST "$API/admin/payloads" -d "$(jq -nc --arg p "$payload" '{name:"SSH WebSocket",transport:"payload",payload:$p}')" | jq -r .id)"
  p443="$(api -X POST "$API/admin/payloads" -d "$(jq -nc --arg p "$payload" --arg s "$VPN_DOMAIN" '{name:"SSH WebSocket TLS",transport:"tls-payload",payload:$p,sni:$s}')" | jq -r .id)"
  add() { api -X POST "$API/admin/servers" -d "$1" >/dev/null && ok "$(printf '%s' "$1" | jq -r .name)"; }
  base() { jq -nc --arg n "$1" --arg h "${HOST_FOR:-$VPN_DOMAIN}" --argjson port "$2" --arg c "$COUNTRY" --argjson o "$3" \
    '{name:$n,host:$h,port:$port,group:"free",country:(if $c=="" then null else $c end),sortOrder:$o}'; }
  xr() { # name port proto tls order
    base "$1" "$2" "$5" | jq -c --arg proto "$3" --arg path "$( [ "$3" = vless ] && echo "$VLESS_PATH" || echo "$VMESS_PATH")" --arg h "$VPN_DOMAIN" \
      --arg sec "$4" --arg id "$XRAY_UUID" '. + {protocol:$proto, xray:({network:"ws",path:$path,host:$h,security:$sec} + (if $sec=="tls" then {sni:$h} else {} end)
        + (if $proto=="vmess" then {vmessSecurity:"auto"} else {} end)), secrets:{userId:$id}}'; }
  sh_() { # name port transport payloadId order
    base "$1" "$2" "$5" | jq -c --arg t "$3" --arg pid "$4" --arg h "$VPN_DOMAIN" --arg u "$SSH_USER" --arg pw "$SSH_PASS" \
      '. + {protocol:"ssh", ssh:({transport:$t} + (if ($t|startswith("tls")) then {sni:$h} else {} end)), secrets:{username:$u,password:$pw}}
        + (if $pid=="" then {} else {payloadId:$pid} end)'; }
  add "$(xr 'VLESS · 443' 443 vless tls 1)"
  add "$(xr 'VMess · 443' 443 vmess tls 2)"
  add "$(sh_ 'SSH WS · 443' 443 tls-payload "$p443" 3)"
  add "$(xr 'VLESS · 80' 80 vless none 4)"
  add "$(xr 'VMess · 80' 80 vmess none 5)"
  add "$(sh_ 'SSH WS · 80' 80 payload "$p80" 6)"
  HOST_FOR="$DOMAIN" add "$(HOST_FOR="$DOMAIN" sh_ 'SSH · 22' 22 direct '' 7)"
  add_proxy_server 8
  api -X POST "$API/admin/publish" -d '{"note":"first setup"}' >/dev/null && ok "Published to the app"
  touch "$DIR/.setup-done" "$DIR/.proxy-added"
  NEW_ADMIN=1
fi

if [ -f "$DIR/.setup-done" ] && [ ! -f "$DIR/.proxy-added" ]; then
  sys_login
  say "Adding the payload proxy server"
  if add_proxy_server 8 && api -X POST "$API/admin/publish" -d '{"note":"payload proxy"}' >/dev/null; then touch "$DIR/.proxy-added"; ok "Published"; fi
fi

# nightly backup (+ Telegram) and a GitHub token expiry check
cat > "/etc/cron.d/$SLUG-backup" <<EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
17 3 * * * root /usr/local/bin/$CLI backup nightly >/dev/null 2>&1
EOF
chmod 644 "/etc/cron.d/$SLUG-backup"

# ----------------------------------------------------------------------------- helper command
cat > "/usr/local/bin/$CLI" <<EOF
#!/usr/bin/env bash
# vpn-panel helper for $VPN_NAME (run as root). "$CLI help" lists the commands.
DIR="$DIR"; c() { docker compose --project-directory "\$DIR" -p "$SLUG" --env-file "\$DIR/.env" -f "\$DIR/compose.yml" "\$@"; }
run() { BUNDLE_KEY="\${BUNDLE_KEY:-\$(cat "\$DIR/.bundle-key" 2>/dev/null)}" "\$@" bash "\$DIR/vpn-panel.sh"; }
case "\${1:-status}" in
  status)    c ps ;;
  logs)      c logs --tail "\${2:-100}" -f "\${3:-backend}" ;;
  restart)   c restart ;;
  update)    curl -fsSL "$INSTALLER_URL" -o "\$DIR/vpn-panel.sh.new" && mv "\$DIR/vpn-panel.sh.new" "\$DIR/vpn-panel.sh"; run env ;;
  build-app) run env BUILD_APP_ONLY=1 ;;
  set-token) read -r -s -p "New GitHub token: " t; echo; [ -n "\$t" ] || exit 1
             umask 077; printf '%s' "\$t" > "\$DIR/.github-token"; echo "saved. Build the app now with: $CLI build-app" ;;
  logo)      [ -n "\${2:-}" ] || { echo "usage: $CLI logo <https link to a PNG>   (then: $CLI build-app)"; exit 2; }
             curl -fsSL "\$2" -o "\$DIR/downloads/logo.png" && chmod 644 "\$DIR/downloads/logo.png" && echo "logo saved. Build the app with: $CLI build-app" ;;
  backup)    run env BACKUP_ONLY=1 BACKUP_MODE="\${2:-}" ;;
  restore)   [ -f "\${2:-}" ] || { echo "usage: $CLI restore <backup-….tar.gz.enc>"; exit 2; }; run env RESTORE_FROM="\$2" ;;
  add-admin) [ -n "\${2:-}" ] || { echo "usage: $CLI add-admin <email>"; exit 2; }
             pw=\$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-16); c exec -T -e ADMIN_PASSWORD="\$pw" backend node dist/scripts/create-admin.js "\$2" "\${3:-admin}" && echo "password: \$pw" ;;
  info)      cat "\$DIR/INFO.txt" ;;
  *)         echo "usage: $CLI status | logs | restart | update | build-app | set-token | logo <link> | backup | restore <file> | add-admin <email> | info" ;;
esac
EOF
chmod 755 "/usr/local/bin/$CLI"
[ -n "${BUNDLE_KEY:-}" ] && { umask 077; printf '%s' "$BUNDLE_KEY" > "$DIR/.bundle-key"; }

# ----------------------------------------------------------------------------- app (APK) built on GitHub
PUBKEY="$(api "$API/servers/signing-key" | jq -r .publicKey)"
# The app source (from the bundle) is pushed to the owner's private repo, where build-app.yml builds the APK.
push_source() {
  local tok="$1" src="$tmp/src"
  [ -f "$DIR/app/app-src.tgz" ] || { warn "This bundle has no app source."; return 1; }
  if [ "${APP_SRC_VER:-}" = "$APP_SRC_NEW" ] && [ -n "$APP_SRC_NEW" ] && [ -z "${FORCE_PUSH:-}" ]; then return 0; fi
  say "Uploading the app source to github.com/$GH_REPO"
  rm -rf "$src"; mkdir -p "$src"; tar -xzf "$DIR/app/app-src.tgz" -C "$src"
  printf '\nuiStyle=%s\n' "${UI_STYLE:-clean}" >> "$src/android/gradle.properties"
  printf '# %s app\n\nPrivate build repository for the %s Android app (managed by the server installer;\nchanges here are overwritten on update). Builds: Actions → Build VPN app.\n' "$VPN_NAME" "$VPN_NAME" > "$src/README.md"
  (cd "$src" && git init -q -b main && git add -A && git -c user.name="$VPN_NAME" -c user.email="installer@$SLUG.vpn" commit -qm "$VPN_NAME app ${APP_SRC_NEW:-}" \
    && git push -q -f "${GIT_PUSH_URL:-https://x-access-token:$tok@github.com/$GH_REPO.git}" main 2>"$tmp/push.err") || {
      sed "s/$tok/***/g" "$tmp/push.err" >&2
      warn "GitHub did not accept the source. The token needs Contents + Workflows: Read and write on $GH_REPO."; return 1; }
  sed -i "s/^APP_SRC_VER=.*/APP_SRC_VER=$APP_SRC_NEW/" "$DIR/settings.env"; APP_SRC_VER="$APP_SRC_NEW"
  ok "Source uploaded"
}
build_app() {
  local tok="$1" ks="$DIR/app/release.p12" kp repo ref
  if [ -n "${GH_REPO:-}" ] && [ -z "${SKIP_SOURCE_PUSH:-}" ]; then push_source "$tok" || return 1; repo="$GH_REPO"; ref=main
  elif [ -n "${GH_REPO:-}" ]; then repo="$GH_REPO"; ref="${APP_REF}"
  else repo="$APP_REPO"; ref="$APP_REF"; fi
  say "Building the $VPN_NAME Android app on GitHub (10-20 minutes)"
  if [ ! -f "$ks" ]; then  # signing key: made once, kept on this server and in every backup
    kp="$(rand 24)"
    openssl ecparam -name prime256v1 -genkey -noout -out "$tmp/k.pem" 2>/dev/null
    openssl req -new -x509 -key "$tmp/k.pem" -out "$tmp/c.pem" -days 10000 -subj "/CN=$VPN_NAME" 2>/dev/null
    openssl pkcs12 -export -inkey "$tmp/k.pem" -in "$tmp/c.pem" -name app -out "$ks" -passout "pass:$kp" \
      -keypbe AES-256-CBC -certpbe AES-256-CBC -macalg sha256 2>/dev/null
    printf '%s' "$kp" > "$DIR/app/release.password"; chmod 600 "$ks" "$DIR/app/release.password"
    NEW_KEY=1
  fi
  kp="$(cat "$DIR/app/release.password")"
  local build=$((APP_BUILD + 1)) code ver logo="" gh="https://api.github.com/repos/$repo"
  code=$((1000 + build)); ver="1.0.$build"
  [ -f "$DIR/downloads/logo.png" ] && logo="https://$DOMAIN/download/logo.png"
  local inputs; inputs="$(jq -nc --arg name "$VPN_NAME" --arg id "$APP_ID" --arg backend "https://$DOMAIN" --arg key "$PUBKEY" \
    --arg vip "$VIP_URL" --arg logo "$logo" --arg ver "$ver" --arg code "$code" --arg ks "$(base64 -w0 "$ks")" --arg kp "$kp" \
    '{name:$name, app_id:$id, backend:$backend, manifest_key:$key, vip_url:$vip, logo_url:$logo, version_name:$ver, version_code:$code, keystore:$ks, keystore_password:$kp}')"
  local started body code_http i; started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  body="$(jq -nc --arg ref "$ref" --argjson i "$inputs" '{ref:$ref, inputs:$i}')"
  for i in $(seq 1 12); do  # a freshly pushed workflow takes a few seconds to appear
    code_http="$(curl -sS -o "$tmp/disp.out" -w '%{http_code}' -X POST -H "Authorization: Bearer $tok" -H 'Accept: application/vnd.github+json' \
      "$gh/actions/workflows/build-app.yml/dispatches" -d "$body" || true)"
    [ "$code_http" = 204 ] && break
    [ "$code_http" = 404 ] || [ "$code_http" = 422 ] || break
    sleep 5
  done
  [ "$code_http" = 204 ] || { warn "GitHub refused the build ($code_http: $(jq -r '.message // empty' "$tmp/disp.out" 2>/dev/null)). The token needs Actions: Read and write on $repo."; return 1; }
  local run="" st="" concl=""
  for i in $(seq 1 20); do
    sleep 6
    run="$(curl -fsS -H "Authorization: Bearer $tok" "$gh/actions/workflows/build-app.yml/runs?event=workflow_dispatch&created=%3E%3D$started&per_page=1" | jq -r '.workflow_runs[0].id // empty')"
    [ -n "$run" ] && break
  done
  [ -n "$run" ] || { warn "The build did not start on GitHub (is Actions enabled for $repo?)."; return 1; }
  printf 'GitHub build %s ' "$run"
  for i in $(seq 1 180); do
    read -r st concl < <(curl -fsS -H "Authorization: Bearer $tok" "$gh/actions/runs/$run" | jq -r '"\(.status) \(.conclusion)"')
    [ "$st" = completed ] && break; printf '.'; sleep 10
  done; echo
  [ "$concl" = success ] || { warn "The app build failed on GitHub: https://github.com/$repo/actions/runs/$run"; return 1; }
  local art; art="$(curl -fsS -H "Authorization: Bearer $tok" "$gh/actions/runs/$run/artifacts" | jq -r '.artifacts[0].archive_download_url')"
  curl -fsSL -H "Authorization: Bearer $tok" "$art" -o "$tmp/app.zip" && unzip -o -q "$tmp/app.zip" -d "$tmp/app" || { warn "Could not download the app."; return 1; }
  local apk; apk="$(ls "$tmp"/app/*.apk | head -1)"; [ -f "$apk" ] || { warn "No APK in the build."; return 1; }
  local file="$SLUG-$ver.apk"
  rm -f "$DIR/downloads/$SLUG-"*.apk; cp "$apk" "$DIR/downloads/$file"; cp "$apk" "$DIR/downloads/$SLUG.apk"
  chmod 644 "$DIR/downloads/"*.apk
  local sha; sha="$(sha256sum "$DIR/downloads/$file" | cut -d' ' -f1)"
  sys_login
  api -X POST "$API/admin/releases" -d "$(jq -nc --argjson c "$code" --arg v "$ver" --arg u "https://$DOMAIN/download/$file" --arg s "$sha" \
    '{versionCode:$c, versionName:$v, apkUrl:$u, sha256:$s, notes:"", mandatory:false}')" >/dev/null && ok "Apps will offer this update"
  sed -i "s/^APP_BUILD=.*/APP_BUILD=$build/" "$DIR/settings.env"; APP_BUILD=$build
  APK_URL="https://$DOMAIN/download/$SLUG.apk"
  ok "App ready: $APK_URL"
  tg_send "$VPN_NAME $ver is ready: $APK_URL"
}

if [ $UPDATE = 0 ] && [ -n "${LOGO:-}" ]; then
  case "$LOGO" in https://*) curl -fsSL "$LOGO" -o "$DIR/downloads/logo.png" || warn "Could not download the logo (later: $CLI logo <link>)." ;;
    *) [ -f "$LOGO" ] && cp "$LOGO" "$DIR/downloads/logo.png" || warn "Logo file not found: $LOGO" ;; esac
  [ -f "$DIR/downloads/logo.png" ] && chmod 644 "$DIR/downloads/logo.png"
fi
if [ "${BUILD_APP_ONLY:-0}" = 1 ] || [ $UPDATE = 0 ] || { [ -n "${GH_REPO:-}" ] && [ -n "$APP_SRC_NEW" ] && [ "${APP_SRC_VER:-}" != "$APP_SRC_NEW" ]; }; then
  if [ -n "${GITHUB_TOKEN:-}" ]; then build_app "$GITHUB_TOKEN" || true
  elif [ "${BUILD_APP_ONLY:-0}" = 1 ]; then warn "No GitHub token yet: $CLI set-token"; fi
fi

# ----------------------------------------------------------------------------- backup now (first run / new key)
if [ $UPDATE = 0 ] || [ -n "${NEW_KEY:-}" ] || [ -n "${NEW_BACKUP_PASS:-}" ] || [ -z "$(ls "$DIR"/backups/backup-*.enc 2>/dev/null)" ]; then
  make_backup || true
fi

# ----------------------------------------------------------------------------- summary
{
  echo "$VPN_NAME"
  echo "Admin panel:   https://$DOMAIN/admin"
  echo "Android app:   ${APK_URL:-https://$DOMAIN/download/$SLUG.apk  (after: $CLI build-app)}"
  echo "VPN domain:    $VPN_DOMAIN$( [ "${VPN_TLS:-}" = "tls internal" ] && echo '  (Cloudflare CDN: SSL/TLS mode Full)')"
  echo "VPN servers:   VLESS/VMess WebSocket 443 (TLS) + 80, SSH WebSocket 443 (TLS) + 80, SSH 22, SSH payload proxy $PROXY_PORT"
  echo "Privacy page:  https://$DOMAIN/privacy"
  echo "Backups:       nightly, panel → Backup$( [ -n "${TG_BOT:-}" ] && echo ' + Telegram')   ($CLI backup = now)"
  echo "Server key:    $PUBKEY"
  echo "Commands:      $CLI status | logs | update | build-app | set-token | logo <link> | backup | restore <file> | info"
} > "$DIR/INFO.txt"; chmod 600 "$DIR/INFO.txt"
say "$VPN_NAME is ready"
cat "$DIR/INFO.txt"
if [ "${NEW_ADMIN:-0}" = 1 ]; then echo; cat "$DIR/ADMIN-LOGIN.txt"; echo "Write the password down (it is also in $DIR/ADMIN-LOGIN.txt)."; fi
if [ $UPDATE = 0 ] || [ -n "${NEW_BACKUP_PASS:-}" ]; then
  printf '\n\033[1;33mBACKUP PASSWORD:  %s\033[0m\n' "$BACKUP_PASS"
  echo "It opens your backups (app signing key + settings + database). Save it, then download a backup:"
  echo "  panel → Backup → Download$( [ -n "${TG_BOT:-}" ] && echo '   (it was also sent to your Telegram)')"
  echo "Without the signing key the app can never be updated again."
  if tty_ok; then
    until yesno "Saved the backup password and downloaded the backup?"; do echo "Please do it now: https://$DOMAIN/admin → Backup"; done
  fi
  tg_send "$VPN_NAME is ready. Panel: https://$DOMAIN/admin  App: ${APK_URL:-not built yet}"
fi
