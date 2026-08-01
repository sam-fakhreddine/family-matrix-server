# First deployment, step by step

Worked example values used throughout: domain `example.com`, docker host at
`192.168.1.10`, LAN `192.168.1.0/24`, media container IPs `192.168.1.241`
(TURN) and `192.168.1.242` (LiveKit).

## 0. Decide your names and addresses

| Setting | Example | Notes |
|---|---|---|
| `MATRIX_HOST` | `matrix.example.com` | **Permanent.** Becomes part of every user ID (`@mom:matrix.example.com`). |
| `RTC_HOST` / `LIVEKIT_HOST` | `rtc.` / `livekit.example.com` | Call auth + call signaling, via tunnel |
| `TURN_HOST` | `turn.example.com` | DNS-only A record → your WAN IP |
| `MACVLAN_RANGE` | `192.168.1.240/29` | Must be OUTSIDE your DHCP pool (check your router's DHCP settings) |
| `MACVLAN_PARENT` | `eth0` | The host's LAN interface: `ip route show default` shows it (`dev …`). On Proxmox it's typically `vmbr0`. |

## 1. Configure and run setup

```bash
cp .env.example .env
$EDITOR .env            # Identity + Network sections; leave Secrets blank
./setup.sh
```

`setup.sh` auto-detects your WAN IP (confirm it), generates every secret,
mints the Synapse signing key, renders all configs, and — once the ingress
network exists — starts postgres and creates the databases. Re-run it any
time; it never overwrites without `--force`.

## 2. Ingress

**Bundled** (recommended for a fresh host): follow
[ingress/README.md](ingress/README.md) — create the tunnel, paste
`TUNNEL_TOKEN` + `CF_DNS_API_TOKEN` into `.env`, add the three public
hostnames in the dashboard, then:

```bash
cd ingress && docker compose --env-file ../.env up -d && cd ..
./setup.sh    # re-run to finish DB bootstrap now that the network exists
```

**Bring your own Traefik**: set `TRAEFIK_NETWORK` and `CERT_RESOLVER` in
`.env` to match your setup; ensure your tunnel/proxy routes the three
hostnames to it; skip the `ingress/` directory entirely.

## 3. DNS

The three proxied hostnames are created automatically when you add them to
the tunnel. Add **manually** in the Cloudflare dashboard:

- `turn.example.com` — **A record → your WAN IP — DNS-only (grey cloud),
  TTL 60s**. TURN cannot traverse the Cloudflare proxy (the orange cloud
  only carries HTTP/WSS); orange-clouding it breaks calls. Proxied records'
  TTL is forced to Auto — nothing to set there.

DNS facts worth knowing before you go further:

- **`MATRIX_HOST` is permanent.** It's the Matrix `server_name`, baked into
  every user ID and room forever — it cannot be changed later without
  starting a brand-new server. If you'd ever want IDs like
  `@alice:example.com` (apex) instead of `@alice:matrix.example.com`,
  that's an advanced setup (the apex must serve
  `/.well-known/matrix/server` delegation) you must choose on day one.
- **No SRV records.** Old tutorials mention `_matrix._tcp` SRV records —
  they're deprecated in the spec, ignored by clients, and irrelevant to a
  closed server. Skip them.
- **Dynamic IP?** Enable the bundled DDNS sidecar to keep the TURN record
  current: `docker compose --profile ddns up -d` (reuses your
  `CF_DNS_API_TOKEN`). After an IP change also re-run `./setup.sh --force`
  and restart coturn — its config embeds the WAN IP separately from DNS.
- **Create records before testing them.** Local resolvers (pihole/AdGuard)
  negative-cache missing names for up to 30 minutes — if a hostname "won't
  resolve" right after you created it, flush the resolver
  (`pihole restartdns`), don't fight Cloudflare.
- **Recommended extras** (Cloudflare dashboard, 5 minutes): enable **DNSSEC**
  (one click + a DS record at your registrar); and since this domain sends no
  email, add the anti-spoofing trio — `MX 0 .` (null MX),
  `TXT "v=spf1 -all"`, `_dmarc TXT "v=DMARC1; p=reject"`.
- **Media uploads**: synapse's 50 MB `max_upload_size` sits under
  Cloudflare's 100 MB proxy limit. Don't raise it past 100 MB — the proxy
  will 413 the uploads regardless.

## 4. Router port-forwards

All four rules point at the **container IPs**, not the docker host:

| Ports | Proto | Destination | Purpose |
|---|---|---|---|
| 3478 | TCP + UDP | `192.168.1.241` | TURN |
| 49152–49252 | UDP | `192.168.1.241` | TURN relay range |
| 7881 | TCP | `192.168.1.242` | Call media (TCP fallback) |
| 7882 | UDP | `192.168.1.242` | Call media (primary) |

Do **not** forward 80/443/8008/7880 — web traffic rides the tunnel.

## 5. Host tuning

```bash
sudo bash host-fixes.sh
```

Always sets the UDP buffer sysctls LiveKit needs. Additionally, it tests
whether your kernel/AppArmor combination breaks unix sockets inside
containers (a known regression on some newer kernels, notably Proxmox) and
installs a patched docker profile **only if the test fails**.

## 6. Launch and verify

```bash
docker compose up -d
curl http://localhost:8008/health                                  # 200
curl https://matrix.example.com/health                             # 200 via tunnel
curl https://rtc.example.com/healthz                               # 200
curl -s https://matrix.example.com/.well-known/matrix/client       # contains rtc_foci
curl -si 'https://matrix.example.com/_matrix/federation/v1/openid/userinfo?access_token=x' # 401 (NOT 404)
curl -so /dev/null -w '%{http_code}\n' https://matrix.example.com/_synapse/admin/v1/register # 403
```

## 7. First user and clients

```bash
docker exec -it family-matrix-synapse-1 register_new_matrix_user -c /data/homeserver.yaml http://localhost:8008
```

Answer **yes** to admin for your own account. Registration is closed by
design — you create every account this way (add `-u NAME -p PASS --no-admin`
for non-interactive).

Everyone signs in from any Element app with homeserver `matrix.example.com`.
The admin panel is at `http://192.168.1.10:8082` (LAN only, on purpose).

## 8. Verify calls end-to-end

Start a video call in a room: one participant on home wifi, one on cellular
(wifi off). Both should connect with video within seconds. If not, see the
Troubleshooting table in [OPERATIONS.md](OPERATIONS.md) — the most common
issues are the TURN A-record being proxied (grey-cloud it), a forward
pointing at the docker host instead of the container IPs, and local-DNS
negative caching.

## 9. Backups

Covered in [OPERATIONS.md](OPERATIONS.md).
