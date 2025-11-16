# shadowsocks‑ninja

![License](https://img.shields.io/github/license/MHesham/shadowsocks-ninja?style=for-the-badge)
![Platform](https://img.shields.io/badge/Platform-OpenWrt%20%2F%20GL.iNet-blue?style=for-the-badge)
![Language](https://img.shields.io/badge/Language-Shell-green?style=for-the-badge)
![Status](https://img.shields.io/badge/Status-Active-success?style=for-the-badge)

![Stars](https://img.shields.io/github/stars/MHesham/shadowsocks-ninja?style=flat-square)
![Forks](https://img.shields.io/github/forks/MHesham/shadowsocks-ninja?style=flat-square)
![Issues](https://img.shields.io/github/issues/MHesham/shadowsocks-ninja?style=flat-square)
![Last Commit](https://img.shields.io/github/last-commit/MHesham/shadowsocks-ninja?style=flat-square)

---

# Project Badges

<p align="left">
  <img src="https://img.shields.io/badge/Full%20Tunnel-Verified-brightgreen?style=flat-square" />
  <img src="https://img.shields.io/badge/DNS%20Leak-Free-brightgreen?style=flat-square" />
  <img src="https://img.shields.io/badge/Game%20Friendly-Dota%202-blueviolet?style=flat-square" />
  <img src="https://img.shields.io/badge/TPROXY-Enabled-orange?style=flat-square" />
  <img src="https://img.shields.io/badge/nftables-Supported-yellow?style=flat-square" />
  <img src="https://img.shields.io/badge/GL.iNet-Compatible-blue?style=flat-square" />
  <img src="https://img.shields.io/badge/IPv6-Leak%20Protected-red?style=flat-square" />
  <img src="https://img.shields.io/badge/QUIC-Blocked-red?style=flat-square" />
</p>

---

# Overview

This project provides a **battle‑tested, production‑grade, full‑tunnel Shadowsocks gateway** for **GL.iNet / OpenWrt routers**.

It supports **two independent routing engines**, each with its own architecture and scripts:

| Mode        | Technology                             | Use Case |
|-------------|-----------------------------------------|----------|
| **ssproxy** | ss-redir + ss-tunnel + TPROXY + iptables | Full IPv4 transparent proxy with UDP & DNS tunneling |
| **nft**     | Pure nftables redirect rules             | Lightweight mode, simpler packet path, no ssproxy service |

Both modes include backup, restore, provisioning, strict health checks, DNS protection, and QUIC blocking.

---

# Features

### 🔐 100% Full Tunnel (No Leaks)
- All LAN traffic routed through SS server  
- IPv6 leak protection  
- QUIC blocked  
- Forced DNS through ss‑tunnel

### 🎮 Game Friendly
- Dota 2 and other UDP‑heavy games work with stable latency  
- No jitter from hardware offload  
- TPROXY‑correct UDP routing

### 🧰 Production Safety
- Automatic backup + rollback if provisioning fails  
- Strict health validation (routing, DNS, egress, processes, hooks)  
- Client & Router validation scripts

### 🧪 Health Check Coverage
- Processes (ss-redir, ss-tunnel)
- Listener ports (1081, 8054)
- TPROXY routing (fwmark → table 100 → local route)
- iptables/nftables hooks
- DNS tunnel whoami check
- External egress verification
- Client test suite for LAN devices

---

# Repository Structure

| File | Description |
|------|-------------|
| `ss-router-ssproxy-provision.sh` | Full provisioning flow for **ssproxy mode** |
| `ss-router-ssproxy-config.sh` | Main configuration logic for ssproxy mode |
| `ss-router-ssproxy-health-check.sh` | Strict router-side diagnostic for ssproxy |
| `ss-router-nft-provision.sh` | Provisioning for **nft‑only mode** |
| `ss-router-nft-health-check.sh` | Diagnostic/health checks for nft mode |
| `ss-router-install-deps.sh` | Shared dependency installer |
| `ss-router-backup.sh` | Router config backup |
| `ss-router-restore.sh` | Restore backup |
| `ss-client-health-check.sh` | LAN-side full tunnel diagnostics |
| `ss-client-sanitize-ssh.sh` | Optional SSH config sanitizer for clients |

---

# Architecture Diagram

```
LAN Clients
     │
     ▼
GL.iNet / OpenWrt Router
(ssproxy mode or nft mode)
     │
     ▼
Encrypted Shadowsocks Tunnel
     │
     ▼
Shadowsocks Server (e.g. 3.80.130.31)
```

---

# Installation

## 1. Upload scripts to router
```sh
scp *.sh root@192.168.8.1:/root/
```

## 2. Make them executable
```sh
chmod +x *.sh
```

## 3. Run the provisioning (choose one)

### ssproxy mode:
```sh
./ss-router-ssproxy-provision.sh
```

### nft mode:
```sh
./ss-router-nft-provision.sh
```

---

# Health Checks

### Router:
```sh
./ss-router-ssproxy-health-check.sh
```

### Client:
```sh
./ss-client-health-check.sh
```

Expected result:  
✅ All tests PASSED

---

# Backup & Restore

### Backup:
```sh
./ss-router-backup.sh
```

### Restore:
```sh
./ss-router-restore.sh ss-backup-YYYYMMDD-HHMMSS.tar.gz
```

---

# Validated Behavior
- Full tunnel active  
- DNS leak-free  
- Games (including Dota 2) stable  
- QUIC + IPv6 fully blocked  
- No fallback to ISP DNS  
- Correct TPROXY routing path  
- Verified end-to-end on both router and client  

---

# License  
GPL‑3.0 — see [LICENSE](LICENSE)

---

# Credits  
Optimized and engineered for GL.iNet / OpenWrt full‑tunnel Shadowsocks with maximum safety and zero leaks.  
