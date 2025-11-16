#!/bin/sh

echo "----------------------------------------------"
echo " Shadowsocks Health Check"
echo "----------------------------------------------"

# Read config via UCI
SS_SERVER=$(uci -q get shadowsocks-libev.awssrv.server)
SS_PORT=$(uci -q get shadowsocks-libev.awssrv.server_port)
SS_METHOD=$(uci -q get shadowsocks-libev.awssrv.method)
REDIR_PORT=$(uci -q get shadowsocks-libev.ss_redir.local_port)
DNS_PORT=$(uci -q get shadowsocks-libev.ss_tunnel.local_port)

echo " Config:"
echo "   Server:   ${SS_SERVER:-unknown}"
echo "   Port:     ${SS_PORT:-unknown}"
echo "   Method:   ${SS_METHOD:-unknown}"
echo "   Redir:    TCP+UDP via ${REDIR_PORT:-unknown}"
echo "   DNS port: ${DNS_PORT:-5353} (ss-tunnel)"
echo ""

# -----------------------------
# Check processes
# -----------------------------
check_process() {
    PROC="$1"
    if pgrep "$PROC" >/dev/null; then
        echo " [OK] Process '$PROC' is running."
    else
        echo " [!!] Process '$PROC' is NOT running."
        FAIL=1
    fi
}

FAIL=0
check_process "ss-redir"
check_process "ss-tunnel"
echo ""

# -----------------------------
# DNS resolution check
# -----------------------------
DOMAIN="openai.com"

echo -n " Testing DNS resolution via 127.0.0.1... "
if nslookup "$DOMAIN" 127.0.0.1 >/dev/null 2>&1; then
    echo "[OK]"
else
    echo "[!!] FAILED"
    FAIL=1
fi

# -----------------------------
# HTTP egress test
# -----------------------------
echo ""
echo " Testing HTTP connectivity (curl via IPv4)..."

EXT_IP=$(curl -4 -s --max-time 5 https://ifconfig.me)

if [ -n "$EXT_IP" ]; then
    echo " [OK] External IP: $EXT_IP"
else
    echo " [!!] HTTP connectivity test FAILED."
    FAIL=1
fi

# -----------------------------
# Check QUIC drop rule
# -----------------------------
echo ""
echo -n " Checking QUIC (UDP/443) is blocked... "

if nft list ruleset | grep -q "udp dport 443"; then
    echo "[OK]"
else
    echo "[!!] QUIC blocking rule NOT found!"
    FAIL=1
fi

# -----------------------------
# IPv6 leak check
# -----------------------------
echo ""
echo -n " Checking IPv6 disabled on router... "

if ifstatus lan | grep -q '"up": true' && ifstatus wan | grep -q '"ipv6"*'; then
    echo "[!!] IPv6 still appears active!"
    FAIL=1
else
    echo "[OK]"
fi

# -----------------------------
# Killswitch verification: fwmark=1
# -----------------------------
echo ""
echo -n " Checking fwmark rule for TPROXY routing... "

if ip rule | grep -q "fwmark 0x1 lookup 100"; then
    echo "[OK]"
else
    echo "[!!] Missing fwmark routing rule!"
    FAIL=1
fi

# -----------------------------
# Summary
# -----------------------------
echo "----------------------------------------------"
if [ "$FAIL" -eq 0 ]; then
    echo " All health checks PASSED."
else
    echo " Some health checks FAILED — see messages above."
fi
echo "----------------------------------------------"
