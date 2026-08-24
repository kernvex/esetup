#!/usr/bin/env bash
# Install the Tailscale MTU keeper as a LaunchDaemon. Run with sudo:
#   sudo scripts/install-tailscale-mtu.sh          # install/update (MTU 1080)
#   sudo scripts/install-tailscale-mtu.sh 1120     # install with a different MTU
#   sudo scripts/install-tailscale-mtu.sh --uninstall
#
# Why a daemon and not a login item: setting an interface MTU needs root, and the value is
# lost on every Tailscale reconnect and every reboot. Why a *copy* into /usr/local/sbin and
# not the repo path: a root job must not execute a script out of a user-writable directory,
# or anything running as the user could rewrite it and gain root.
set -euo pipefail

LABEL="com.kernvex.tailscale-mtu"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"
TARGET="/usr/local/sbin/tailscale-mtu.sh"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/tailscale-mtu.sh"
LOG="/var/log/tailscale-mtu.log"

[[ $EUID -eq 0 ]] || { echo "must run as root: sudo $0 $*" >&2; exit 1; }

if [[ "${1:-}" == "--uninstall" ]]; then
  launchctl bootout "system/${LABEL}" 2>/dev/null || launchctl unload "$PLIST" 2>/dev/null || true
  rm -f "$PLIST" "$TARGET"
  echo "uninstalled ${LABEL} (the running MTU is left as-is; it resets on reconnect)"
  exit 0
fi

MTU="${1:-1080}"
[[ "$MTU" =~ ^[0-9]+$ ]] || { echo "MTU must be numeric, got '$MTU'" >&2; exit 2; }
[[ -f "$SRC" ]] || { echo "missing $SRC" >&2; exit 1; }

install -o root -g wheel -m 755 "$SRC" "$TARGET"

cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${TARGET}</string>
    <string>apply</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>TAILSCALE_MTU</key>
    <string>${MTU}</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <!-- Polling rather than a network-change trigger: launchd's network watchers fire before
       Tailscale has finished bringing the interface up, so the MTU would be set on an
       interface that then gets replaced. A 30s idempotent check is cheap and never races. -->
  <key>StartInterval</key>
  <integer>30</integer>
  <key>StandardOutPath</key>
  <string>${LOG}</string>
  <key>StandardErrorPath</key>
  <string>${LOG}</string>
</dict>
</plist>
PLIST_EOF

chown root:wheel "$PLIST"; chmod 644 "$PLIST"

launchctl bootout "system/${LABEL}" 2>/dev/null || true
launchctl bootstrap system "$PLIST"

echo "installed ${LABEL} (MTU ${MTU})"
echo "  script: $TARGET"
echo "  plist : $PLIST"
echo "  log   : $LOG"
