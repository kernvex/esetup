#!/usr/bin/env bash
# Readiness check for the client DB tunnel: reports what's ready vs still pending,
# without printing any secret. Run any time: scripts/db-doctor.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/db-tunnel.env"
# Guarded because this script runs without `set -e`: an unguarded source of a missing
# db-lib.sh would carry on, leave TS empty, and report "Tailscale not installed" - a
# confidently wrong diagnosis from the one script whose whole job is diagnosis.
[[ -f "${SCRIPT_DIR}/db-lib.sh" ]] || { echo "missing ${SCRIPT_DIR}/db-lib.sh (incomplete checkout?)" >&2; exit 1; }
# shellcheck source=db-lib.sh
source "${SCRIPT_DIR}/db-lib.sh"

ok()   { printf '  \033[0;32m✓\033[0m %s\n' "$1"; }
pend() { printf '  \033[0;33m…\033[0m %s\n' "$1"; }
bad()  { printf '  \033[0;31m✗\033[0m %s\n' "$1"; }

# shellcheck disable=SC1090
[[ -f "$ENV_FILE" ]] && { set -a; source "$ENV_FILE"; set +a; }

echo "db-tunnel readiness"

# 1. Tooling
command -v sqlcmd >/dev/null && ok "sqlcmd installed" || bad "sqlcmd missing (run the db-tunnel module)"
TS="$(tailscale_bin)"
[[ -n "$TS" ]] && ok "Tailscale present" || bad "Tailscale not installed"

# 2. Config file
[[ -f "$ENV_FILE" ]] && ok "db-tunnel.env exists" || bad "db-tunnel.env missing (copy db-tunnel.env.example)"
for v in HOME_PIVOT HOME_USER HOME_SSH_KEY PROD_HOST DB_NAME DB_USER DB_PASSWORD; do
  # Never print the value — only whether it's set.
  if [[ -n "${!v:-}" ]]; then ok "$v set"; else pend "$v not set yet"; fi
done

# 3. Local SSH key
key="${HOME_SSH_KEY/#\~/$HOME}"
[[ -n "${HOME_SSH_KEY:-}" && -f "$key" ]] && ok "ssh key present ($HOME_SSH_KEY)" || pend "ssh key not found locally"

# 4. Reachability + auth to the home pivot
#
# SSH is the authoritative test - it is the thing db-tunnel.sh actually needs -
# so it runs first and decides. A cheap `nc` probe only runs afterwards, to
# explain a failure. The reverse (nc gating ssh) reported the pivot dead
# whenever Tailscale was relaying through DERP: a cold relay costs well over the
# 4s the probe allowed, while SSH itself connects fine given a moment. Never let
# a fast proxy metric overrule the slower measurement that is the real question.
if [[ -n "${HOME_PIVOT:-}" && -n "${HOME_USER:-}" && -f "$key" ]] \
   && ssh -o BatchMode=yes -o ConnectTimeout=20 -i "$key" -o IdentitiesOnly=yes \
          "${HOME_USER}@${HOME_PIVOT}" true 2>/dev/null; then
  ok "home Mac reachable and passwordless SSH works ($HOME_PIVOT)"
elif [[ -n "${HOME_PIVOT:-}" ]] && nc -z -G 20 "$HOME_PIVOT" 22 >/dev/null 2>&1; then
  # Port open but SSH refused: the path is fine, the credential is not.
  pend "home Mac reachable on :22 but SSH key not accepted - authorize it there"
else
  pend "home Mac not reachable (Tailscale down on one end, or still relaying?)"
fi

# 5. Tailscale tunnel MTU
#
# The failure this catches is the one that looks like success: SSH authenticates, `nc -z`
# passes, and then the first full-size packet - a TLS ClientHello - vanishes, so the
# connection dies of a broken pipe long after everything above went green. This site's
# uplink carries ~1280 bytes (L2TP+GRE, router-setup ADR-0012) while Tailscale defaults its
# tunnel to 1280 and adds 60 bytes of WireGuard+UDP+IP on top. The router's MSS clamping
# cannot rescue it: WireGuard is UDP, so there is no TCP SYN to rewrite.
if [[ -x "${SCRIPT_DIR}/tailscale-mtu.sh" ]]; then
  mtu_msg=$("${SCRIPT_DIR}/tailscale-mtu.sh" check 2>/dev/null)
  case $? in
    0) ok   "$mtu_msg" ;;
    2) pend "$mtu_msg" ;;
    *) bad  "$mtu_msg — run: sudo scripts/install-tailscale-mtu.sh" ;;
  esac
fi

# 6. Exit node (GUI mode)
#
# `exit-node list` queries the control plane and is flaky when Tailscale is
# relaying through DERP - measured 1 pass in 3 while the datacentre was policing
# UDP, which reported the exit node missing when it was there the whole time.
# `status` reads the local daemon's cached netmap instead: no round trip, 6 of 6
# in the same conditions. Prefer local state for a question local state can
# answer.
if [[ -n "$TS" ]]; then
  # ts_exit_node_state tests 'offline' before the exit-node tokens (see db-lib.sh): a dead
  # pivot still advertises 'offers exit node', and reading that as ready is how it passed every
  # check for 2.5 days (router-setup ADR-0016). 'available'/'in-use' both mean ready here.
  case "$(ts_exit_node_state "$(ts_peer_line "$TS" "${EXIT_NODE:-__none__}")")" in
    absent)           pend "exit node ${EXIT_NODE:-<unset>} not in the tailnet right now" ;;
    offline)          bad  "exit node ${EXIT_NODE} is OFFLINE (its Tailscale is down — likely no login session after a reboot)" ;;
    available|in-use) ok   "exit node advertised & approved (${EXIT_NODE})" ;;
    *)                pend "exit node not available yet (advertise on home + approve in admin console)" ;;
  esac
fi

# 7. Tunnel state
"${SCRIPT_DIR}/db-tunnel.sh" status 2>/dev/null | sed 's/^/  /'
