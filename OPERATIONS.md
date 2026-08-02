# Operations

Day-2 reference. Example values: `matrix.example.com`, host `192.168.1.10`,
media IPs `192.168.1.241`/`.242`.

## Everyday commands

```bash
docker compose up -d                    # start/reconcile the stack
docker compose logs -f synapse|livekit|coturn

# Create a user (interactive; answer admin y/n)
docker exec -it family-matrix-synapse-1 register_new_matrix_user -c /data/homeserver.yaml http://localhost:8008

# Database shell
docker exec family-matrix-db-1 psql -U synapse -d synapse

# Ephemeral TURN credentials for the trickle-ICE test page
u=$(( $(date +%s) + 3600 )); p=$(printf '%s' "$u" | openssl dgst -sha1 -hmac "$TURN_STATIC_SECRET" -binary | base64); echo "$u / $p"
```

## Files, ownership, and editing gotchas

| Path | Owner | Notes |
|---|---|---|
| `.env` | you (mode 600) | The identity + secret source of truth. Most secrets are ALSO rendered as literals into the configs below — after changing one, `./setup.sh --force` + restart the affected service. |
| `files/` (homeserver.yaml, signing key, media) | **uid 991** | Synapse runs non-root as 991. Edit via `docker run --rm -v ./files:/f alpine sh -c '...'` — never chown the tree to yourself. `homeserver.yaml` is mode 600. |
| `schemas/` | uid 70 | Postgres data (postgres-18 layout: DB lives in `schemas/18/docker/`). Never touch. |
| `coturn/turnserver.conf` | **uid 65534** (mode 400) | Embeds `TURN_STATIC_SECRET` + your **WAN IP** — locked to the coturn container's uid. Don't hand-edit: change `.env`, `./setup.sh --force`, restart coturn. Re-render on IP change and update the TURN A record. |
| `synapse-admin-config.json` | you | Consumed by the **etkecc fork**, which serves from `/var/public` on `:8080` and takes `{"restrictBaseUrl": "..."}`. Mounting it at the old `/app/config.json` path silently serves an empty config (panel loads but won't pin your homeserver). |
| `livekit/livekit.yaml` | you | Contains **no secrets** (the API key rides the `LIVEKIT_KEYS` env var). `interfaces.includes: [eth0]` assumes the macvlan attach is eth0 in-container; verify with `docker exec family-matrix-livekit-1 cat /proc/net/route` if calls won't establish. |

**Rotating a secret** = edit it in `.env` (or blank it and let setup regenerate)
→ `./setup.sh --force` → restart the services that consume it. Exceptions:
`LIVEKIT_API_SECRET` is env-injected, not rendered — just
`docker compose up -d livekit lk-jwt` after editing. Note rotating
`SYNAPSE_MACAROON_KEY` logs every user out (passwords unaffected).

## Backups and restore

```bash
./backup.sh     # pg_dump + media tar → $BACKUP_DIR, 14-day retention
# cron: 30 3 * * * /path/to/family-matrix-server/backup.sh >> /path/to/family-matrix-server/backup.log 2>&1
```

`$BACKUP_DIR` on the same machine is **not** a complete backup strategy —
push it offsite (restic/kopia → B2/S3) and test restores quarterly.

**Restore** (fresh host: run `./setup.sh` first so configs/keys exist — note
a *restored* server needs the ORIGINAL signing key and secrets from your
backups of `.env` + `files/`, so back those up too):

```bash
docker compose stop synapse
docker cp "$BACKUP_DIR/synapse-YYYY-MM-DD.dump" family-matrix-db-1:/tmp/
docker exec family-matrix-db-1 pg_restore -U synapse -d synapse --clean --if-exists /tmp/synapse-YYYY-MM-DD.dump
tar xzf "$BACKUP_DIR/media-YYYY-MM-DD.tar.gz" -C ./files/
docker run --rm -v ./files:/f alpine chown -R 991:991 /f
docker compose start synapse
```

## Troubleshooting

| Symptom | Check / fix |
|---|---|
| db container exits immediately; logs mention "PostgreSQL data in … unused mount/volume" or `pg_ctlcluster` | The postgres-18 image stores data under `/var/lib/postgresql` (compose mounts `./schemas` there). If you're upgrading a deployment created when this template ran postgres 17 (`./schemas` has `PG_VERSION` at its top level), that's pre-18 data: dump with the old image, then restore into a fresh `schemas/` — or run `pg_upgrade`. See the postgres image docs. |
| Calls fail: "unable to create room on SFU" | `docker compose logs lk-jwt`. If DNS lookup errors: local resolver negative-cached a hostname — flush it. If 404s verifying tokens: the `openid` listener resource or `serve_server_wellknown` was removed from homeserver.yaml — restore them (required even though federation is off). |
| Postgres/nginx containers crash-loop; dmesg shows `apparmor="DENIED" ... family="unix"` | Kernel/AppArmor af_unix regression — `sudo bash host-fixes.sh` (it detects and patches). |
| Remote callers connect but no media | Trickle-ICE test with ephemeral TURN creds (command above) from a phone on cellular; verify forwards point at `.241`/`.242` (container IPs, not the host) and the TURN record is grey-cloud. |
| Choppy video | Judge after the first minute (WebRTC ramps up). `chrome://webrtc-internals` on a laptop participant: `qualityLimitationReason` `cpu` = device (battery/low-power mode), `bandwidth` = wifi/uplink. Phones on 5 GHz, VPNs (Tailscale etc.) off during calls. Check host sysctls applied (`sysctl net.core.rmem_max` ≥ 16777216). |
| LAN devices can't reach `.241`/`.242` from the docker host | Expected — macvlan kernel isolation. Test from another LAN device or a container on the `lanvlan` network. |
| WAN IP changed (residential) | Two staleness surfaces: the TURN **A record** (auto-healed if you run the `ddns` profile) and coturn's **embedded `external-ip`** (not auto-healed: `./setup.sh --force` + restart coturn). LiveKit self-heals via STUN. Symptom of staleness: only remote/strict-NAT callers fail, LAN calls fine. |
| Two LAN devices can't call each other (rare) | LAN peers normally connect via direct host candidates. If those are blocked (client isolation etc.), the TURN fallback needs router NAT loopback (hairpin) to work from inside — enable it, or fix the isolation. |

## Capacity planning

- Database grows ≈ 0.6 GB per active user per year on a closed server; the
  **media store dominates** (family photo/video sharing ≈ 25–30 GB/year and
  up). Watch `du -sh files/media_store schemas`.
- The growth valve is synapse's `media_retention` setting (e.g. purge remote
  and local media older than a year) — add it to `files/homeserver.yaml` via
  the alpine-edit pattern above if disk pressure appears.
- Small-RAM hosts (4 GB): add `SYNAPSE_CACHE_FACTOR=0.25` to the synapse
  service environment, and consider compose memory limits (synapse 1g,
  postgres 1g, livekit 512m, everything else ≤256m — the stack
  idles around 2–2.5 GB resident).
- CPU is effectively never the bottleneck at family scale — an 8-person
  call is ~56 forwarded tracks and LiveKit handles ~1,600 tracks/core on
  modern hardware. Your uplink saturates first; see the sizing table in the
  README.

## Logging (quiet by default)

Nothing here keeps a routine record of who used the server, when, or from
where:

| Source | Default | What it would otherwise record |
|---|---|---|
| synapse `log.config` | root `WARNING`, access logger `ERROR` | client IP + user agent + URI, every request |
| synapse `user_ips_max_age` | `1d` (default 28d) | per-device last-seen IP/user-agent **in the database** — outlives log rotation |
| traefik | `--accesslog=false`, `--log.level=WARN` | client IP + full URI for every service |
| livekit | `level: warn` | every participant join/leave with identity |
| container logs | `local` driver, 1 MB, 1 file | unbounded stdout retained forever under `/var/lib/docker` |

**To debug**, raise the relevant one, reproduce, then put it back:

```bash
# synapse: files/<MATRIX_HOST>.log.config -> root level: INFO (edit as uid 991)
docker compose restart synapse
# livekit: livekit/livekit.yaml -> level: info|debug
docker compose restart livekit
# ICE/candidate detail for call problems lives at livekit debug level
```

For a server that keeps nothing at all, set the `x-logging` driver in
`docker-compose.yml` to `none` — you also lose the ability to see why a
container crashed, so know what you're trading.

## Update policy

Images are version-pinned on purpose. The internet-listening services
(coturn, livekit) are your priority: watch their GitHub releases plus
[matrix.org security announcements](https://matrix.org/category/security/atom.xml),
apply security releases within days, bump the rest monthly after reading
release notes. Avoid blind auto-updaters on stateful services (synapse
migrations + a mid-call restart is a bad combination).
