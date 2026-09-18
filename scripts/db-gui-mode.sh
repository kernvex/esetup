#!/usr/bin/env bash
# Route ALL of this laptop's traffic through the home Mac (Tailscale exit node), so the
# browser, GUI DB tools, and sites like whatismyip all show the home residential IP.
# This is the full-tunnel counterpart to db-tunnel.sh (which forwards only the DB port).
# Toggle it on only while exploring; leave it off for normal work.
#
# One-time prerequisites (see modules/db-tunnel.sh manual notes):
#   1. Home Mac advertises the exit node (Tailscale app: This device -> Exit node ->
#      Run as exit node; or `tailscale set --advertise-exit-node`).
#   2. Approve it once in the admin console (Machines -> home Mac -> exit node route).
#
# Usage: db-gui-mode.sh [on|off|status]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/db-tunnel.env"
# shellcheck disable=SC1090
[[ -f "$ENV_FILE" ]] && { set -a; source "$ENV_FILE"; set +a; }

# Prefer a tailscale on PATH; fall back to the macOS app bundle's CLI.
if command -v tailscale >/dev/null 2>&1; then
  TS=tailscale
elif [[ -x /Applications/Tailscale.app/Contents/MacOS/Tailscale ]]; then
  TS=/Applications/Tailscale.app/Contents/MacOS/Tailscale
else
  echo "tailscale CLI not found (is the app installed?)" >&2; exit 1
fi

# Literal address on purpose: cdn-cgi/trace needs no DNS, so a resolver problem
# cannot masquerade as "no connectivity". api.ipify.org needed both DNS and TCP
# and reported the same unhelpful string whichever failed.
show_ip() {
  curl -s --max-time 10 https://1.1.1.1/cdn-cgi/trace 2>/dev/null | awk -F= '/^ip=/{print $2}'
}

# Ask the local daemon, not the control plane. `tailscale exit-node list` passed
# 1 run in 3 while relaying through DERP; `status` reads the cached netmap and
# was 6 of 6 in the same conditions.
exit_node_state() {
  local line
  line=$("$TS" status 2>/dev/null | grep -F "${EXIT_NODE:-__none__}" || true)
  # 'offline' is tested before the exit-node tokens on purpose: a peer that is down still
  # carries 'offers exit node' in its status line, with 'offline, last seen ...' appended.
  # Reading that as 'available' is how a dead pivot looked healthy for 2.5 days (router-setup
  # ADR-0016: its Tailscale dies on an unattended reboot).
  if   [[ -z "$line" ]];                       then echo "absent"
  elif grep -q "offline" <<<"$line";           then echo "offline"
  elif grep -q "offers exit node" <<<"$line";  then echo "available"
  elif grep -q "exit node"        <<<"$line";  then echo "in-use"
  else                                              echo "peer-present"
  fi
}

# The failure this exists to catch: with the exit node engaged, ICMP and DNS pass
# while every TCP connection hangs. That is the tunnel MTU exceeding what the
# underlying path carries - seen 12 Aug 2026, Tailscale at 1280 inside
# L2TP(1280)->GRE(1280), silently dropping every full-size packet. Ping is not
# evidence that the path works.
diagnose_no_tcp() {
  if ping -c 2 -t 5 8.8.8.8 >/dev/null 2>&1; then
    local iface
    iface=$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')
    echo "  ICMP works but TCP does not - almost certainly tunnel MTU."
    echo "  try: sudo ifconfig ${iface:-utun5} mtu 1100"
  else
    echo "  no ICMP either - the exit node itself is unreachable."
  fi
}

case "${1:-status}" in
  on)
    : "${EXIT_NODE:?set EXIT_NODE in db-tunnel.env (the home Mac Tailscale name)}"
    # Refuse an offline (or absent) node. `tailscale set` accepts an offline node without
    # complaint, then routes every packet into a peer that cannot answer and the whole laptop
    # goes dark (ICMP/DNS may limp through DERP while all TCP hangs). Fail here with the reason.
    case "$(exit_node_state)" in
      offline) echo "refusing: exit node ${EXIT_NODE} is OFFLINE -- routing all traffic through it would black-hole this laptop" >&2; exit 1 ;;
      absent)  echo "refusing: exit node ${EXIT_NODE} is not in the tailnet right now" >&2; exit 1 ;;
    esac
    # allow-lan-access keeps local devices (printers, router) reachable while tunneled.
    "$TS" set --exit-node="$EXIT_NODE" --exit-node-allow-lan-access=true
    echo "exit node ON -> $EXIT_NODE"
    echo -n "public IP now: "; show_ip
    ;;
  off)
    "$TS" set --exit-node=
    echo "exit node OFF (direct connection)"
    echo -n "public IP now: "; show_ip
    ;;
  status)
    state=$(exit_node_state)
    case "$state" in
      in-use)      echo "exit node ACTIVE  -> ${EXIT_NODE}" ;;
      available)   echo "exit node off (${EXIT_NODE} is advertising, not in use)" ;;
      offline)     echo "exit node ${EXIT_NODE} is OFFLINE (its Tailscale is down -- likely no login session after a reboot)" ;;
      peer-present) echo "peer ${EXIT_NODE} visible but not offering an exit node" ;;
      absent)      echo "peer ${EXIT_NODE} not in the tailnet right now" ;;
    esac
    ip=$(show_ip)
    if [[ -n "$ip" ]]; then
      echo "public IP: $ip"
    else
      echo "public IP: unreachable"
      [[ "$state" == "in-use" ]] && diagnose_no_tcp
    fi
    ;;
  *)
    echo "usage: $(basename "$0") [on|off|status]" >&2; exit 2 ;;
esac
