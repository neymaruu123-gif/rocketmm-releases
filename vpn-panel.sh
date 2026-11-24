#!/usr/bin/env bash
# =============================================================================
#  All-in-one VPN server installer (Ubuntu 22.04 / 24.04, Debian 12)
#
#  One run on a fresh VPS sets up, under YOUR VPN's name and YOUR domain:
#    - the admin panel (servers, VIP codes, free plan, app updates)   https://<domain>/admin
#    - V2ray: VLESS + VMess over WebSocket on ports 443 (TLS) and 80
#    - SSH: WebSocket/HTTP payload on 443 (TLS) and 80, and plain SSH on 22
#    - adds all of these to the panel and publishes them to the app
#    - optionally builds your Android app on GitHub and hosts it at https://<domain>/download/
#
#  Run as root:   bash vpn-panel.sh            (asks a few questions)
#  Re-run it later to update; your data, keys and settings are kept.
#  Non-interactive (tests): VPN_NAME, PANEL_DOMAIN, ADMIN_EMAIL, VIP_URL, COUNTRY, LOGO, GITHUB_TOKEN,
#  BUNDLE_KEY (or BUNDLE_FILE + IMAGE_FILE), CADDY_TLS, ASSUME_YES=1.
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
  ask VPN_NAME "VPN app name (e.g. Light VPN)"
  VPN_NAME="$(printf '%s' "$VPN_NAME" | tr -d '"\\$`' | sed 's/^ *//; s/ *$//')"
  [ -n "$VPN_NAME" ] || fail "A name is needed."
  SLUG="$(slugify "$VPN_NAME")"; [ -n "$SLUG" ] || fail "The name needs at least one letter or digit."
  case "$SLUG" in [a-z]*) ;; *) SLUG="vpn$SLUG" ;; esac
  SLUG="$(printf '%s' "$SLUG" | cut -c1-24)"
  ask PANEL_DOMAIN "Domain for the admin panel and the VPN (e.g. vpn.example.com)"
  PANEL_DOMAIN="$(printf '%s' "$PANEL_DOMAIN" | tr '[:upper:]' '[:lower:]' | sed 's#^https\?://##; s#/.*$##')"
  printf '%s' "$PANEL_DOMAIN" | grep -Eq '^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$|^localhost$' || fail "\"$PANEL_DOMAIN\" is not a domain name."
  ask ADMIN_EMAIL "Admin login email" "admin@$PANEL_DOMAIN"
  ask VIP_URL "Telegram link for buying VIP (e.g. https://t.me/yourname)" ""
  VIP_URL="$(printf '%s' "$VIP_URL" | sed 's#t\.me/@#t.me/#')"
  guess="$(curl -fsS --max-time 5 https://ipinfo.io/country 2>/dev/null | tr -cd 'A-Z' | cut -c1-2 || true)"
  ask COUNTRY "Server country code (2 letters, for the flag)" "${guess:-SG}"
  COUNTRY="$(printf '%s' "$COUNTRY" | tr '[:lower:]' '[:upper:]' | tr -cd 'A-Z' | cut -c1-2)"
  DIR="/opt/$SLUG"
  CLI="$SLUG"; if command -v "$CLI" >/dev/null 2>&1 && ! grep -q 'vpn-panel' "$(command -v "$CLI")" 2>/dev/null; then CLI="$SLUG-panel"; fi
fi
DOMAIN="$PANEL_DOMAIN"
compose() { docker compose --project-directory "$DIR" -p "$SLUG" --env-file "$DIR/.env" -f "$DIR/compose.yml" "$@"; }

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
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
if [ -n "${BUNDLE_FILE:-}" ]; then cp "$BUNDLE_FILE" "$tmp/bundle.tgz"
else
  curl -fsSL --retry 3 "$BUNDLE_URL" -o "$tmp/bundle.enc" || fail "Download failed (check the internet connection)."
  BUNDLE_KEY="$BUNDLE_KEY" openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -pass env:BUNDLE_KEY -in "$tmp/bundle.enc" -out "$tmp/bundle.tgz" 2>/dev/null \
    || fail "BUNDLE_KEY is wrong."
fi
tar -xzf "$tmp/bundle.tgz" -C "$tmp" || fail "The download is corrupted. Run again."
[ -d "$tmp/bundle/allinone" ] || fail "This download is too old for the all-in-one setup."
cp "$tmp/bundle/allinone/compose.yml" "$tmp/bundle/allinone/Caddyfile" "$tmp/bundle/allinone/sshws.py" "$DIR/"
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
EOF
  cat > "$DIR/.env" <<EOF
VPN_NAME="$VPN_NAME"
DOMAIN=$DOMAIN
ADMIN_EMAIL=$ADMIN_EMAIL
CADDY_TLS=${CADDY_TLS:-}
POSTGRES_PASSWORD=$(rand 40)
JWT_SECRET=$(rand 64)
SECRETS_KEY=$(openssl rand -base64 32)
MANIFEST_SIGNING_KEY=$(openssl rand -base64 32)
EOF
  printf 'DIR=%s\nSLUG=%s\n' "$DIR" "$SLUG" > "$CONF"
fi
chmod 600 "$DIR/settings.env" "$DIR/.env"
# shellcheck disable=SC1091
. "$DIR/settings.env"
for k in BACKEND_IMAGE VLESS_PATH VMESS_PATH SSH_PATH API_PORT; do sed -i "/^$k=/d" "$DIR/.env"; done
printf 'BACKEND_IMAGE=%s\nVLESS_PATH=%s\nVMESS_PATH=%s\nSSH_PATH=%s\nAPI_PORT=%s\n' "$IMAGE" "$VLESS_PATH" "$VMESS_PATH" "$SSH_PATH" "$API_PORT" >> "$DIR/.env"

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
if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q 'Status: active'; then ufw allow 80/tcp >/dev/null; ufw allow 443/tcp >/dev/null; ufw allow 22/tcp >/dev/null; fi
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
  p443="$(api -X POST "$API/admin/payloads" -d "$(jq -nc --arg p "$payload" --arg s "$DOMAIN" '{name:"SSH WebSocket TLS",transport:"tls-payload",payload:$p,sni:$s}')" | jq -r .id)"
  add() { api -X POST "$API/admin/servers" -d "$1" >/dev/null && ok "$(printf '%s' "$1" | jq -r .name)"; }
  base() { jq -nc --arg n "$1" --arg h "$DOMAIN" --argjson port "$2" --arg c "$COUNTRY" --argjson o "$3" \
    '{name:$n,host:$h,port:$port,group:"free",country:(if $c=="" then null else $c end),sortOrder:$o}'; }
  xr() { # name port proto tls order
    base "$1" "$2" "$5" | jq -c --arg proto "$3" --arg path "$( [ "$3" = vless ] && echo "$VLESS_PATH" || echo "$VMESS_PATH")" --arg h "$DOMAIN" \
      --arg sec "$4" --arg id "$XRAY_UUID" '. + {protocol:$proto, xray:({network:"ws",path:$path,host:$h,security:$sec} + (if $sec=="tls" then {sni:$h} else {} end)
        + (if $proto=="vmess" then {vmessSecurity:"auto"} else {} end)), secrets:{userId:$id}}'; }
  sh_() { # name port transport payloadId order
    base "$1" "$2" "$5" | jq -c --arg t "$3" --arg pid "$4" --arg h "$DOMAIN" --arg u "$SSH_USER" --arg pw "$SSH_PASS" \
      '. + {protocol:"ssh", ssh:({transport:$t} + (if ($t|startswith("tls")) then {sni:$h} else {} end)), secrets:{username:$u,password:$pw}}
        + (if $pid=="" then {} else {payloadId:$pid} end)'; }
  add "$(xr 'VLESS · 443' 443 vless tls 1)"
  add "$(xr 'VMess · 443' 443 vmess tls 2)"
  add "$(sh_ 'SSH WS · 443' 443 tls-payload "$p443" 3)"
  add "$(xr 'VLESS · 80' 80 vless none 4)"
  add "$(xr 'VMess · 80' 80 vmess none 5)"
  add "$(sh_ 'SSH WS · 80' 80 payload "$p80" 6)"
  add "$(sh_ 'SSH · 22' 22 direct '' 7)"
  api -X POST "$API/admin/publish" -d '{"note":"first setup"}' >/dev/null && ok "Published to the app"
  touch "$DIR/.setup-done"
  NEW_ADMIN=1
fi

# ----------------------------------------------------------------------------- helper command
cat > "/usr/local/bin/$CLI" <<EOF
#!/usr/bin/env bash
# vpn-panel helper for $VPN_NAME:  $CLI status | logs | restart | update | backup | restore <file> | add-admin <email> | build-app | info
DIR="$DIR"; c() { docker compose --project-directory "\$DIR" -p "$SLUG" --env-file "\$DIR/.env" -f "\$DIR/compose.yml" "\$@"; }
case "\${1:-status}" in
  status)    c ps ;;
  logs)      c logs --tail "\${2:-100}" -f "\${3:-backend}" ;;
  restart)   c restart ;;
  update)    curl -fsSL "$INSTALLER_URL" -o "\$DIR/vpn-panel.sh.new" && mv "\$DIR/vpn-panel.sh.new" "\$DIR/vpn-panel.sh"
             BUNDLE_KEY="\${BUNDLE_KEY:-\$(cat "\$DIR/.bundle-key" 2>/dev/null)}" bash "\$DIR/vpn-panel.sh" ;;
  build-app) BUNDLE_KEY="\${BUNDLE_KEY:-\$(cat "\$DIR/.bundle-key" 2>/dev/null)}" BUILD_APP_ONLY=1 bash "\$DIR/vpn-panel.sh" ;;
  backup)    f="\$DIR/backup-\$(date +%Y%m%d-%H%M%S).sql.gz"; c exec -T db pg_dump -U vpn vpn | gzip > "\$f"; chmod 600 "\$f"
             echo "saved \$f  (also keep \$DIR/.env and \$DIR/settings.env and \$DIR/app/ — they hold the keys)" ;;
  restore)   [ -f "\${2:-}" ] || { echo "usage: $CLI restore <backup.sql.gz>"; exit 2; }
             read -r -p "This REPLACES everything in the database with \$2. Type yes: " a; [ "\$a" = yes ] || exit 1
             c stop backend && c exec -T db psql -U vpn -d vpn -qc 'drop schema public cascade; create schema public;' \\
               && gunzip -c "\$2" | c exec -T db psql -U vpn -d vpn -v ON_ERROR_STOP=1 -q >/dev/null && c start backend && echo restored ;;
  add-admin) [ -n "\${2:-}" ] || { echo "usage: $CLI add-admin <email>"; exit 2; }
             pw=\$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-16); c exec -T -e ADMIN_PASSWORD="\$pw" backend node dist/scripts/create-admin.js "\$2" "\${3:-admin}" && echo "password: \$pw" ;;
  info)      cat "\$DIR/INFO.txt" ;;
  *)         echo "usage: $CLI status | logs | restart | update | backup | restore <file> | add-admin <email> | build-app | info" ;;
esac
EOF
chmod 755 "/usr/local/bin/$CLI"
[ -n "${BUNDLE_KEY:-}" ] && { umask 077; printf '%s' "$BUNDLE_KEY" > "$DIR/.bundle-key"; }

# ----------------------------------------------------------------------------- app (APK) built on GitHub
PUBKEY="$(api "$API/servers/signing-key" | jq -r .publicKey)"
build_app() {
  local tok="$1" ks="$DIR/app/release.p12" kp
  say "Building the $VPN_NAME Android app on GitHub (10-20 minutes)"
  if [ ! -f "$ks" ]; then  # signing key: made once, kept on this server (back it up!)
    kp="$(rand 24)"
    openssl ecparam -name prime256v1 -genkey -noout -out "$tmp/k.pem" 2>/dev/null
    openssl req -new -x509 -key "$tmp/k.pem" -out "$tmp/c.pem" -days 10000 -subj "/CN=$VPN_NAME" 2>/dev/null
    openssl pkcs12 -export -inkey "$tmp/k.pem" -in "$tmp/c.pem" -name app -out "$ks" -passout "pass:$kp" \
      -keypbe AES-256-CBC -certpbe AES-256-CBC -macalg sha256 2>/dev/null
    printf '%s' "$kp" > "$DIR/app/release.password"; chmod 600 "$ks" "$DIR/app/release.password"
  fi
  kp="$(cat "$DIR/app/release.password")"
  local build=$((APP_BUILD + 1)) code ver logo="" gh="https://api.github.com/repos/$APP_REPO"
  code=$((1000 + build)); ver="1.0.$build"
  [ -f "$DIR/downloads/logo.png" ] && logo="https://$DOMAIN/download/logo.png"
  local inputs; inputs="$(jq -nc --arg name "$VPN_NAME" --arg id "$APP_ID" --arg backend "https://$DOMAIN" --arg key "$PUBKEY" \
    --arg vip "$VIP_URL" --arg logo "$logo" --arg ver "$ver" --arg code "$code" --arg ks "$(base64 -w0 "$ks")" --arg kp "$kp" \
    '{name:$name, app_id:$id, backend:$backend, manifest_key:$key, vip_url:$vip, logo_url:$logo, version_name:$ver, version_code:$code, keystore:$ks, keystore_password:$kp}')"
  local started; started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  curl -fsS -X POST -H "Authorization: Bearer $tok" -H 'Accept: application/vnd.github+json' "$gh/actions/workflows/build-app.yml/dispatches" \
    -d "$(jq -nc --arg ref "$APP_REF" --argjson i "$inputs" '{ref:$ref, inputs:$i}')" \
    || { warn "GitHub refused the build (check the token: it needs Actions read/write + Contents read on $APP_REPO)."; return 1; }
  local run="" st="" concl=""
  for i in $(seq 1 20); do
    sleep 6
    run="$(curl -fsS -H "Authorization: Bearer $tok" "$gh/actions/workflows/build-app.yml/runs?event=workflow_dispatch&created=%3E%3D$started&per_page=1" | jq -r '.workflow_runs[0].id // empty')"
    [ -n "$run" ] && break
  done
  [ -n "$run" ] || { warn "The build did not start on GitHub."; return 1; }
  printf 'GitHub build %s ' "$run"
  for i in $(seq 1 180); do
    read -r st concl < <(curl -fsS -H "Authorization: Bearer $tok" "$gh/actions/runs/$run" | jq -r '"\(.status) \(.conclusion)"')
    [ "$st" = completed ] && break; printf '.'; sleep 10
  done; echo
  [ "$concl" = success ] || { warn "The app build failed on GitHub (run $run)."; return 1; }
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
}

if [ "${BUILD_APP_ONLY:-0}" = 1 ] || [ $UPDATE = 0 ]; then
  if [ $UPDATE = 0 ]; then
    ask LOGO "Logo PNG for the app (path on this server or an https link; empty = default rocket)" ""
    if [ -n "$LOGO" ]; then
      case "$LOGO" in https://*) curl -fsSL "$LOGO" -o "$DIR/downloads/logo.png" || warn "Could not download the logo." ;;
        *) [ -f "$LOGO" ] && cp "$LOGO" "$DIR/downloads/logo.png" || warn "Logo file not found: $LOGO" ;; esac
      [ -f "$DIR/downloads/logo.png" ] && chmod 644 "$DIR/downloads/logo.png"
    fi
    printf '\nThe Android app can be built for you on GitHub now. It needs a GitHub token once\n'
    printf '(github.com → Settings → Developer settings → Fine-grained tokens → repository %s,\n' "$APP_REPO"
    printf ' permissions: Actions = Read and write, Contents = Read). Leave empty to skip; later: %s build-app\n' "$CLI"
  fi
  ask GITHUB_TOKEN "GitHub token" ""
  if [ -n "$GITHUB_TOKEN" ]; then build_app "$GITHUB_TOKEN" || true; fi
fi

# ----------------------------------------------------------------------------- summary
{
  echo "$VPN_NAME"
  echo "Admin panel:   https://$DOMAIN/admin"
  echo "Android app:   ${APK_URL:-https://$DOMAIN/download/$SLUG.apk  (after: $CLI build-app)}"
  echo "Server key:    $PUBKEY"
  echo "VPN servers:   VLESS/VMess WebSocket 443 (TLS) + 80, SSH WebSocket 443 (TLS) + 80, SSH 22"
  echo "Commands:      $CLI status | logs | update | backup | build-app | info"
  echo "Back up:       $DIR/.env  $DIR/settings.env  $DIR/app/  (keys — without them the app can't be updated)"
} > "$DIR/INFO.txt"; chmod 600 "$DIR/INFO.txt"
say "$VPN_NAME is ready"
cat "$DIR/INFO.txt"
if [ "${NEW_ADMIN:-0}" = 1 ]; then echo; cat "$DIR/ADMIN-LOGIN.txt"; echo "Write the password down (it is also in $DIR/ADMIN-LOGIN.txt)."; fi
