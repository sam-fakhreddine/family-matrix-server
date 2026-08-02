# Security

Threat model, hardening inventory, and verification checklist for this
template. Read alongside [ARCHITECTURE.md](ARCHITECTURE.md) (trust
boundaries) and [OPERATIONS.md](OPERATIONS.md) (update policy, rotation).

## Threat model

**In scope** (what the design defends against):

- Internet scanners / opportunistic attackers hitting the public hostnames,
  the TURN relay, or the LiveKit media ports.
- Compromise of any single container → the blast radius is that container,
  not the host or the rest of the stack.
- Theft of a rendered config or backup file by another (non-root) user on
  the docker host.
- A lost or forgotten family device holding a live session token.

**Out of scope** (accepted by design — know what you're trusting):

- A hostile device **on your LAN**: the admin plane (`:8008`, `:8082`) is
  deliberately reachable, unauthenticated at the transport layer, over plain
  HTTP on the LAN. Anyone on the LAN can also reach synapse's client API
  directly (bypassing Cloudflare) and spoof `X-Forwarded-For` to it. The LAN
  is treated as semi-trusted; if yours isn't (roommates, IoT junk), put the
  docker host on its own VLAN or bind admin access behind a VPN.
- A root-level compromise of the docker host itself.
- Cloudflare: it terminates public TLS, so it can observe HTTP traffic
  (message *content* is protected by Matrix E2EE regardless).
- Physical access to the host / disks (use full-disk encryption if that's a
  concern).

## Hardening inventory

Every item below is enforced by the files in this repo — if you edit them,
keep these invariants:

**Containers**
- `no-new-privileges` on every service in both stacks.
- `cap_drop: [ALL]` everywhere, with minimal explicit `cap_add` only where
  required: coturn (`NET_BIND_SERVICE` — its binary carries that file
  capability), synapse-admin (nginx: `CHOWN SETGID SETUID NET_BIND_SERVICE`),
  traefik (`NET_BIND_SERVICE`).
- synapse runs as uid 991 and postgres as uid 70 directly (`user:` in
  compose) — no in-container root at any point in their lifecycle.
- Every long-running service image is version-pinned (Renovate keeps them
  current; apply security releases per the OPERATIONS.md update policy).
  The throwaway `alpine:3.24` helpers setup.sh runs for file
  ownership/install steps are pinned to the minor release — they execute
  only `cp`/`chown`/`chmod` and never stay running.

**Network**
- Admin ports bind to `${LAN_HOST_IP}`, never `0.0.0.0` — docker-published
  ports bypass ufw/firewalld, and the host may have interfaces (VPN, second
  NIC) that must not expose the admin plane.
- postgres lives on an `internal:` network with synapse — no internet
  route in either direction, nothing else can reach it.
- synapse-admin (static SPA) sits alone on its own network with a route to
  nothing.
- The public `/_synapse/*` path is 403'd at Traefik by a higher-priority
  router; the federation listener resource is absent; the federation
  whitelist is empty.
- Bundled ingress publishes **zero** inbound ports; web traffic enters only
  via the outbound Cloudflare tunnel.
- Traefik reaches the docker API through `socket-proxy` (read-only container
  listing, POST denied) over an `internal:` network — never a mounted
  `docker.sock`.

**Secrets**
- `.env` is chmod 600 (enforced on every `setup.sh` run) and gitignored.
- All secrets are 256-bit values from `openssl rand`.
- `files/homeserver.yaml` is mode 600 uid 991; `coturn/turnserver.conf` is
  mode 400 uid 65534. `livekit/livekit.yaml` contains no secrets (the API
  key is injected via the `LIVEKIT_KEYS` env var).
- Backups are written owner-only (`umask 077`, `chmod 700` on the backup
  dir) — a pg_dump contains every access token and message on the server.
- Known tradeoff: compose-injected secrets are visible in `docker inspect`
  output to anyone who can use the docker socket — on this single-admin
  host, docker access is root-equivalent anyway.

**Synapse (closed-server posture)**
- Registration, guests, public room directory, federation: all off.
- URL previews stay off (`url_preview_enabled: false`) — they are an SSRF
  primitive (the server fetches attacker-supplied URLs from inside the LAN).
  Element renders its own link previews; don't enable this casually.
- Profile data requires auth and a shared room
  (`require_auth_for_profile_requests`,
  `limit_profile_requests_to_users_who_share_rooms`).
- Devices idle for a year are logged out (`delete_stale_devices_after: 1y`).
- Synapse's default per-IP login rate limits remain in force (we don't
  override `rc_login`).

**TURN / media**
- coturn: `denied-peer-ip` covers all RFC1918/CGNAT/loopback/link-local/
  multicast/reserved space — the relay cannot be used to pivot into the LAN
  (LAN↔LAN calls use direct candidates, never TURN).
- coturn: RFC5780 NAT-discovery responses disabled
  (`no-rfc5780`, `no-stun-backward-compatibility`,
  `response-origin-only-with-rfc5780`) — closes the unauthenticated STUN
  reflection/amplification vector scanners look for — and
  `no-software-attribute` hides the version banner.
- coturn quotas cap relay abuse (`user-quota=12`, `total-quota=1200`).
- LiveKit exposes no metrics endpoint (the prometheus listener would be
  unauthenticated on a LAN-reachable IP); rooms are created only by the
  call-auth service (`auto_create: false`), which itself only trusts
  `${MATRIX_HOST}` (`LIVEKIT_FULL_ACCESS_HOMESERVERS`).

## Verifying a deployment

From the **WAN side** (phone on cellular, or a VPS):

```bash
curl -so /dev/null -w '%{http_code}\n' https://matrix.example.com/_synapse/admin/v1/register   # 403
curl -so /dev/null -w '%{http_code}\n' https://matrix.example.com/_matrix/federation/v1/version # 404/403 — federation not served
nmap -Pn -p 80,443,8008,8082,5432,7880 <WAN_IP>   # all closed/filtered (web rides the tunnel)
```

From a **LAN device**:

```bash
nmap -Pn -p 8008,8082 <LAN_HOST_IP>               # open — the admin plane, LAN only by design
nmap -Pn -p 6789,7880 <LIVEKIT_IP>                # 6789 closed (no metrics); 7880 open (signaling, token-auth)
```

On the **host**:

```bash
ss -tlnp | grep -E '8008|8082'                    # bound to LAN_HOST_IP, not 0.0.0.0/*
ls -l .env coturn/turnserver.conf                 # 600 you / 400 uid 65534
docker inspect family-matrix-synapse-1 --format '{{.HostConfig.CapDrop}} {{.HostConfig.SecurityOpt}}'
docker exec family-matrix-db-1 sh -c 'wget -T3 -qO- https://example.com || echo "no egress (good)"'
```

## Residual risks & recommended operator steps

1. **Offsite backups are your ransomware/disk-failure story** — push
   `$BACKUP_DIR` offsite encrypted (restic/kopia to B2/S3), including copies
   of `.env` and `files/` (signing key). Test a restore quarterly.
2. **Cloudflare API token scope**: `CF_DNS_API_TOKEN` can edit DNS for the
   whole zone and is held by traefik (and ddns if enabled). Scope it to the
   one zone, nothing else; rotate it if a container holding it is ever
   suspect. Ideally use two tokens (one for certs, one for ddns) so either
   can be revoked alone.
3. **Watch the internet-listening services**: coturn and livekit are the
   components cold-reachable from the internet — subscribe to their release
   feeds and the [matrix.org security feed](https://matrix.org/category/security/atom.xml);
   apply security releases within days (see OPERATIONS.md update policy).
4. **LAN trust**: if the LAN hosts untrusted devices, VLAN the server or
   move admin access behind WireGuard/Tailscale — the admin plane is
   plain-HTTP by design.
5. **Password hygiene is still the front door**: registration is closed and
   rate-limited, but accounts are only as strong as the passwords you set
   when creating users. Long unique passwords; the E2EE recovery key is the
   real crown jewel — store it in a password manager.
6. Optional extras, deliberately not defaulted here: synapse `pepper`
   (catastrophic if lost — only add it if your `.env` backup discipline is
   solid), compose `mem_limit`s (see OPERATIONS.md capacity notes), and a
   `media_retention` policy (growth valve, not security).

## Reporting

This is a template, not a service. If you find a vulnerability in the
template itself, open a GitHub issue (or a private security advisory on the
repo) rather than posting exploit details in a public room.
