# 🚀 Shadowsocks Router Setup (GL.iNet / OpenWrt)  
### **Full-Tunnel | nftables | TPROXY | DNS Hijack | Kill Switch | Zero Leak**

This repository provides a **battle-tested**, **zero-leak**, **full-tunnel Shadowsocks gateway** for GL.iNet/OpenWrt routers.  
It uses modern `nftables`, `TPROXY`, `dnsmasq-full`, and a strict **LAN→WAN kill-switch** to guarantee **no bypass**, **no QUIC leaks**, **no IPv6 leaks**, and **forced US egress**.

Included:

- 🛠 `ss-router-provision.sh` — fully provisions the router  
- 🔍 `ss-router-health-check.sh` — validates router-side tunnel integrity  
- 🧪 `ss-client-health-check.sh` — validates client-side egress consistency  
- 💾 `ss-router-backup.sh` — backup of all SS + firewall + nftable rules  
- ♻️ `ss-router-restore.sh` — restore a previous backup cleanly  

Validated on:

- GL.iNet **BE3600** (QSDK v12.5 / OpenWrt fw4)  
- macOS (Safari, Chrome, Incognito)  
- YouTube / ifconfig.me / dnsleaktest.net / ip.me  

✔ No DNS leaks  
✔ No QUIC leaks  
✔ No IPv6 leaks  
✔ No WAN fallback  
✔ 100% consistent EC2 IP in all browsers  

---

## ✨ Features

### 🔐 Full Transparent Proxying (IPv4)
All LAN traffic is forced through Shadowsocks:

- **TCP** → ss-redir (port `1081`)  
- **UDP** → TPROXY → ss-redir (fwmark `0x1`, route table `100`)  

### 🧩 DNS Hardening
- dnsmasq upstream = `127.0.0.1#5353` (via ss-tunnel → 8.8.8.8 or 1.1.1.1)  
- DNS hijack: *all* TCP/UDP port 53 forced through router  
- GL.iNet’s AdGuard/DoH/DNS services disabled  
- `filter_aaaa=1` enabled (blocks IPv6 DNS answers)

### 🌐 IPv6 Disabled (Leak-Free)
- No DHCPv6  
- No RA  
- No global IPv6 on LAN  
- Prevents YouTube/Chrome/Safari IPv6 bypass  

### 🔥 Strict Kill Switch (LAN → WAN block)
WAN traffic **cannot leave the router unless it passed through ss-redir**.

Prevents:

- QUIC fallback  
- Direct TCP bypass  
- Browser speculative connections  
- YouTube local region detection  
- All ifconfig.me inconsistencies  

### 🚫 QUIC Blocking
`UDP/443` dropped before routing → perfect browser control.

### ⚙️ Performance Boosts
- `reuse_port=1`  
- `fast_open=1`  
- `no_delay=1`  
- Hardware & software flow offloading disabled  
  (these would bypass TPROXY)

### 🔁 Fully Idempotent
You can safely re-run the provisioning script anytime.

---

## 📁 File Overview

| Script | Purpose |
|--------|---------|
| **ss-router-provision.sh** | Full provisioning: SS config, nftables, TPROXY, DNS, killswitch |
| **ss-router-health-check.sh** | Ensures router-side integrity of tunnel, DNS, iptables/nftables |
| **ss-client-health-check.sh** | Ensures macOS client exits via SS tunnel with no leaks |
| **ss-router-backup.sh** | Backup firewall + SS + nft rules + DNS config |
| **ss-router-restore.sh** | Restore a previous backup |

---

## 🛠 1. Provision the Router

Upload scripts:

```
scp ss-router-provision.sh \
    ss-router-health-check.sh \
    ss-client-health-check.sh \
    ss-router-backup.sh \
    ss-router-restore.sh \
    root@192.168.8.1:/root/
```

On router:

```
ssh root@192.168.8.1
chmod +x ss-*.sh
./ss-router-provision.sh
```

Expected:

- ✔ All steps pass  
- ✔ Health check auto-runs  
- ✔ External IP = **EC2 US IP**  

---

## 🔍 2. Router Health Check

```
./ss-router-health-check.sh
```

Checks:

- ss-redir running  
- ss-tunnel running  
- DNS through ss-tunnel  
- QUIC blocked  
- No IPv6  
- No WAN bypass  
- Router’s public IP = EC2  

Expected:

```
All health checks PASSED.
```

---

## 🧪 3. Client Health Check (macOS)

```
./ss-client-health-check.sh
```

Checks:

- Router reachability  
- DNS server usage (`192.168.8.1`)  
- Egress IP  
- Traceroute  
- Leak signatures  

Expected:

```
Client health check: ALL TESTS PASSED.
```

---

## 💾 4. Backup & Restore

### Create backup:

```
./ss-router-backup.sh
```

Produces:

```
ss-backup-<timestamp>.tar.gz
```

### Restore:

```
./ss-router-restore.sh ss-backup-XXXX.tar.gz
```

Restores all:

- UCI SS config  
- dnsmasq  
- firewall  
- nftables  
- routing rules  

---

## 🎯 Expected Post-Provision Behavior

- ifconfig.me → **EC2 IP (everywhere, every refresh)**
- dnsleaktest extended → **US DNS resolvers only**
- YouTube signed-out → **US region**
- ip.me / ifconfig.co → **EC2 IP**
- Traceroute → **router → tunneled hops**, no ISP

---

## 🧰 Troubleshooting

### ❗ Browser shows ISP IP
Close all browser windows.  
Verify QUIC drop rule:

```
nft list ruleset | grep "udp dport 443"
```

### ❗ DNS leaks
Check dnsmasq upstream:

```
uci show dhcp | grep server
```

Must be only:

```
127.0.0.1#5353
```

### ❗ ss-tunnel not running

```
pgrep ss-tunnel
/etc/init.d/shadowsocks-libev restart
```

---

## ⚙️ GL.iNet Firmware Notes

This script disables conflicting GL services:

- AdGuard Home  
- DNS-over-HTTPS  
- DNS Rebind protection  
- Flow Offloading (HW/SW)  
- IPv6 RA/DHCPv6  

These can break TPROXY or leak your real IP — they *must* stay disabled.

---

## 🙌 Credits

Thanks to deep work on:

- nftables  
- TPROXY + routing table 100  
- dnsmasq-full  
- SS-libev tuning  
- QUIC fingerprint suppression  
- IPv6 suppression  
- macOS browser leak analysis  

You now have a **professional-grade transparent Shadowsocks gateway**.
