#!/bin/bash

###############################################################################
# Client-side Shadowsocks / VPN Health Check
# - To be run on your Mac (or Linux) behind the GL-BE3600 router.
# - Verifies:
#   * Router reachable
#   * Router is default gateway (or at least first hop)
#   * DNS resolution works
#   * External IP == EXPECTED_EGRESS_IP (full-tunnel OK)
###############################################################################

# ===== USER SETTINGS =====

ROUTER_IP="192.168.8.1"          # GL router LAN IP
EXPECTED_EGRESS_IP="3.80.130.31" # Your SS/EC2 public IP (change if needed)
TEST_DOMAIN="openai.com"

# ==========================

HEALTH_OK=1

section() {
  echo ""
  echo "========== $1 =========="
}

ok() {
  echo " [OK] $1"
}

fail() {
  echo " [!!] $1"
  HEALTH_OK=0
}

info() {
  echo " [-] $1"
}

echo "----------------------------------------------"
echo " Client Shadowsocks / VPN Health Check"
echo "  Router IP:          $ROUTER_IP"
echo "  Expected egress IP: $EXPECTED_EGRESS_IP"
echo "  Test domain:        $TEST_DOMAIN"
echo "----------------------------------------------"

###############################################################################
# 1. Check router reachability
###############################################################################
section "Router reachability"

if ping -c1 -W1 "$ROUTER_IP" >/dev/null 2>&1; then
  ok "Ping to router $ROUTER_IP succeeded."
else
  fail "Ping to router $ROUTER_IP FAILED."
fi

###############################################################################
# 2. Check default gateway
###############################################################################
section "Default gateway"

GATEWAY=""

# macOS style (route -n get default)
if command -v route >/dev/null 2>&1; then
  GW=$(route -n get default 2>/dev/null | awk '/gateway:/{print $2}' | head -n1)
  if [ -n "$GW" ]; then
    GATEWAY="$GW"
  fi
fi

# Linux style fallback (ip route)
if [ -z "$GATEWAY" ] && command -v ip >/dev/null 2>&1; then
  GW=$(ip route 2>/dev/null | awk '/default/{print $3}' | head -n1)
  if [ -n "$GW" ]; then
    GATEWAY="$GW"
  fi
fi

if [ -n "$GATEWAY" ]; then
  echo " Default gateway: $GATEWAY"
  if [ "$GATEWAY" = "$ROUTER_IP" ]; then
    ok "Default gateway matches router IP."
  else
    fail "Default gateway is $GATEWAY (does NOT match router $ROUTER_IP)."
  fi
else
  fail "Could not determine default gateway."
fi

###############################################################################
# 3. DNS configuration & resolution
###############################################################################
section "DNS configuration & resolution"

DNS_SERVERS=""

# macOS: scutil --dns
if command -v scutil >/dev/null 2>&1; then
  DNS_SERVERS=$(scutil --dns 2>/dev/null | awk '/nameserver\[[0-9]+\]/{print $3}' | sort -u)
fi

# Linux fallback: /etc/resolv.conf
if [ -z "$DNS_SERVERS" ] && [ -f /etc/resolv.conf ]; then
  DNS_SERVERS=$(awk '/^nameserver/{print $2}' /etc/resolv.conf | sort -u)
fi

if [ -n "$DNS_SERVERS" ]; then
  echo " DNS servers in use:"
  echo "$DNS_SERVERS" | sed 's/^/  - /'
  if echo "$DNS_SERVERS" | grep -q "$ROUTER_IP"; then
    ok "Router IP ($ROUTER_IP) appears in DNS servers."
  else
    info "Router IP ($ROUTER_IP) not seen in DNS servers (may still be fine)."
  fi
else
  info "Could not detect DNS servers."
fi

# Test DNS resolution
if command -v nslookup >/dev/null 2>&1; then
  if nslookup "$TEST_DOMAIN" >/dev/null 2>&1; then
    ok "DNS resolution for $TEST_DOMAIN via system resolvers succeeded."
  else
    fail "DNS resolution for $TEST_DOMAIN via system resolvers FAILED."
  fi
elif command -v dig >/dev/null 2>&1; then
  if dig +short "$TEST_DOMAIN" >/dev/null 2>&1; then
    ok "DNS resolution for $TEST_DOMAIN via system resolvers succeeded."
  else
    fail "DNS resolution for $TEST_DOMAIN via system resolvers FAILED."
  fi
else
  info "Neither nslookup nor dig installed; skipping explicit DNS test."
fi

###############################################################################
# 4. External IP & egress
###############################################################################
section "External IP check"

if ! command -v curl >/dev/null 2>&1; then
  fail "curl is not installed; cannot test external IP."
else
  EXT_IP=$(curl -4s --max-time 10 https://ifconfig.me 2>/dev/null || true)
  if [ -n "$EXT_IP" ]; then
    echo " External IP (via https://ifconfig.me): $EXT_IP"
    if [ -n "$EXPECTED_EGRESS_IP" ]; then
      if [ "$EXT_IP" = "$EXPECTED_EGRESS_IP" ]; then
        ok "External IP matches EXPECTED_EGRESS_IP ($EXPECTED_EGRESS_IP) – full tunnel likely OK."
      else
        fail "External IP ($EXT_IP) does NOT match EXPECTED_EGRESS_IP ($EXPECTED_EGRESS_IP)."
      fi
    else
      info "EXPECTED_EGRESS_IP not set; cannot compare."
    fi
  else
    fail "Failed to retrieve external IP from https://ifconfig.me."
  fi
fi

###############################################################################
# 5. Optional: first hop / traceroute hint (best-effort)
###############################################################################
section "First hop / path hint"

if command -v traceroute >/dev/null 2>&1; then
  echo " Running short traceroute to $TEST_DOMAIN (first few hops)..."
  traceroute -m 5 "$TEST_DOMAIN" 2>/dev/null | sed 's/^/  /'
elif command -v mtr >/dev/null 2>&1; then
  echo " Running short mtr to $TEST_DOMAIN (may require sudo)..."
  mtr -r -c 5 "$TEST_DOMAIN" 2>/dev/null | sed 's/^/  /'
else
  info "No traceroute/mtr installed; skipping path hint."
fi

###############################################################################
# Summary
###############################################################################
echo ""
echo "----------------------------------------------"
if [ "$HEALTH_OK" -eq 1 ]; then
  echo " Client health check: ALL TESTS PASSED."
  EXIT_CODE=0
else
  echo " Client health check: SOME TESTS FAILED."
  EXIT_CODE=1
fi
echo "----------------------------------------------"

exit "$EXIT_CODE"