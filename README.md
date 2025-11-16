# 🚀 Shadowsocks Router Setup (GL.iNet / OpenWrt)  
### **Full-Tunnel · nftables · TPROXY · DNS Hijack · Kill Switch · Zero Leak**

![License](https://img.shields.io/badge/license-MIT-green.svg)
![Platform](https://img.shields.io/badge/platform-OpenWrt%20%2F%20GL.iNet-blue.svg)
![Language](https://img.shields.io/badge/scripts-bash-orange.svg)
![Status](https://img.shields.io/badge/build-passing-brightgreen.svg)
![Shadowsocks](https://img.shields.io/badge/shadowsocks-libev-red.svg)
![TPROXY](https://img.shields.io/badge/TPROXY-enabled-purple.svg)

This repository provides a **battle-tested**, **zero-leak**, **full-tunnel Shadowsocks gateway** for GL.iNet/OpenWrt routers.  
It uses modern `nftables`, `TPROXY`, `dnsmasq-full`, QUIC blocking, IPv6 suppression, and a strict kill-switch.

✔ No DNS leaks  
✔ No QUIC leaks  
✔ No IPv6 leaks  
✔ No WAN fallback  
✔ YouTube US  
✔ 100% consistent EC2 IP in all browsers  

---

# 📦 Included Scripts

| File | Purpose |
|------|---------|
| `ss-router-provision.sh` | Full router provisioning (SS, nft, DNS, TPROXY, killswitch) |
| `ss-router-health-check.sh` | Router tunnel integrity checks |
| `ss-client-health-check.sh` | Client egress, DNS, traceroute, leak checks |
| `ss-router-backup.sh` | Backup SS + firewall + nft config |
| `ss-router-restore.sh` | Restore a previous backup |

---

# 🗺 Architecture Overview Diagram

```
                 ┌───────────────────────────┐
                 │      macOS / Clients      │
                 │  All traffic via router    │
                 └─────────────┬─────────────┘
                               │ LAN (192.168.8.0/24)
                               ▼
┌──────────────────────────────────────────────────────────┐
│                   GL.iNet Router (fw4)                   │
│                                                          │
│   ┌──────────────────────────────┐      ┌─────────────┐  │
│   │ dnsmasq-full (LAN DNS)       │      │  nftables   │  │
│   │ Upstream: 127.0.0.1#5353     │◄────►│  TPROXY     │  │
│   │ AAAA blocked (filter_aaaa=1) │      │  Redirects  │  │
│   └──────────────────────────────┘      │  TCP→1081   │  │
│                                          │  UDP→TPROXY │  │
│             ┌──────────────────────┐     └─────────────┘  │
│             │  Shadowsocks-libev   │                      │
│             │   ss-redir (1081)    │◄────────────────────┐│
│             │   ss-tunnel (5353)   │◄──── DNS (TCP/UDP) ─┘│
│             └──────────────────────┘                      │
│                         │                                 │
│                         ▼                                 │
│               Encrypted Shadowsocks Tunnel                │
└─────────────────────────┼──────────────────────────────────┘
                          ▼
                 ┌──────────────────────────┐
                 │      EC2 SS Server       │
                 │       (3.80.xx.xx)       │
                 └──────────────────────────┘
```

---

# 🔁 Traffic Flow Diagram (TCP + UDP)

```
         TCP Traffic Path
┌────────────┐      IPv4 LAN       ┌─────────────┐   Encrypted   ┌───────────┐
│   Client   │────────────────────►│  nft dstnat │──────────────►│ ss-server │
└────────────┘   (Safari/Chrome)    │ redirect   │   Shadowsocks  └───────────┘
                                    │  tcp!=53   │
                                    └─────┬──────┘
                                          ▼
                                   ss-redir:1081


         UDP Traffic Path (DNS, QUIC blocked)
┌────────────┐        LAN         ┌────────────┐   fwmark=0x1   ┌───────────┐
│   Client   │────────────────────►│ nft tproxy │──────────────►│ ss-server │
└────────────┘                     │ udp        │   table=100   └───────────┘
                                   └────────────┘


         DNS Path (Hijacked)
┌────────────┐   udp/tcp:53  ┌──────────────┐   tcp/5353     ┌────────────┐
│   Client   │──────────────►│ nft redirect │───────────────►│ ss-tunnel  │
└────────────┘               │ to router    │                │ 8.8.8.8:53 │
                              └──────────────┘                └────────────┘
```

---

# 🧩 Features

### 🔐 Full Transparent Proxying (IPv4)
- TCP → ss-redir (1081)  
- UDP → TPROXY → ss-redir (fwmark 0x1)  
- Route table `100` for TPROXY return paths  

### 🧩 DNS Hardening
- dnsmasq upstream = `127.0.0.1#5353`
- DNS hijack for TCP/UDP 53  
- GL DNS services disabled  
- `filter_aaaa=1` (remove IPv6 answers)

### 🌐 IPv6 Disabled
- Router stops advertising IPv6  
- No DHCPv6  
- No RA  
- Prevents YouTube/Chrome IPv6 bypass  

### 🔥 Kill Switch
LAN → WAN is **blocked unless marked (`0x1`)**, ensuring no bypass.

### 🚫 QUIC Blocking
UDP/443 dropped before routing.

### ⚙️ Performance
- `fast_open`, `no_delay`, `reuse_port`  
- flow-offloading disabled (would bypass TPROXY)

---

# 🛠 1. Provision the Router

Upload:

```
scp ss-router-provision.sh     ss-router-health-check.sh     ss-client-health-check.sh     ss-router-backup.sh     ss-router-restore.sh     root@192.168.8.1:/root/
```

Run on router:

```
ssh root@192.168.8.1
chmod +x ss-*.sh
./ss-router-provision.sh
```

---

# 🔍 2. Router Health Check

```
./ss-router-health-check.sh
```

Expected:

```
All health checks PASSED.
```

---

# 🧪 3. Client Health Check (macOS)

```
./ss-client-health-check.sh
```

Expected:

```
Client health check: ALL TESTS PASSED.
```

---

# 💾 4. Backup & Restore

Backup:

```
./ss-router-backup.sh
```

Restore:

```
./ss-router-restore.sh ss-backup-XXXX.tar.gz
```

---

# 🎯 Expected Behavior

- ifconfig.me → **EC2 IP (everywhere, every refresh)**
- dnsleaktest extended → **US DNS resolvers only**
- YouTube → **US region**
- Traceroute → **tunneled hops**, no ISP exposure
- Zero IPv6/QUIC/WAN leaks

---

# ⚙️ GL.iNet Notes

Auto-disabled:

- AdGuard Home  
- DNS-over-HTTPS  
- DNS Rebind protection  
- Hardware offload  
- Software offload  
- IPv6 RA / DHCPv6  

---

# 🙌 Credits

Developed with deep integration into:

- nftables  
- TPROXY  
- Route table 100  
- Shadowsocks-libev  
- macOS leak analysis  
- GL.iNet fw4 behavior  

A **commercial-grade, zero-leak transparent Shadowsocks router**.
