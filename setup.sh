#!/bin/bash
# family-matrix-server setup — renders per-deployment configs from templates/ using .env,
# generates secrets, mints the synapse signing key, and bootstraps the database.
# Idempotent: safe to re-run. Use --force to re-render existing configs
# (e.g. after rotating a secret or a WAN IP change).
set -euo pipefail
cd "$(dirname "$0")"

FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

say()  { printf '\n==> %s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# ── 0. Dependencies ─────────────────────────────────────────────────────────
command -v docker >/dev/null        || die "docker is required"
docker compose version >/dev/null 2>&1 || die "docker compose v2 is required"
command -v openssl >/dev/null       || die "openssl is required"
command -v envsubst >/dev/null      || die "envsubst is required (package: gettext-base)"

# ── 1. Load .env ────────────────────────────────────────────────────────────
if [ ! -f .env ]; then
  cp .env.example .env
  die ".env created from .env.example — edit the Identity/Network sections, then re-run ./setup.sh"
fi
set -a; . ./.env; set +a

for v in DOMAIN MATRIX_HOST RTC_HOST LIVEKIT_HOST TURN_HOST LAN_HOST_IP \
         MACVLAN_PARENT LAN_SUBNET LAN_GATEWAY MACVLAN_RANGE COTURN_IP LIVEKIT_IP \
         TRAEFIK_NETWORK CERT_RESOLVER BACKUP_DIR POSTGRES_USER POSTGRES_DB; do
  [ -n "${!v:-}" ] || die "$v is empty in .env"
done

# ── 2. WAN IP ───────────────────────────────────────────────────────────────
if [ -z "${WAN_IP:-}" ]; then
  detected=$(curl -fsS --max-time 10 https://ifconfig.me || true)
  [ -n "$detected" ] || die "could not auto-detect WAN IP; set WAN_IP in .env"
  read -r -p "Detected WAN IP: $detected — use it? [Y/n] " ans
  case "${ans:-Y}" in [Yy]*|"") WAN_IP="$detected";; *) die "set WAN_IP in .env and re-run";; esac
  sed -i "s|^WAN_IP=.*|WAN_IP=${WAN_IP}|" .env
fi
case "$WAN_IP" in
  10.*|192.168.*|100.6[4-9].*|100.[7-9]*|100.1[0-2]*|172.1[6-9].*|172.2?.*|172.3[01].*)
    echo "WARNING: $WAN_IP looks like a private/CGNAT address — remote callers will not reach you without a real public IP." ;;
esac

# ── 3. Generate missing secrets ─────────────────────────────────────────────
say "Ensuring secrets exist (blank values in .env get generated)"
for v in POSTGRES_PASSWORD TURN_STATIC_SECRET LIVEKIT_API_SECRET \
         SYNAPSE_REGISTRATION_SECRET SYNAPSE_MACAROON_KEY SYNAPSE_FORM_SECRET; do
  if [ -z "${!v:-}" ]; then
    val=$(openssl rand -hex 32)
    sed -i "s|^${v}=.*|${v}=${val}|" .env
    printf '  generated %s\n' "$v"
  fi
done
set -a; . ./.env; set +a

# ── 4. Directories ──────────────────────────────────────────────────────────
mkdir -p files coturn livekit whatsapp schemas

# ── 5. Synapse signing key (once, via synapse's own generator) ──────────────
if [ ! -f "files/${MATRIX_HOST}.signing.key" ]; then
  say "Generating synapse signing key + log config"
  docker run --rm -v "$(pwd)/files:/data" \
    -e SYNAPSE_SERVER_NAME="${MATRIX_HOST}" -e SYNAPSE_REPORT_STATS=no \
    docker.io/matrixdotorg/synapse:v1.157.2 generate >/dev/null
  # generate writes a throwaway homeserver.yaml — ours replaces it below
fi

# ── 6. Render templates ─────────────────────────────────────────────────────
VARS='${MATRIX_HOST} ${RTC_HOST} ${LIVEKIT_HOST} ${TURN_HOST} ${WAN_IP} ${LAN_HOST_IP} ${COTURN_IP} ${LIVEKIT_IP} ${POSTGRES_USER} ${POSTGRES_DB} ${POSTGRES_PASSWORD} ${TURN_STATIC_SECRET} ${LIVEKIT_API_SECRET} ${SYNAPSE_REGISTRATION_SECRET} ${SYNAPSE_MACAROON_KEY} ${SYNAPSE_FORM_SECRET}'
render() { # render <template> <dest>
  if [ -f "$2" ] && [ "$FORCE" -ne 1 ] && [ "$2" != "files/.homeserver.rendered" ]; then
    printf '  keep    %s (use --force to re-render)\n' "$2"; return 0
  fi
  envsubst "$VARS" < "$1" > "$2"
  printf '  rendered %s\n' "$2"
}
say "Rendering configs"
render templates/turnserver.conf.tmpl          coturn/turnserver.conf
render templates/livekit.yaml.tmpl             livekit/livekit.yaml
render templates/synapse-admin-config.json.tmpl synapse-admin-config.json

# homeserver.yaml lives in files/ which is owned by uid 991 — render to a
# temp file, then install with correct ownership via a throwaway container.
if [ ! -f files/.setup-rendered ] || [ "$FORCE" -eq 1 ]; then
  tmp=$(mktemp)
  envsubst "$VARS" < templates/homeserver.yaml.tmpl > "$tmp"
  docker run --rm -v "$(pwd)/files:/f" -v "$tmp:/src:ro" alpine \
    sh -c 'cp /src /f/homeserver.yaml && chown -R 991:991 /f && chmod 600 /f/homeserver.yaml && touch /f/.setup-rendered'
  rm -f "$tmp"
  printf '  rendered files/homeserver.yaml (owner 991, mode 600)\n'
else
  printf '  keep    files/homeserver.yaml (use --force to re-render)\n'
fi

# ── 7. Ingress network check ────────────────────────────────────────────────
if ! docker network inspect "${TRAEFIK_NETWORK}" >/dev/null 2>&1; then
  say "Traefik network '${TRAEFIK_NETWORK}' does not exist yet"
  echo "  Bundled ingress: cd ingress && docker compose up -d   (see ingress/README.md)"
  echo "  Own Traefik:     set TRAEFIK_NETWORK in .env to your existing network name"
  echo "  Then re-run ./setup.sh to finish database bootstrap."
  exit 0
fi

# ── 8. Database bootstrap ───────────────────────────────────────────────────
say "Starting postgres and creating databases"
docker compose up -d db
for i in $(seq 1 30); do
  docker compose ps db --format '{{.Health}}' 2>/dev/null | grep -q healthy && break
  [ "$i" -eq 30 ] && die "postgres did not become healthy in 60s — check: docker compose logs db"
  sleep 2
done
docker compose exec -T db psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -tc \
  "SELECT 1 FROM pg_database WHERE datname='mautrix_whatsapp'" | grep -q 1 || \
  docker compose exec -T db psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -c \
    "CREATE DATABASE mautrix_whatsapp OWNER ${POSTGRES_USER};"

# ── 9. Checklist ────────────────────────────────────────────────────────────
say "Setup complete. Remaining manual steps:"
cat <<CHECKLIST

  DNS (Cloudflare dashboard, zone ${DOMAIN}):
  ┌──────────────────────────────┬───────┬────────────────────────────┬─────────────────┐
  │ ${MATRIX_HOST}               │ CNAME │ <your-tunnel>.cfargotunnel │ Proxied (orange)│
  │ ${RTC_HOST}                  │ CNAME │ <your-tunnel>.cfargotunnel │ Proxied (orange)│
  │ ${LIVEKIT_HOST}              │ CNAME │ <your-tunnel>.cfargotunnel │ Proxied (orange)│
  │ ${TURN_HOST}                 │ A     │ ${WAN_IP}                  │ DNS-only (grey) │
  └──────────────────────────────┴───────┴────────────────────────────┴─────────────────┘
  (Bundled ingress: also add the three proxied hostnames to the tunnel's
   Public Hostnames, each pointing at https://traefik:443, TLS verify off.)

  Router port-forwards (all → the container IPs, NOT the docker host):
    3478   tcp+udp  → ${COTURN_IP}   (TURN)
    49152-49252 udp → ${COTURN_IP}   (TURN relay)
    7881   tcp      → ${LIVEKIT_IP}  (call media, TCP fallback)
    7882   udp      → ${LIVEKIT_IP}  (call media)

  Host tuning (UDP buffers; AppArmor patch only if needed):
    sudo bash ./host-fixes.sh

  Launch:
    docker compose up -d
    curl http://localhost:8008/health        # expect 200 (may take ~30s first boot)

  First (admin) user:
    docker exec -it family-matrix-synapse-1 register_new_matrix_user -c /data/homeserver.yaml http://localhost:8008

  Then sign in from any Element client with homeserver: ${MATRIX_HOST}
  Optional WhatsApp bridge + backups: see OPERATIONS.md
CHECKLIST
