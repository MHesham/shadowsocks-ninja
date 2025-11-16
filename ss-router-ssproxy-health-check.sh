#!/bin/sh
# === ss-router-ssproxy-health-check.sh =======================================
# Shadowsocks "ssproxy" Router Health & Diagnostics (GL / OpenWrt)
#
# This script is READ-ONLY: it does NOT change config, it only inspects:
#  - Binaries & service (ss-redir, ss-tunnel, ssproxy)
#  - dnsmasq integration (DNS -> 127.0.0.1#8054)
#  - Processes & listening ports (ss-redir, ss-tunnel)
#  - TPROXY routing (ip rule fwmark 0x1, table 100 + ip route get test)
#  - iptables hooks (SHADOWSOCKS in mangle/nat PREROUTING)
#  - DNS tunnel behavior (dig whoami.cloudflare via 127.0.0.1#8054)
#  - Optional external IP check (if curl/wget is available)
#
# It also writes debug snapshots into:
#  - /tmp/ssrouter-health-iptables-nat.txt
#  - /tmp/ssrouter-health-iptables-mangle.txt
#  - /tmp/ssrouter-health-iprules.txt
#  - /tmp/ssrouter-health-table100.txt
#  - /tmp/ssrouter-health-logs.txt
#  - /tmp/ssrouter-health-dns.txt
#
# Adjust these if needed:

SS_WORKERS_EXPECTED="2"       # expected ss-redir worker count (per config script)
DNS_TEST_DOMAIN="example.com" # used only as fallback if dig is missing
EXPECTED_EGRESS_IP=""         # optional (e.g. "3.80.130.31"); leave empty to skip strict compare

# IP used for TPROXY functional test (must be an internet IP)
TPROXY_TEST_IP="1.1.1.1"

# ============================================================================

set -eu

say()  { printf "\n[*] %s\n" "$*"; }
ok()   { printf "    [OK] %s\n" "$*"; }
warn() { printf "    [!!] %s\n" "$*"; }

summary_failed=0

mark_fail() {
  summary_failed=1
}

check_root() {
  say "Environment check"
  if [ "$(id -u)" -ne 0 ]; then
    warn "Not running as root. Some checks (iptables/ip rules/logread) may be incomplete."
    mark_fail
  else
    ok "Running as root."
  fi

  printf "    Shell: %s\n" "$SHELL"
  printf "    PATH:  %s\n" "$PATH"
}

check_binaries() {
  say "Shadowsocks binaries & service"

  # ss-redir
  if command -v ss-redir >/dev/null 2>&1; then
    ok "ss-redir found at: $(command -v ss-redir)"
  else
    warn "ss-redir binary NOT found in PATH."
    mark_fail
  fi

  # ss-tunnel
  if command -v ss-tunnel >/dev/null 2>&1; then
    ok "ss-tunnel found at: $(command -v ss-tunnel)"
  else
    warn "ss-tunnel binary NOT found in PATH."
    mark_fail
  fi

  # init script
  if [ -x /etc/init.d/ssproxy ]; then
    ok "/etc/init.d/ssproxy exists and is executable."
  else
    warn "/etc/init.d/ssproxy is missing or not executable."
    mark_fail
  fi

  # autostart
  if ls /etc/rc.d/*ssproxy* >/dev/null 2>&1; then
    ok "ssproxy appears to be enabled at boot (rc.d symlink present)."
  else
    warn "No /etc/rc.d/*ssproxy* symlink found; ssproxy may not start at boot."
    mark_fail
  fi
}

check_dnsmasq() {
  say "dnsmasq integration (DNS -> ss-tunnel)"

  if ! uci -q show dhcp.@dnsmasq[0] >/dev/null 2>&1; then
    warn "No dhcp.@dnsmasq[0] found in UCI; dnsmasq config unknown."
    mark_fail
    return
  fi

  local_servers="$(uci -q get dhcp.@dnsmasq[0].server 2>/dev/null || echo "")"
  local_noresolv="$(uci -q get dhcp.@dnsmasq[0].noresolv 2>/dev/null || echo "")"

  printf "    dnsmasq 'server' list: %s\n" "${local_servers:-<none>}"
  printf "    dnsmasq 'noresolv':    %s\n" "${local_noresolv:-<unset>}"

  echo "$local_servers" | grep -q '127.0.0.1#8054' 2>/dev/null && has_tunnel_server=1 || has_tunnel_server=0

  if [ "$has_tunnel_server" -eq 1 ]; then
    ok "dnsmasq is configured to forward DNS to 127.0.0.1#8054."
  else
    warn "dnsmasq does NOT list 127.0.0.1#8054 as a server."
    mark_fail
  fi

  if [ "$local_noresolv" = "1" ]; then
    ok "dnsmasq 'noresolv' is set (avoids leaking to ISP resolvers)."
  else
    warn "dnsmasq 'noresolv' is not '1' (upstream resolvers may be mixed)."
    mark_fail
  fi
}

check_processes_and_ports() {
  say "ssproxy processes & listening ports"

  # processes
  redir_count="$(ps w | grep -E '[s]s-redir' | wc -l || echo 0)"
  tunnel_count="$(ps w | grep -E '[s]s-tunnel' | wc -l || echo 0)"

  printf "    ss-redir process count:  %s\n" "$redir_count"
  printf "    ss-tunnel process count: %s\n" "$tunnel_count"

  if [ "$redir_count" -lt "$SS_WORKERS_EXPECTED" ]; then
    warn "Expected at least $SS_WORKERS_EXPECTED ss-redir workers, but found $redir_count."
    mark_fail
  else
    ok "ss-redir workers running as expected (>= $SS_WORKERS_EXPECTED)."
  fi

  if [ "$tunnel_count" -lt 1 ]; then
    warn "No ss-tunnel process found."
    mark_fail
  else
    ok "ss-tunnel process running."
  fi

  # ports
  if command -v netstat >/dev/null 2>&1; then
    udp_8054="$(netstat -ulpn 2>/dev/null | grep ':8054' || true)"
    tcp_1081="$(netstat -ntlp 2>/dev/null | grep ':1081' || true)"

    if [ -n "$udp_8054" ]; then
      ok "UDP 8054 (DNS tunnel) is listening:"
      printf "       %s\n" "$udp_8054"
    else
      warn "UDP 8054 is NOT listening; ss-tunnel may not be bound."
      mark_fail
    fi

    if [ -n "$tcp_1081" ]; then
      ok "TCP 1081 (ss-redir) is listening:"
      printf "       %s\n" "$tcp_1081"
    else
      warn "TCP 1081 is NOT listening; ss-redir may not be bound."
      mark_fail
    fi
  else
    warn "netstat not found; cannot verify listening ports."
    mark_fail
  fi
}

check_tproxy_routing() {
  say "TPROXY routing (ip rule / table 100)"

  ip rule show >/tmp/ssrouter-health-iprules.txt 2>&1 || true
  ip route show table 100 >/tmp/ssrouter-health-table100.txt 2>&1 || true

  if ip rule show | grep -q 'fwmark 0x1.*lookup 100'; then
    ok "ip rule fwmark 0x1 -> table 100 present."
  else
    warn "ip rule fwmark 0x1 -> table 100 MISSING."
    mark_fail
  fi

  t100_out="$(ip route show table 100 2>/dev/null || true)"
  printf "    table 100 routes: %s\n" "${t100_out:-<empty>}"

  echo "$t100_out" | grep -Eq 'local (0\.0\.0\.0/0|default) dev lo' && has_local_route=1 || has_local_route=0
  if [ "$has_local_route" -eq 1 ]; then
    ok "table 100 has local 0.0.0.0/0 dev lo route (TPROXY OK)."
  else
    warn "table 100 missing local 0.0.0.0/0 dev lo route."
    mark_fail
  fi
}

check_tproxy_route_test() {
  say "TPROXY functional test (ip route get with fwmark 0x1)"

  route_test="$(ip route get "$TPROXY_TEST_IP" mark 0x1 2>/dev/null || true)"

  if echo "$route_test" | grep -q "local $TPROXY_TEST_IP dev lo"; then
    ok "Marked traffic to $TPROXY_TEST_IP (mark 0x1) is routed to local dev lo (table 100 functional)."
  else
    warn "TPROXY route test FAILED for $TPROXY_TEST_IP with mark 0x1:"
    printf "        %s\n" "$route_test"
    mark_fail
  fi
}

check_iptables() {
  say "iptables SHADOWSOCKS hooks"

  iptables -t nat -L PREROUTING -n -v >/tmp/ssrouter-health-iptables-nat.txt 2>&1 || true
  iptables -t mangle -L PREROUTING -n -v >/tmp/ssrouter-health-iptables-mangle.txt 2>&1 || true

  if iptables -t nat -S SHADOWSOCKS >/dev/null 2>&1; then
    ok "SHADOWSOCKS chain exists in nat table."
  else
    warn "SHADOWSOCKS chain does NOT exist in nat table."
    mark_fail
  fi

  if iptables -t mangle -S SHADOWSOCKS >/dev/null 2>&1; then
    ok "SHADOWSOCKS chain exists in mangle table."
  else
    warn "SHADOWSOCKS chain does NOT exist in mangle table."
    mark_fail
  fi

  if iptables -t nat -L PREROUTING -n 2>/dev/null | grep -q 'SHADOWSOCKS'; then
    ok "nat PREROUTING jumps to SHADOWSOCKS."
  else
    warn "nat PREROUTING does NOT jump to SHADOWSOCKS."
    mark_fail
  fi

  if iptables -t mangle -L PREROUTING -n 2>/dev/null | grep -q 'SHADOWSOCKS'; then
    ok "mangle PREROUTING jumps to SHADOWSOCKS."
  else
    warn "mangle PREROUTING does NOT jump to SHADOWSOCKS."
    mark_fail
  fi
}

check_dns_tunnel() {
  say "DNS tunnel behavior (via ss-tunnel)"

  # Prefer dig + Cloudflare whoami (proves it's going over SS)
  if command -v dig >/dev/null 2>&1; then
    out="$(dig @127.0.0.1 -p 8054 CH TXT whoami.cloudflare +short 2>&1 || true)"
    echo "$out" >/tmp/ssrouter-health-dns.txt 2>&1 || true

    if echo "$out" | grep -qiE 'communications error|no servers could be reached'; then
      warn "DNS tunnel FAILED (connection error to ss-tunnel):"
      printf "        %s\n" "$out"
      mark_fail
    elif [ -n "$out" ]; then
      ok "DNS tunnel OK (whoami.cloudflare: $out)"
    else
      warn "DNS tunnel FAILED (empty whoami.cloudflare response)."
      mark_fail
    fi
    return
  fi

  # Fallback: nslookup to 127.0.0.1 (less strong, but better than nothing)
  if command -v nslookup >/dev/null 2>&1; then
    nslookup "$DNS_TEST_DOMAIN" 127.0.0.1 >/tmp/ssrouter-health-dns.txt 2>&1 || true

    if grep -q "Address" /tmp/ssrouter-health-dns.txt 2>/dev/null; then
      ok "nslookup $DNS_TEST_DOMAIN @127.0.0.1 returned an address (tunnel resolving)."
    else
      warn "nslookup $DNS_TEST_DOMAIN @127.0.0.1 FAILED. See /tmp/ssrouter-health-dns.txt."
      mark_fail
    fi
  else
    warn "Neither dig nor nslookup found; cannot test DNS tunnel."
    mark_fail
  fi
}

check_external_ip() {
  say "External IP from router (optional)"

  if [ -z "$EXPECTED_EGRESS_IP" ]; then
    printf "    EXPECTED_EGRESS_IP not set; skipping strict comparison.\n"
  fi

  external_ip=""

  if command -v curl >/dev/null 2>&1; then
    external_ip="$(curl -s --max-time 5 https://ifconfig.me || true)"
  elif command -v wget >/dev/null 2>&1; then
    external_ip="$(wget -qO- https://ifconfig.me 2>/dev/null || true)"
  else
    warn "curl/wget not available; skipping external IP check."
    return
  fi

  if [ -z "$external_ip" ]; then
    warn "Failed to retrieve external IP from ifconfig.me."
    mark_fail
    return
  fi

  printf "    External IP (router): %s\n" "$external_ip"

  if [ -n "$EXPECTED_EGRESS_IP" ] && [ "$external_ip" != "$EXPECTED_EGRESS_IP" ]; then
    warn "External IP does NOT match EXPECTED_EGRESS_IP ($EXPECTED_EGRESS_IP)."
    mark_fail
  else
    ok "External IP check completed."
  fi
}

collect_logs() {
  say "Collecting recent logs (ssproxy / shadowsocks keywords)"

  if command -v logread >/dev/null 2>&1; then
    logread | grep -Ei 'ssproxy|ss-redir|ss-tunnel|shadowsocks' | tail -n 100 \
      >/tmp/ssrouter-health-logs.txt 2>/dev/null || true
    ok "Saved recent related logs to /tmp/ssrouter-health-logs.txt."
  else
    warn "logread not available; skipping log collection."
  fi
}

# === MAIN ====================================================================

check_root
check_binaries
check_dnsmasq
check_processes_and_ports
check_tproxy_routing
check_tproxy_route_test
check_iptables
check_dns_tunnel
check_external_ip
collect_logs

say "Summary"

if [ "$summary_failed" -ne 0 ]; then
  warn "One or more health checks FAILED. See /tmp/ssrouter-health-* files for debug details."
  exit 1
else
  ok "All health checks PASSED. ssproxy + TPROXY path looks correct."
  exit 0
fi
