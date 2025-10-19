# GL.iNet / OpenWrt Shadowsocks Client Provisioning

This repository contains a single-shot provisioning script that configures a GL.iNet (OpenWrt) router as a Shadowsocks client with:

- `ss-redir` (TCP + UDP redirection)
- `ss-tunnel` (DNS forwarding through Shadowsocks)
- TPROXY-based UDP interception (so UDP from LAN clients is proxied)
- NAT/REDIRECT for TCP
- DNS leak protection (dnsmasq -> local `ss-tunnel`)
- Optional QUIC (UDP/443) DROP rule to prevent browser bypass
- Multi-worker `ss-redir` (via `--reuse-port`)

> **Important:** The script must be run on the router as `root`. Edit the environment variables at the top before running.

---

## Files

- `ss-router-provision.sh` — the main provisioning script. Replace placeholders:
  - `SS_HOST` = your Shadowsocks server host/IP (example: `ec2-1-2-3-4.compute-1.amazonaws.com` or `1.2.3.4`)
  - `SS_PORT` = server port (default `8388`)
  - `SS_PASS` = server password
  - `SS_METHOD` = cipher (e.g., `chacha20-ietf-poly1305` recommended)
  - `REDIR_PORT` = local port `ss-redir` listens on (default `1081`)
  - `TUNNEL_PORT` = local port `ss-tunnel` (default `8054`)
  - `UPSTREAM_DNS` = DNS destination for `ss-tunnel` (defaults to `1.1.1.1:53`)
  - `WORKERS` = how many `ss-redir` worker instances (default `2`)
  - `BLOCK_QUIC` = `1` to add a firewall UCI rule dropping UDP/443 from LAN→WAN

---

## High-level steps the script performs

1. Attempts to install necessary packages (`shadowsocks-libev` bits, TPROXY modules).
2. Writes `/etc/init.d/ssproxy` (procd-style) which starts:
   - multiple `ss-redir` instances (workers) with `--fast-open --reuse-port --no-delay` flags
   - a single `ss-tunnel` instance listening on `127.0.0.1:${TUNNEL_PORT}`
3. Configures `dnsmasq` (`/etc/dnsmasq.d/shadowsocks.conf`) to forward DNS to `127.0.0.1:${TUNNEL_PORT}` and sets `no-resolv`.
4. Adds an optional UCI `firewall` rule to drop QUIC (UDP/443) from LAN to WAN (prevents browser-level DNS/QUIC leaks).
5. Writes persistent TPROXY and NAT rules to `/etc/firewall.user`:
   - `PREROUTING` hook with `iptables -t nat` chain `SHADOWSOCKS` for TCP -> REDIRECT -> `ss-redir`
   - `mangle` chain `SHADOWSOCKS` for UDP -> TPROXY -> `ss-redir` and marks packets for a local routing table
   - `ip rule` + `ip route` for `fwmark` lookup table
6. Disables flow offloading in UCI defaults (many routers bypass NF rules otherwise).
7. Enables `net.ipv4.tcp_fastopen=3`.
8. Restarts services and performs light verification.

---

## How to run

1. Copy `ss-router-provision.sh` to the router (e.g. `/root`).
2. Edit the top section and fill `SS_HOST` and `SS_PASS` (and any other desired variables).
3. Make the script executable:
   ```sh
   chmod +x /root/ss-router-provision.sh