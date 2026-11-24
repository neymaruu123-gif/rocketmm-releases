#!/usr/bin/env bash
# RocketMM backend installer / updater for a fresh Ubuntu or Debian VPS.
#
#   curl -fsSL https://raw.githubusercontent.com/neymaruu123-gif/rocketmm-releases/main/install-backend.sh \
#     | sudo BUNDLE_KEY=... MANIFEST_SIGNING_KEY=... bash
#
# Safe to re-run: it updates the code and keeps the database, secrets and certificates.
# It refuses to start (and changes nothing) if ports 80/443 are used by something else.
#
# Moving to a new server (same domain, apps keep working): copy the old server's .env and a
# `rocketmm backup` file to the new one, then run with
#   RESTORE_ENV=/root/rocketmm-backup/.env RESTORE_SQL=/root/rocketmm-backup/backup-....sql.gz
# (only on a server without RocketMM yet), and point the domain's DNS to the new IP.
set -euo pipefail

DOMAIN=${DOMAIN:-yethiha101.dpdns.org}
DIR=${ROCKETMM_DIR:-/opt/rocketmm}
BUNDLE_URL=${BUNDLE_URL:-https://raw.githubusercontent.com/neymaruu123-gif/rocketmm-releases/main/backend-bundle.enc}
# Prebuilt backend image (encrypted like the bundle), so small servers need not run npm/TypeScript builds.
IMAGE_BASE=${IMAGE_BASE:-https://raw.githubusercontent.com/neymaruu123-gif/rocketmm-releases/backend-image}
ADMIN_EMAIL=${ADMIN_EMAIL:-admin@$DOMAIN}
HTTP_PORT=${HTTP_PORT:-80}
HTTPS_PORT=${HTTPS_PORT:-443}

say()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
fail() { printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || fail "Run as root (use sudo)."
command -v curl >/dev/null || { apt-get update -qq && apt-get install -y -qq curl; }
command -v openssl >/dev/null || apt-get install -y -qq openssl

compose() { docker compose --project-directory "$DIR" -p rocketmm "$@"; }

# ---- 1. ports: never disturb another service (e.g. a VPN) that already owns 80/443
port_owner() { ss -ltnpH "sport = :$1" 2>/dev/null | head -1; }
ours_running=0
if command -v docker >/dev/null && [ -f "$DIR/docker-compose.yml" ] && compose ps -q caddy 2>/dev/null | grep -q .; then ours_running=1; fi
if [ $ours_running = 0 ]; then
  for p in "$HTTP_PORT" "$HTTPS_PORT"; do
    o=$(port_owner "$p")
    [ -z "$o" ] || fail "Port $p is already in use on this server:
  $o
RocketMM needs ports 80 and 443 for HTTPS. Nothing was changed. Use a VPS where these ports are free,
or stop that service first."
  done
fi

# ---- 2. the signing key decides which apps accept this server: check it before touching anything
if [ -n "${RESTORE_ENV:-}${RESTORE_SQL:-}" ]; then
  [ ! -f "$DIR/.env" ] || fail "RESTORE_ENV/RESTORE_SQL are only for a new server, but $DIR/.env already exists here.
To load a backup into this server use:  rocketmm restore <backup.sql.gz>"
  [ -n "${RESTORE_ENV:-}" ] && [ -f "$RESTORE_ENV" ] || fail "RESTORE_ENV must point to the old server's .env file (it holds the keys)."
  grep -q '^MANIFEST_SIGNING_KEY=.\+' "$RESTORE_ENV" || fail "$RESTORE_ENV has no MANIFEST_SIGNING_KEY - is it the right file?"
  grep -q '^SECRETS_KEY=.\+' "$RESTORE_ENV" || fail "$RESTORE_ENV has no SECRETS_KEY - is it the right file?"
  [ -z "${RESTORE_SQL:-}" ] || [ -f "$RESTORE_SQL" ] || fail "RESTORE_SQL not found: $RESTORE_SQL"
  [ -z "${RESTORE_SQL:-}" ] || gzip -t "$RESTORE_SQL" 2>/dev/null || fail "RESTORE_SQL is not a valid .sql.gz backup."
elif [ -f "$DIR/.env" ] && grep -q '^MANIFEST_SIGNING_KEY=.\+' "$DIR/.env"; then
  : # already configured; keep it
else
  [ -n "${MANIFEST_SIGNING_KEY:-}" ] || fail "MANIFEST_SIGNING_KEY is required on first install (from rocketmm-manifest-signing-key.txt)."
  [ "$(printf %s "$MANIFEST_SIGNING_KEY" | base64 -d 2>/dev/null | wc -c)" = 32 ] || fail "MANIFEST_SIGNING_KEY is not a valid key (expected 32 bytes, base64)."
fi
# Either an uploaded plain bundle (BUNDLE_FILE=/path/rocketmm-backend.tgz) or the encrypted download.
[ -n "${BUNDLE_FILE:-}" ] || [ -n "${BUNDLE_KEY:-}" ] || fail "BUNDLE_KEY (download) or BUNDLE_FILE (uploaded bundle) is required."
[ -z "${BUNDLE_FILE:-}" ] || [ -f "$BUNDLE_FILE" ] || fail "BUNDLE_FILE not found: $BUNDLE_FILE"

# ---- 3. docker
if ! command -v docker >/dev/null || ! docker compose version >/dev/null 2>&1; then
  say "Installing Docker"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq docker.io docker-compose-v2 >/dev/null 2>&1 || curl -fsSL https://get.docker.com | sh
  systemctl enable --now docker >/dev/null 2>&1 || true
fi
docker compose version >/dev/null 2>&1 || fail "Docker Compose could not be installed."

# ---- 4. code: download, decrypt, unpack (database, .env and certificates are untouched)
say "Unpacking RocketMM backend"
mkdir -p "$DIR"; chmod 700 "$DIR"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
if [ -n "${BUNDLE_FILE:-}" ]; then
  cp "$BUNDLE_FILE" "$tmp/bundle.tgz"
else
  curl -fsSL "$BUNDLE_URL" -o "$tmp/bundle.enc" || fail "Could not download the backend bundle."
  BUNDLE_KEY="$BUNDLE_KEY" openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -pass env:BUNDLE_KEY -in "$tmp/bundle.enc" -out "$tmp/bundle.tgz" 2>/dev/null \
    || fail "Could not decrypt the bundle: BUNDLE_KEY is wrong."
fi
tar -xzf "$tmp/bundle.tgz" -C "$tmp" || fail "The bundle is corrupted."
rm -rf "$DIR/backend.new"; mv "$tmp/bundle/backend" "$DIR/backend.new"
rm -rf "$DIR/backend.old"; [ -d "$DIR/backend" ] && mv "$DIR/backend" "$DIR/backend.old"
mv "$DIR/backend.new" "$DIR/backend"
cp "$tmp/bundle/docker-compose.yml" "$tmp/bundle/Caddyfile" "$DIR/"
cp "$tmp/bundle/VERSION" "$DIR/VERSION" 2>/dev/null || true

# ---- 5. secrets: generated once on this server, never leave it (or moved from the old server)
if [ ! -f "$DIR/.env" ] && [ -n "${RESTORE_ENV:-}" ]; then
  say "Using the keys from the old server"
  umask 077
  cp "$RESTORE_ENV" "$DIR/.env"
  sed -i "s/^HTTP_PORT=.*/HTTP_PORT=$HTTP_PORT/; s/^HTTPS_PORT=.*/HTTPS_PORT=$HTTPS_PORT/" "$DIR/.env"
fi
if [ ! -f "$DIR/.env" ]; then
  say "Generating secrets"
  umask 077
  cat > "$DIR/.env" <<ENV
DOMAIN=$DOMAIN
HTTP_PORT=$HTTP_PORT
HTTPS_PORT=$HTTPS_PORT
CADDY_TLS=${CADDY_TLS:-}
POSTGRES_PASSWORD=$(openssl rand -hex 24)
JWT_SECRET=$(openssl rand -hex 48)
SECRETS_KEY=$(openssl rand -base64 32)
MANIFEST_SIGNING_KEY=$MANIFEST_SIGNING_KEY
ENV
fi
chmod 600 "$DIR/.env"

# ---- 5b. backend image: download the prebuilt one for this exact version (fallback: build here)
VER=$(cat "$DIR/VERSION" 2>/dev/null || echo local)
use_prebuilt=0
if docker image inspect "rocketmm-backend:$VER" >/dev/null 2>&1; then
  use_prebuilt=1
elif [ -n "${IMAGE_FILE:-}" ]; then
  say "Loading the backend image"
  gunzip -c "$IMAGE_FILE" | docker load >/dev/null && use_prebuilt=1
elif [ -n "${BUNDLE_KEY:-}" ] && [ -z "${ROCKETMM_FORCE_BUILD:-}" ]; then
  say "Downloading the prebuilt backend ($VER)"
  # stored as <90 MB parts (GitHub file limit): rocketmm-backend-<ver>.enc.part-aa, -ab, …
  : > "$tmp/image.enc"
  for p in aa ab ac ad ae af ag ah; do
    curl -fsL --retry 3 "$IMAGE_BASE/rocketmm-backend-$VER.enc.part-$p" >> "$tmp/image.enc" 2>/dev/null || break
  done
  if [ -s "$tmp/image.enc" ] \
     && BUNDLE_KEY="$BUNDLE_KEY" openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -pass env:BUNDLE_KEY -in "$tmp/image.enc" 2>/dev/null | gunzip -c | docker load >/dev/null; then
    use_prebuilt=1
  else
    echo "No prebuilt image for $VER - building on this server instead (needs ~1.5 GB RAM incl. swap)."
  fi
  rm -f "$tmp/image.enc"
fi
docker image inspect "rocketmm-backend:$VER" >/dev/null 2>&1 || use_prebuilt=0
if grep -q '^BACKEND_TAG=' "$DIR/.env"; then sed -i "s/^BACKEND_TAG=.*/BACKEND_TAG=$VER/" "$DIR/.env"; else echo "BACKEND_TAG=$VER" >> "$DIR/.env"; fi
export BACKEND_TAG=$VER

# ---- 6. start
if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q 'Status: active'; then
  ufw allow "$HTTP_PORT"/tcp >/dev/null; ufw allow "$HTTPS_PORT"/tcp >/dev/null
fi
say "Building and starting (first time takes a few minutes)"
build_flag=--build; [ -z "${ROCKETMM_NO_BUILD:-}" ] && [ $use_prebuilt = 0 ] || build_flag=--no-build
if [ -n "${RESTORE_SQL:-}" ]; then
  say "Restoring the database backup"
  compose --env-file "$DIR/.env" up -d db
  for i in $(seq 1 40); do compose exec -T db pg_isready -U rocketmm -d rocketmm >/dev/null 2>&1 && break; sleep 2; done
  tables=$(compose exec -T db psql -U rocketmm -d rocketmm -tAc "select count(*) from information_schema.tables where table_schema='public'")
  [ "${tables//[[:space:]]/}" = 0 ] || fail "The database on this server is not empty; nothing was restored."
  gunzip -c "$RESTORE_SQL" | compose exec -T db psql -U rocketmm -d rocketmm -v ON_ERROR_STOP=1 -q >/dev/null \
    || fail "Restoring $RESTORE_SQL failed (see the error above)."
  touch "$DIR/.admin-created"   # the admin accounts came with the backup
  echo "restored: $(compose exec -T db psql -U rocketmm -d rocketmm -tAc 'select count(*) from "Server"') servers, $(compose exec -T db psql -U rocketmm -d rocketmm -tAc 'select count(*) from "Subscription"') codes/tokens"
fi
compose --env-file "$DIR/.env" up -d $build_flag --remove-orphans
say "Waiting for the backend"
ok=0
for i in $(seq 1 60); do
  if [ "$(docker inspect -f '{{.State.Health.Status}}' "$(compose ps -q backend)" 2>/dev/null)" = healthy ]; then ok=1; break; fi
  sleep 3
done
[ $ok = 1 ] || { compose logs --tail 40 backend; fail "The backend did not become healthy. The log above shows why."; }

# ---- 7. first admin account (random password, shown once and kept in a root-only file)
if [ ! -f "$DIR/.admin-created" ]; then
  pw=$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-20)
  compose exec -T -e ADMIN_PASSWORD="$pw" backend node dist/scripts/create-admin.js "$ADMIN_EMAIL" admin >/dev/null
  umask 077
  printf 'Dashboard: https://%s/admin\nEmail:     %s\nPassword:  %s\n' "$DOMAIN" "$ADMIN_EMAIL" "$pw" > "$DIR/ADMIN-LOGIN.txt"
  touch "$DIR/.admin-created"
  NEW_ADMIN=1
fi

# ---- 8. helper commands
cat > /usr/local/bin/rocketmm <<HELP
#!/usr/bin/env bash
# rocketmm status | logs | restart | backup | restore <file> | add-admin <email> [admin|editor|viewer]
cd "$DIR"; c() { docker compose --project-directory "$DIR" -p rocketmm --env-file "$DIR/.env" "\$@"; }
case "\${1:-status}" in
  status)  c ps ;;
  logs)    c logs --tail "\${2:-100}" -f backend ;;
  restart) c restart ;;
  backup)  f="$DIR/backup-\$(date +%Y%m%d-%H%M%S).sql.gz"; c exec -T db pg_dump -U rocketmm rocketmm | gzip > "\$f"; chmod 600 "\$f"; echo "saved \$f (also back up $DIR/.env: it holds the keys that decrypt it)" ;;
  restore) [ -f "\${2:-}" ] || { echo "usage: rocketmm restore <backup.sql.gz>"; exit 2; }
           read -r -p "This REPLACES everything in the database with \$2. Type yes: " a; [ "\$a" = yes ] || exit 1
           c stop backend && c exec -T db psql -U rocketmm -d rocketmm -qc 'drop schema public cascade; create schema public;' \
             && gunzip -c "\$2" | c exec -T db psql -U rocketmm -d rocketmm -v ON_ERROR_STOP=1 -q >/dev/null && c start backend && echo restored ;;
  add-admin) [ -n "\${2:-}" ] || { echo "usage: rocketmm add-admin <email> [role]"; exit 2; }; pw=\$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-20); c exec -T -e ADMIN_PASSWORD="\$pw" backend node dist/scripts/create-admin.js "\$2" "\${3:-admin}" && echo "password: \$pw" ;;
  *) echo "usage: rocketmm status|logs|restart|backup|restore <file>|add-admin <email> [role]" ;;
esac
HELP
chmod +x /usr/local/bin/rocketmm

say "RocketMM backend is running (version $(cat "$DIR/VERSION" 2>/dev/null || echo unknown))"
echo "Dashboard:  https://$DOMAIN/admin"
if [ "${NEW_ADMIN:-0}" = 1 ]; then
  echo; cat "$DIR/ADMIN-LOGIN.txt"
  echo; echo "Write the password down, then delete the file:  rm $DIR/ADMIN-LOGIN.txt"
fi
echo
echo "The HTTPS certificate is issued on the first visit; if the page does not open within a minute,"
echo "check that $DOMAIN points to this server's IP.   Commands: rocketmm status | logs | backup"
