#!/usr/bin/env bash
# Hold Tailscale's tunnel MTU below what this site's uplink can actually carry.
#
# Why this exists: the site's internet path is L2TP(1280) -> GRE(1280) (see router-setup
# docs/adr/0012), so the wire carries ~1280 bytes. Tailscale defaults its tunnel to 1280 and
# then adds 60 bytes of WireGuard+UDP+IP overhead, putting 1340 bytes on a path that drops
# anything over ~1280. Small packets pass, so SSH authenticates and `nc -z` succeeds, and the
# first full-size packet -- a TLS ClientHello -- vanishes. The symptom is a connection that
# hangs or dies with "Broken pipe" long after the handshake looked healthy.
#
# The router's MSS clamping cannot fix this: Tailscale is WireGuard over UDP, so there is no
# TCP SYN for the router to rewrite and the inner TCP is encrypted.
#
# 1080 is chosen so 1080+60=1140 fits both the main LAN (~1280) and the Client Segment
# (~1160, ADR-0012's "less WireGuard twice"). 1100 would sit exactly on the segment's ceiling.
#
# Usage: tailscale-mtu.sh [apply|check]
#   apply  set the MTU if it has drifted (needs root; run from the LaunchDaemon)
#   check  report only, no root needed; used by db-doctor.sh
#          exit 0 correct, 1 drifted, 2 cannot tell (Tailscale down)
set -euo pipefail

DESIRED_MTU="${TAILSCALE_MTU:-1080}"

log() { printf '%s tailscale-mtu: %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*"; }

# Find the interface by its CGNAT address rather than by name: the utun number is assigned in
# connection order and moves between reboots (it was utun4 here, and a stale note said utun5).
tailscale_iface() {
  local i ip
  for i in $(seq 0 15); do
    ip=$(ifconfig "utun$i" 2>/dev/null | awk '/inet /{print $2; exit}') || true
    [[ -n "${ip:-}" ]] || continue
    if [[ "$ip" =~ ^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\. ]]; then
      echo "utun$i"; return 0
    fi
  done
  return 1
}

iface_mtu() { ifconfig "$1" 2>/dev/null | sed -n 's/.*mtu \([0-9]*\).*/\1/p' | head -1; }

case "${1:-apply}" in
  check)
    # Exit 2, not 0: "cannot tell" is not "correct". db-doctor.sh shows this amber
    # rather than green, so a stopped Tailscale never reads as a passing MTU check.
    if ! iface=$(tailscale_iface); then
      echo "tailscale interface absent (Tailscale stopped?) - MTU not verifiable"; exit 2
    fi
    cur=$(iface_mtu "$iface")
    if [[ "$cur" == "$DESIRED_MTU" ]]; then
      echo "$iface MTU $cur (correct)"; exit 0
    fi
    echo "$iface MTU $cur, expected $DESIRED_MTU - large packets will be dropped"; exit 1
    ;;
  apply)
    # Absent interface is not an error: Tailscale is simply down, and the daemon will pick it
    # up on a later run. Exiting non-zero here would make launchd log noise every 30s.
    if ! iface=$(tailscale_iface); then exit 0; fi
    cur=$(iface_mtu "$iface")
    [[ "$cur" == "$DESIRED_MTU" ]] && exit 0   # already right; stay quiet
    # macOS ifconfig exits 0 even when the ioctl is refused ("Operation not permitted"),
    # so its status proves nothing. Read the MTU back and compare.
    ifconfig "$iface" mtu "$DESIRED_MTU" 2>/dev/null || true
    now=$(iface_mtu "$iface")
    if [[ "$now" == "$DESIRED_MTU" ]]; then
      log "$iface MTU $cur -> $DESIRED_MTU"
    else
      log "FAILED to set $iface MTU (still $now; needs root)"; exit 1
    fi
    ;;
  *)
    echo "usage: $(basename "$0") [apply|check]" >&2; exit 2 ;;
esac
