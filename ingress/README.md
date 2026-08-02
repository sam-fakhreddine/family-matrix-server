# Bundled ingress (Traefik + Cloudflare Tunnel)

Use this if you don't already run a reverse proxy. It gives the chat stack
HTTPS ingress with **zero inbound HTTP ports** on your router — all web
traffic arrives through an outbound Cloudflare Tunnel. (Call *media* still
needs the four UDP/TCP port-forwards; that's separate and unavoidable.)

## One-time Cloudflare dashboard setup

1. **Create the tunnel**: Zero Trust → Networks → Tunnels → *Create a tunnel*
   (Cloudflared type). Copy the token into `TUNNEL_TOKEN` in `../.env`.
2. **Add three public hostnames** to the tunnel (Public Hostname tab), all
   pointing at the same service:
   | Hostname | Service | Extra |
   |---|---|---|
   | your `MATRIX_HOST` | `https://traefik:443` | TLS → *No TLS Verify: on* |
   | your `RTC_HOST` | `https://traefik:443` | same |
   | your `LIVEKIT_HOST` | `https://traefik:443` | same |
   (Adding a hostname here also creates its proxied DNS record automatically.)
3. **DNS API token** for certificates: dashboard → My Profile → API Tokens →
   *Create Token* → "Edit zone DNS" template, scoped to your zone. Put it in
   `CF_DNS_API_TOKEN` in `../.env`.
4. The `TURN_HOST` record is **not** a tunnel hostname — create it manually as
   a **DNS-only (grey cloud) A record** pointing at your WAN IP. TURN/UDP
   cannot traverse the Cloudflare proxy.

## Launch

```bash
cd ingress
docker compose --env-file ../.env up -d
```

This creates the `family-matrix-ingress` docker network the chat stack attaches to
(matches the default `TRAEFIK_NETWORK` in `.env.example`). Then go back up and
re-run `../setup.sh` to finish the database bootstrap.

## Notes

- "No TLS Verify" on the tunnel hostnames is normal here: cloudflared →
  traefik is a private docker-network hop; the public leg is TLS at
  Cloudflare's edge, and traefik still serves real Let's Encrypt certs.
- Nothing in this stack publishes ports 80/443 to the host — the only path in
  is the tunnel. Keep it that way.
- Traefik never mounts `docker.sock`. It discovers services through the
  `socket-proxy` container, which allows only the read-only endpoints
  discovery needs (ping/version/container list/events) over an internal
  network — an exploited Traefik can enumerate containers but cannot exec,
  start, or create anything. Don't widen socket-proxy's `-allowGET` list
  (and especially don't add `-allowPOST`) without a concrete need.
