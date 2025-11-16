#!/bin/sh

###############################################################################
# Shadowsocks-libev Full-Tunnel Provisioning v3.1
#  - GL-BE3600 / OpenWrt, fw4 + nftables
#
# Features:
# - SS server profile via UCI (awssrv)
# - ss-redir (TCP+UDP) @ 0.0.0.0:1081 with tuning (reuse_port, fast_open, no_delay)
# - ss-tunnel (DNS) @ 0.0.0.0:5353 -> upstream (default 8.8.8.8:53)
# - dnsmasq -> ss-tunnel (127.0.0.1#5353), noresolv, filter_aaaa
# - Disable GL DNS helpers (adguardhome, gl_dnsmasq, https-dns-proxy)
# - nftables:
#     * TCP redirect from LAN (192.168.8.0/24) -> ss-redir:1081
#     * DNS hijack (TCP/UDP 53) -> router dnsmasq
#     * UDP TPROXY for LAN UDP -> ss-redir:1081, fwmark 0x1, table 100
#     * QUIC hardening: drop UDP/443 from LAN (pre-forward)
#     * Killswitch: drop ALL forwarded traffic from LAN (pre-forward)
# - Flow offload disabled (fw4 defaults)
# - Sysctl tuning: net.ipv4.tcp_fastopen=3
# - IPv6 on LAN disabled (ip6assign=0, DHCPv6/RA/ND off)
# - Idempotent & verbose (safe to rerun)
###############################################################################

# ------------- ENVIRONMENT SANITY CHECK -------------------------------------

if ! command -v uci >/dev/null 2>&1 || ! command -v opkg >/dev/null 2>&1; then
    echo "ERROR: This script must be run on the OpenWrt/GL router as root."
    echo "       'uci' and/or 'opkg' were not found in PATH."
    echo ""
    echo "You probably ran it on your Mac. Instead, do:"
    echo "  scp -O router-provision-ss-v3.1.sh router-ss-health-check.sh root@192.168.8.1:/root/"
    echo "  ssh root@192.168.8.1"
    echo "  cd /root"
    echo "  chmod +x router-provision-ss-v3.1.sh router-ss-health-check.sh"
    echo "  ./router-provision-ss-v3.1.sh"
    exit 1
fi

if ! command -v nft >/dev/null 2>&1; then
    echo "ERROR: nft (nftables) not found. This script assumes fw4 + nftables."
    exit 1
fi

if [ ! -d /etc/init.d ]; then
    echo "ERROR: /etc/init.d directory not found. This does not look like OpenWrt."
    exit 1
fi

# ---------------- USER SETTINGS ---------------------------------------------

SS_SERVER="SS_SERVER_IP"
SS_PORT="SS_SERVER_PORT"
SS_PASSWORD="SS_SERVER_PASSWORD"
SS_METHOD="chacha20-ietf-poly1305"

# Local ports on the router
SS_REDIR_PORT="1081"     # ss-redir (TCP+UDP transparent proxy)
SS_DNS_PORT="5353"       # ss-tunnel (DNS)

# UDP TPROXY / routing parameters
FW_MARK="0x1"
FW_TABLE="100"

# LAN interface & subnet
LAN_IF="br-lan"
LAN_NET="192.168.8.0/24"
ROUTER_LAN_IP="192.168.8.1"

# QUIC blocking (1 = drop UDP/443 from LAN, 0 = allow)
BLOCK_QUIC="1"

# ---------------- INTERNALS (logging / step helper) -------------------------

TOTAL_STEPS=11
STEP=0
FAILURES=0

step() {
    STEP=$((STEP + 1))
    echo ""
    echo "========== Step $STEP/$TOTAL_STEPS: $1 =========="
}

run() {
    DESC="$1"
    shift
    echo "  -> $DESC"
    "$@"
    RC=$?
    if [ $RC -ne 0 ]; then
        echo "  !! FAILED ($RC): $DESC"
        FAILURES=$((FAILURES + 1))
    else
        echo "  OK: $DESC"
    fi
    return $RC
}

echo "=============================================="
echo " Starting Shadowsocks-libev provisioning (v3.1)"
echo "  Server:   $SS_SERVER"
echo "  Port:     $SS_PORT"
echo "  Method:   $SS_METHOD"
echo "=============================================="

###############################################################################
# Step 1 – Packages
###############################################################################
step "Install required packages (shadowsocks-libev, dnsmasq-full, TPROXY helpers)"

run "opkg update (non-fatal)" sh -c 'opkg update || true'

run "Install SS + helpers" \
    opkg install \
      shadowsocks-libev-ss-redir \
      shadowsocks-libev-ss-tunnel \
      shadowsocks-libev-config \
      iptables-mod-tproxy \
      ipset \
      ip-full \
      dnsmasq-full

###############################################################################
# Step 2 – Configure Shadowsocks-libev (UCI)
###############################################################################
step "Configure Shadowsocks-libev (server + ss-redir + ss-tunnel) via UCI"

echo "  -> Clean old SS UCI config (ignore 'not found' warnings)"
uci -q delete shadowsocks-libev.redir  2>/dev/null || true
uci -q delete shadowsocks-libev.dns    2>/dev/null || true
uci -q delete shadowsocks-libev.awssrv 2>/dev/null || true
uci -q delete shadowsocks-libev.server 2>/dev/null || true   # legacy name

run "Commit SS clear" uci commit shadowsocks-libev

# ---- Define the remote server section (type: server, name: awssrv) ----
run "Create server section 'awssrv'" \
    uci set shadowsocks-libev.awssrv='server'

run "Set awssrv.server (IP/hostname)" \
    uci set shadowsocks-libev.awssrv.server="$SS_SERVER"

run "Set awssrv.server_port" \
    uci set shadowsocks-libev.awssrv.server_port="$SS_PORT"

run "Set awssrv.password" \
    uci set shadowsocks-libev.awssrv.password="$SS_PASSWORD"

run "Set awssrv.method" \
    uci set shadowsocks-libev.awssrv.method="$SS_METHOD"

uci set shadowsocks-libev.awssrv.alias='aws-ss-server' 2>/dev/null || true

# ---- ss-redir instance (type: ss_redir, name: redir) ----
run "Set ss-redir UCI section (type ss_redir)" \
    uci set shadowsocks-libev.redir='ss_redir'

run "Enable ss-redir" \
    uci set shadowsocks-libev.redir.enabled='1'

run "Point ss-redir to server 'awssrv'" \
    uci set shadowsocks-libev.redir.server='awssrv'

run "Set ss-redir mode tcp_and_udp" \
    uci set shadowsocks-libev.redir.mode='tcp_and_udp'

run "Set ss-redir bind address" \
    uci set shadowsocks-libev.redir.local_address='0.0.0.0'

run "Set ss-redir local port" \
    uci set shadowsocks-libev.redir.local_port="$SS_REDIR_PORT"

# Tuning flags for ss-redir
run "Enable ss-redir fast_open" \
    uci set shadowsocks-libev.redir.fast_open='1'

run "Enable ss-redir no_delay" \
    uci set shadowsocks-libev.redir.no_delay='1'

run "Enable ss-redir reuse_port" \
    uci set shadowsocks-libev.redir.reuse_port='1'

# ---- ss-tunnel instance (type: ss_tunnel, name: dns) ----
run "Set ss-tunnel UCI section (type ss_tunnel)" \
    uci set shadowsocks-libev.dns='ss_tunnel'

run "Enable ss-tunnel" \
    uci set shadowsocks-libev.dns.enabled='1'

run "Point ss-tunnel to server 'awssrv'" \
    uci set shadowsocks-libev.dns.server='awssrv'

run "Set ss-tunnel bind address" \
    uci set shadowsocks-libev.dns.local_address='0.0.0.0'

run "Set ss-tunnel local port" \
    uci set shadowsocks-libev.dns.local_port="$SS_DNS_PORT"

run "Set ss-tunnel remote DNS 8.8.8.8:53" \
    uci set shadowsocks-libev.dns.tunnel_address='8.8.8.8:53'

run "Set ss-tunnel mode tcp_and_udp" \
    uci set shadowsocks-libev.dns.mode='tcp_and_udp'

run "Commit SS UCI config" \
    uci commit shadowsocks-libev

###############################################################################
# Step 3 – dnsmasq → send DNS to ss-tunnel
###############################################################################
step "Configure dnsmasq to use ss-tunnel on 127.0.0.1#$SS_DNS_PORT"

echo "  -> Clear existing upstream DNS servers (ignore 'not found' warnings)"
uci -q delete dhcp.@dnsmasq[0].server 2>/dev/null || true

run "Enable noresolv for dnsmasq" \
    uci set dhcp.@dnsmasq[0].noresolv='1'

run "Add 127.0.0.1#$SS_DNS_PORT as dnsmasq upstream" \
    uci add_list dhcp.@dnsmasq[0].server="127.0.0.1#$SS_DNS_PORT"

run "Commit dhcp/dnsmasq config" \
    uci commit dhcp

run "Restart dnsmasq" \
    /etc/init.d/dnsmasq restart

sleep 2

###############################################################################
# Step 4 – Disable GL-specific DNS services
###############################################################################
step "Disable GL DNS-related services (if present)"

GL_DNS_SERVICES="
gl_dnsmasq
adguardhome
https-dns-proxy
"

for svc in $GL_DNS_SERVICES; do
    if [ -x "/etc/init.d/$svc" ]; then
        run "Stop $svc" "/etc/init.d/$svc" stop
        run "Disable $svc" "/etc/init.d/$svc" disable
    else
        echo "  (info) Service $svc not present, skipping"
    fi
done

###############################################################################
# Step 5 – Cleanup old iptables rules & write nftables TCP/DNS redirect
###############################################################################
step "Cleanup legacy iptables SHADOWSOCKS block and write nftables TCP/DNS rules"

FW_USER="/etc/firewall.user"
BEGIN_MARK="# BEGIN SHADOWSOCKS AUTO RULES"
END_MARK="# END SHADOWSOCKS AUTO RULES"

# Remove old iptables-based SHADOWSOCKS block (if any)
if [ -f "$FW_USER" ]; then
    run "Remove legacy SHADOWSOCKS block from firewall.user (iptables era)" \
        sed -i "/^$BEGIN_MARK\$/,/^$END_MARK\$/d" "$FW_USER"
fi

# Create nftables snippet for fw4 dstnat chain (TCP redirect + DNS hijack)
NFT_DSTNAT_DIR="/usr/share/nftables.d/chain-pre/dstnat"
NFT_DSTNAT_FILE="$NFT_DSTNAT_DIR/50-shadowsocks.nft"

run "Ensure nftables dstnat snippet directory exists ($NFT_DSTNAT_DIR)" \
    mkdir -p "$NFT_DSTNAT_DIR"

cat > "$NFT_DSTNAT_FILE" << EOF
# Shadowsocks TCP & DNS redirect for LAN subnet ($LAN_NET via $LAN_IF)

# --- Bypass router-local access (SSH, LuCI, etc.) ---
iifname "$LAN_IF" ip saddr $LAN_NET ip daddr $ROUTER_LAN_IP return

# --- Redirect ALL TCP from LAN (except DNS) to ss-redir ---
iifname "$LAN_IF" ip saddr $LAN_NET tcp dport != 53 redirect to :$SS_REDIR_PORT

# --- Force LAN DNS → router dnsmasq → ss-tunnel ---
iifname "$LAN_IF" ip saddr $LAN_NET udp dport 53 redirect to :53
iifname "$LAN_IF" ip saddr $LAN_NET tcp dport 53 redirect to :53
EOF

echo "  OK: Wrote nftables TCP/DNS redirect rules to $NFT_DSTNAT_FILE"

###############################################################################
# Step 6 – Write nftables UDP TPROXY rules & routing (fwmark/table)
###############################################################################
step "Write nftables UDP TPROXY rules and routing (fwmark $FW_MARK, table $FW_TABLE)"

NFT_PRE_DIR="/usr/share/nftables.d/chain-pre/prerouting"
NFT_PRE_FILE="$NFT_PRE_DIR/50-shadowsocks-udp.nft"

run "Ensure nftables prerouting snippet directory exists ($NFT_PRE_DIR)" \
    mkdir -p "$NFT_PRE_DIR"

cat > "$NFT_PRE_FILE" << EOF
# Shadowsocks UDP TPROXY for LAN subnet ($LAN_NET via $LAN_IF)

# --- Bypass router-local access (SSH, LuCI, etc.) ---
iifname "$LAN_IF" ip saddr $LAN_NET ip daddr $ROUTER_LAN_IP return

# --- Bypass direct traffic to SS server (avoid loop) ---
iifname "$LAN_IF" ip saddr $LAN_NET ip daddr $SS_SERVER return

# --- Bypass RFC1918/private ranges (local networks) ---
iifname "$LAN_IF" ip saddr $LAN_NET ip daddr { 0.0.0.0/8, 10.0.0.0/8, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16 } return

# --- Bypass DNS (handled by TCP/DNS redirect + ss-tunnel) ---
iifname "$LAN_IF" ip saddr $LAN_NET udp dport 53 return

# --- TPROXY all remaining UDP from LAN via ss-redir, mark packets $FW_MARK ---
iifname "$LAN_IF" ip saddr $LAN_NET udp meta mark set $FW_MARK tproxy to :$SS_REDIR_PORT
EOF

echo "  OK: Wrote nftables UDP TPROXY rules to $NFT_PRE_FILE"

# Install fwmark table routing for TPROXY
run "Add ip rule for fwmark $FW_MARK -> table $FW_TABLE" \
    sh -c "ip rule add fwmark $FW_MARK/$FW_MARK table $FW_TABLE 2>/dev/null || true"

run "Add local route in table $FW_TABLE via lo" \
    sh -c "ip route add local 0.0.0.0/0 dev lo table $FW_TABLE 2>/dev/null || true"

run "Add LAN local route in table $FW_TABLE via $LAN_IF" \
    sh -c "ip route add local $LAN_NET dev $LAN_IF table $FW_TABLE 2>/dev/null || true"

###############################################################################
# Step 7 – QUIC hardening + Killswitch (LAN → routed zones, PRE-forward)
###############################################################################
step "QUIC hardening and LAN→WAN killswitch (pre-forward)"

NFT_FWD_PRE_DIR="/usr/share/nftables.d/chain-pre/forward"
NFT_FWD_POST_DIR="/usr/share/nftables.d/chain-post/forward"
NFT_FWD_QUIC_PRE="$NFT_FWD_PRE_DIR/50-shadowsocks-quic.nft"
NFT_FWD_KS_PRE="$NFT_FWD_PRE_DIR/60-shadowsocks-killswitch.nft"
NFT_FWD_QUIC_POST="$NFT_FWD_POST_DIR/50-shadowsocks-quic.nft"
NFT_FWD_KS_POST="$NFT_FWD_POST_DIR/60-shadowsocks-killswitch.nft"

run "Ensure nftables pre-forward snippet directory exists ($NFT_FWD_PRE_DIR)" \
    mkdir -p "$NFT_FWD_PRE_DIR"

# Clean any old post-forward files from v3
if [ -f "$NFT_FWD_QUIC_POST" ] || [ -f "$NFT_FWD_KS_POST" ]; then
    run "Remove old post-forward QUIC/killswitch snippets" \
        sh -c "rm -f '$NFT_FWD_QUIC_POST' '$NFT_FWD_KS_POST'"
fi

# QUIC drop (UDP/443 from LAN) – PRE-forward now
if [ "$BLOCK_QUIC" = "1" ]; then
    cat > "$NFT_FWD_QUIC_PRE" << EOF
# Drop QUIC (UDP/443) from LAN to any destination to avoid QUIC bypass

iifname "$LAN_IF" ip saddr $LAN_NET udp dport 443 drop
EOF
    echo "  OK: Wrote QUIC drop rule to $NFT_FWD_QUIC_PRE"
else
    if [ -f "$NFT_FWD_QUIC_PRE" ]; then
        run "Remove existing QUIC drop file (BLOCK_QUIC=0)" rm -f "$NFT_FWD_QUIC_PRE"
    fi
    echo "  (info) BLOCK_QUIC=0, no UDP/443 drop rules installed."
fi

# Killswitch: PRE-forward drop of any forwarded LAN traffic
cat > "$NFT_FWD_KS_PRE" << EOF
# Killswitch: block any forwarded traffic from LAN subnet ($LAN_NET).
# Legitimate SS-proxied flows are redirected/TPROXY'd to local and do not traverse forward chain.

iifname "$LAN_IF" ip saddr $LAN_NET counter drop
EOF

echo "  OK: Wrote killswitch rule to $NFT_FWD_KS_PRE"

###############################################################################
# Step 8 – Disable IPv6 on LAN & suppress AAAA
###############################################################################
step "Disable IPv6 on LAN and suppress AAAA responses"

run "Disable IPv6 assignment on LAN (ip6assign=0)" \
    sh -c 'uci set network.lan.ip6assign="0"; uci commit network'

run "Disable DHCPv6/RA/ND on LAN" \
    sh -c 'uci set dhcp.lan.dhcpv6="disabled"; uci set dhcp.lan.ra="disabled"; uci set dhcp.lan.ndp="disabled"; uci commit dhcp'

run "Enable dnsmasq AAAA filtering (filter_aaaa=1)" \
    sh -c 'uci set dhcp.@dnsmasq[0].filter_aaaa="1"; uci commit dhcp'

run "Restart odhcpd if present" \
    sh -c '/etc/init.d/odhcpd restart 2>/dev/null || true'

run "Restart dnsmasq after IPv6/AAAA changes" \
    /etc/init.d/dnsmasq restart

###############################################################################
# Step 9 – Disable flow offloading & apply sysctl tuning
###############################################################################
step "Disable flow offloading and apply sysctl tuning"

run "Disable software flow_offloading" \
    sh -c 'uci set firewall.@defaults[0].flow_offloading="0"; uci commit firewall'

run "Disable hardware flow_offloading_hw" \
    sh -c 'uci set firewall.@defaults[0].flow_offloading_hw="0"; uci commit firewall'

SYSCTL_FILE="/etc/sysctl.d/99-shadowsocks.conf"
cat > "$SYSCTL_FILE" << 'EOF'
# Shadowsocks-related TCP tuning
net.ipv4.tcp_fastopen = 3
EOF

run "Reload sysctl settings" sysctl -p "$SYSCTL_FILE"

###############################################################################
# Step 10 – Restart firewall
###############################################################################
step "Restart firewall to apply nftables rules, killswitch, and flow-offload changes"

run "Restart firewall" /etc/init.d/firewall restart
sleep 2

###############################################################################
# Step 11 – Enable & start Shadowsocks-libev
###############################################################################
step "Enable and start shadowsocks-libev"

/etc/init.d/shadowsocks-libev enable || {
    echo "  !! FAILED to enable shadowsocks-libev"
    FAILURES=$((FAILURES + 1))
}

run "Restart shadowsocks-libev" /etc/init.d/shadowsocks-libev restart
sleep 3

###############################################################################
# Summary & optional health check
###############################################################################
echo ""
echo "=============================================="
echo " Provisioning completed (v3.1)."
echo " Total steps:   $TOTAL_STEPS"
echo " Failures seen: $FAILURES"
echo "=============================================="
echo "  Server:   $SS_SERVER"
echo "  Port:     $SS_PORT"
echo "  Method:   $SS_METHOD"
echo "  Redir:    TCP+UDP from $LAN_NET via $SS_REDIR_PORT"
echo "  DNS:      dnsmasq -> ss-tunnel @ 127.0.0.1#$SS_DNS_PORT (upstream 8.8.8.8)"
echo "  QUIC:     $( [ "$BLOCK_QUIC" = "1" ] && echo "UDP/443 dropped from LAN (pre-forward)" || echo "UDP/443 allowed" )"
echo "  IPv6:     LAN ip6assign=0, DHCPv6/RA/ND disabled, AAAA filtered"
echo "  Scope:    IPv4 from $LAN_NET only (router & IPv6 not tunneled)"
echo "=============================================="
echo ""

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

HC_CANDIDATES="
ss-router-health-check.sh
"

HC_SCRIPT=""
for hc in $HC_CANDIDATES; do
    if [ -x "$SCRIPT_DIR/$hc" ]; then
        HC_SCRIPT="$SCRIPT_DIR/$hc"
        break
    fi
done

if [ -n "$HC_SCRIPT" ]; then
    echo "Running health check: $HC_SCRIPT"
    echo ""
    "$HC_SCRIPT" || {
        echo ""
        echo "NOTE: Health check reported problems (see above),"
        echo "      but provisioning script did not abort."
    }
else
    echo "Health check script not found or not executable in $SCRIPT_DIR."
    echo "Looked for:"
    echo "  - router-ss-health-check.sh"
    echo "  - ss-health-check.sh"
    echo "You can place one of these next to this script and chmod +x it."
fi

exit 0