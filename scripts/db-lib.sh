# db-lib.sh -- shared helpers for the db-tunnel tooling family (db-doctor, db-gui-mode,
# db-tunnel). Sourced, never executed: it only defines functions and has no side effects
# at source time, so `set -euo pipefail` callers can source it safely.
#
# The reason this file exists: the "read a peer's `tailscale status` line, then decide
# offline before the exit-node tokens" rule was copied into three scripts. An offline peer
# still advertises 'offers exit node' with 'offline, last seen ...' appended (router-setup
# ADR-0016: the pivot's Tailscale dies on an unattended reboot), so the offline token must be
# tested first. Encoding that once means Tailscale changing its wording is a one-file edit.

# Echo the path to a usable tailscale CLI, or nothing if none is found. Prefer one on PATH;
# fall back to the macOS app bundle's CLI. Always returns 0 so a `ts=$(tailscale_bin)`
# assignment never trips `set -e`; callers test the result for emptiness and decide what an
# empty result means (db-doctor reports it, db-gui-mode exits, db-tunnel lets ssh try).
tailscale_bin() {
  if command -v tailscale >/dev/null 2>&1; then
    command -v tailscale
  elif [[ -x /Applications/Tailscale.app/Contents/MacOS/Tailscale ]]; then
    echo /Applications/Tailscale.app/Contents/MacOS/Tailscale
  fi
  return 0
}

# Echo the `tailscale status` line for the peer matched by $2 (an IP or MagicDNS name), using
# the CLI in $1. Empty if the peer is not listed or status could not be read.
ts_peer_line() {
  local ts="$1" needle="$2"
  [[ -n "$ts" && -n "$needle" ]] || return 0
  "$ts" status 2>/dev/null | grep -F "$needle" || true
}

# True when a peer's status line ($1) reports it offline. An offline peer still carries the
# exit-node tokens, so 'offline' is the token that must decide.
ts_line_offline() {
  grep -q "offline" <<<"${1:-}"
}

# Classify an exit-node peer's status line ($1) into one state string. 'offline' is tested
# before the exit-node tokens because an offline line still carries them. 'exit node' matches
# both the offered form ('offers exit node') and the in-use form.
#   absent | offline | available | in-use | peer-present
ts_exit_node_state() {
  local line="${1:-}"
  if   [[ -z "$line" ]];                       then echo "absent"
  elif grep -q "offline" <<<"$line";           then echo "offline"
  elif grep -q "offers exit node" <<<"$line";  then echo "available"
  elif grep -q "exit node"        <<<"$line";  then echo "in-use"
  else                                              echo "peer-present"
  fi
}
