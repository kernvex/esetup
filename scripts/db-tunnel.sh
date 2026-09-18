#!/usr/bin/env bash
# Bring up (or check, or tear down) the SSH port-forward that routes a local port to the
# client's prod MSSQL *through* the home Mac, so the DB sees the allowlisted home IP.
# Reads scripts/db-tunnel.env.  Usage: db-tunnel.sh [up|status|down]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/db-tunnel.env"

[[ -f "$ENV_FILE" ]] || { echo "missing $ENV_FILE (copy db-tunnel.env.example and fill it in)" >&2; exit 1; }
# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a

# Defaulted so `status`/`down` work on a partially-filled env; `up` enforces the
# required ones below (it's the only path that actually opens the connection).
HOME_PIVOT="${HOME_PIVOT:-}"
HOME_USER="${HOME_USER:-}"
PROD_HOST="${PROD_HOST:-}"
PROD_PORT="${PROD_PORT:-1433}"
LOCAL_PORT="${LOCAL_PORT:-14330}"

# Use the dedicated key only (IdentitiesOnly), so ssh doesn't cycle through every other
# key in ~/.ssh and trip "Too many authentication failures". ~ won't expand inside the
# quoted env value, so do it by hand.
ssh_key_opts=()
if [[ -n "${HOME_SSH_KEY:-}" ]]; then
  ssh_key_opts=(-i "${HOME_SSH_KEY/#\~/$HOME}" -o IdentitiesOnly=yes)
fi

is_up() { nc -z 127.0.0.1 "$LOCAL_PORT" >/dev/null 2>&1; }
# Unique enough to identify our forward among any other ssh processes.
forward_pattern="-L ${LOCAL_PORT}:${PROD_HOST}:${PROD_PORT}"

tailscale_bin() {
  if command -v tailscale >/dev/null 2>&1; then
    command -v tailscale
  elif [[ -x /Applications/Tailscale.app/Contents/MacOS/Tailscale ]]; then
    echo /Applications/Tailscale.app/Contents/MacOS/Tailscale
  fi
}

# The pivot is reached over Tailscale. While Tailscale is stopped its 100.64/10 address has
# no route, so the SYN falls through to the default gateway and is dropped in silence: ssh
# then sits in TCP retransmit for the full 75s of net.inet.tcp.keepinit, printing nothing,
# and looks hung. Fail here instead, where we can say what to do about it.
require_tailscale_up() {
  [[ "$HOME_PIVOT" =~ ^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\. ]] || return 0
  local ts state peer
  ts="$(tailscale_bin)"
  [[ -n "$ts" ]] || return 0   # can't tell; let ssh try
  state="$("$ts" status --json 2>/dev/null \
    | sed -n 's/.*"BackendState"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
  if [[ "$state" != "Running" ]]; then
    echo "tailscale is ${state:-unreachable}, so ${HOME_PIVOT} has no route -- run 'tailscale up', then retry" >&2
    exit 1
  fi
  # Local Tailscale being up says nothing about the pivot itself. It is a residential Mac
  # whose Tailscale dies on an unattended reboot (router-setup ADR-0016): the peer then reads
  # 'offline' here while our own BackendState stays Running, and ssh would sit in ConnectTimeout
  # printing nothing. Name the real cause instead of letting it look like a generic timeout.
  peer="$("$ts" status 2>/dev/null | grep -F "$HOME_PIVOT" || true)"
  if [[ -n "$peer" ]] && grep -q "offline" <<<"$peer"; then
    echo "pivot ${HOME_PIVOT} is offline in Tailscale -- nobody is logged into the home Mac (its Tailscale needs a login session to start after a reboot). Log in there, then retry." >&2
    exit 1
  fi
}

case "${1:-up}" in
  status)
    is_up && echo "tunnel up on 127.0.0.1:${LOCAL_PORT}" || echo "tunnel down"
    ;;
  down)
    pkill -f "$forward_pattern" 2>/dev/null && echo "tunnel torn down" || echo "no matching tunnel"
    ;;
  up)
    : "${HOME_PIVOT:?set HOME_PIVOT in db-tunnel.env}"
    : "${HOME_USER:?set HOME_USER in db-tunnel.env}"
    : "${PROD_HOST:?set PROD_HOST in db-tunnel.env}"
    if is_up; then echo "tunnel already up on 127.0.0.1:${LOCAL_PORT}"; exit 0; fi
    require_tailscale_up
    ssh -f -N \
      ${ssh_key_opts[@]+"${ssh_key_opts[@]}"} \
      -o ConnectTimeout=10 \
      -o ExitOnForwardFailure=yes \
      -o ServerAliveInterval=30 \
      -o ServerAliveCountMax=3 \
      -L "${LOCAL_PORT}:${PROD_HOST}:${PROD_PORT}" \
      "${HOME_USER}@${HOME_PIVOT}"
    # ssh -f backgrounds after auth; poll briefly until the forward is listening.
    for _ in 1 2 3 4 5; do is_up && break; sleep 0.5; done
    if is_up; then
      echo "tunnel up on 127.0.0.1:${LOCAL_PORT} -> ${PROD_HOST}:${PROD_PORT} via ${HOME_USER}@${HOME_PIVOT}"
    else
      echo "tunnel failed to come up" >&2; exit 1
    fi
    ;;
  *)
    echo "usage: $(basename "$0") [up|status|down]" >&2; exit 2 ;;
esac
