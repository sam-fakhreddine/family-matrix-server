# family-matrix-server

A self-hosted, **private-by-design** chat server for a family or small group:
end-to-end-encrypted messaging, group voice/video calls, and an optional
WhatsApp bridge — built on [Matrix Synapse](https://github.com/element-hq/synapse),
[Element Call](https://github.com/element-hq/element-call)/[LiveKit](https://livekit.io),
and [mautrix-whatsapp](https://github.com/mautrix/whatsapp), deployed with
docker compose.

Users connect with the standard [Element](https://element.io) apps (iOS,
Android, web, desktop). Nothing custom to install on phones.

## What makes this template different

- **Closed server**: no federation, no public registration, admin plane
  LAN-only, `/_synapse` blocked at the proxy, E2EE on by default. The attack
  surface is the client API plus two narrowly-forwarded media ports.
- **Calls that actually work**: Element Call/LiveKit wired correctly for a
  home network — including the non-obvious parts (the openid exception a
  closed server needs for call auth, single-port UDP media mux, macvlan IPs
  so LAN devices get switch-speed media instead of NAT hairpin, the 16 MiB
  UDP buffer sysctl that LiveKit silently degrades without).
- **Zero inbound HTTP**: web traffic arrives via a Cloudflare Tunnel
  (bundled optional ingress); only 4 UDP/TCP media forwards touch your router.
- **Everything parameterized**: one `.env` + `./setup.sh` renders all configs
  and generates all secrets. No hand-editing YAML to deploy.

## Requirements

- A Linux docker host on your LAN (docker compose v2) — x86_64 or arm64
  (every image ships arm64; a Pi 5 works, see sizing below)
- A domain on Cloudflare (for the bundled ingress; BYO-proxy also supported)
- A **real public IP** and the ability to add 4 router port-forward rules
  (CGNAT won't work for calls with remote participants)
- A small block of LAN IPs outside your DHCP pool (macvlan for media)
- **An SSD.** Postgres + Synapse are random-I/O-heavy; SD cards and HDDs are
  the #1 cause of mysteriously slow/corrupted small Matrix servers.

## Hardware sizing

A closed (non-federating) server is far cheaper to run than most Matrix
sizing guides suggest — federation traffic, not user count, is what makes
Synapse hungry. The video SFU never transcodes (it forwards encrypted
packets; no GPU ever needed), so your **upload bandwidth** is usually the
real ceiling, not CPU.

| | Minimum | Recommended | Best |
|---|---|---|---|
| Example | Pi 5 (4 GB) + NVMe, or 2 vCPU/4 GB VPS | N100/N305 mini PC, 16 GB | 6–8-core desktop, 32 GB |
| Disk (SSD) | 64–128 GB | 256–512 GB | 1–2 TB |
| Uplink | 15–20 Mbps | 30–50 Mbps | 100+ Mbps |
| Handles | 5 users, 1:1 + small calls | 5–10 users, regular 5–8-person calls, bridge | 25+ users, parallel calls, years of media |

Rules of thumb: each camera-on participant uploads ~2.4 Mbps to the server;
a 5-person call with remote members costs the server ~12–18 Mbps of egress
(simulcast gracefully degrades tiles to 360p before anything fails). Storage
growth is dominated by shared photos/videos, not messages — budget roughly
25–30 GB/year for an active family and see OPERATIONS.md for the retention
valve. On 4 GB hosts set `SYNAPSE_CACHE_FACTOR=0.25`.

## Quick start

```bash
cp .env.example .env      # fill in Identity + Network sections
./setup.sh                # generates secrets, renders configs, bootstraps DB
cd ingress && docker compose --env-file ../.env up -d && cd ..   # or BYO Traefik
sudo bash host-fixes.sh   # UDP buffers (+ AppArmor patch only if needed)
docker compose up -d
```

Then follow the DNS + router checklist `setup.sh` prints, create your first
user, and sign in from Element. Full walkthrough: **[SETUP.md](SETUP.md)**.

## Documentation

| Doc | What's in it |
|---|---|
| [SETUP.md](SETUP.md) | Step-by-step first deployment |
| [OPERATIONS.md](OPERATIONS.md) | Day-2: users, backups/restore, WhatsApp bridge, troubleshooting |
| [ARCHITECTURE.md](ARCHITECTURE.md) | Diagrams, network design, and the reasoning behind the decisions |
| [ingress/README.md](ingress/README.md) | Bundled Traefik + Cloudflare Tunnel setup |

## License

MIT
