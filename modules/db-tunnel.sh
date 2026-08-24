# Module: db-tunnel — sourced by setup.sh, not executable on its own.
# Depends on shared machinery in setup.sh: brew_owns_cask, brew_install_cask,
# brew_install_formula, prompt_yes_no, record_manual, and the NONINTERACTIVE global.
#
# Purpose: reach a *client's* production Microsoft SQL Server from this laptop when the
# client allowlists only a residential IP. A second Mac at home (whose public IP is the
# allowlisted one) runs as an always-on SSH pivot. Tailscale gives this laptop a private,
# NAT-proof route to that home Mac without touching the office router, and an
# `ssh -L` forward makes the prod DB connection *originate* from the home IP. `sqlcmd`
# is the read-only query client that talks to the local end of the forward.
#
# Two usage modes, both driven by scripts alongside this module:
#   - Agentic/CLI (surgical): scripts/db-tunnel.sh brings up an ssh -L forward of just the
#     DB port; scripts/db-query.sh runs read-only sqlcmd against it. Leave on all day.
#   - GUI/browser (full tunnel): scripts/db-gui-mode.sh toggles the home Mac as a Tailscale
#     exit node, so the whole laptop (browser, GUI DB tools, whatismyip) egresses from the
#     home IP. Toggle on only while exploring.
#
# Deliberately client-specific, so it is opt-in and modeled on optional_gcloud:
# --upgrade must never *introduce* it onto a machine that never asked for it. Ownership
# of the tailscale-app cask is the "this machine opted in" signal; once owned, both
# artifacts are ordinary convergent installs.
#
# The cask token is tailscale-app, not tailscale (same rename trap as gcloud-cli above:
# `brew list --cask` prints tailscale-app, so naming the old token leaves brew_owns_cask
# false forever). It ships a .pkg, so its install runs a privileged installer and will
# prompt for a sudo password — this Step is not fully unattended on a fresh machine.
optional_db_tunnel() {
  if [[ "$NONINTERACTIVE" -eq 1 ]]; then
    # --upgrade: converge only if this machine already opted in (tailscale owned).
    brew_owns_cask tailscale-app || return 0
    brew_install_cask tailscale-app "Tailscale (mesh VPN to the home SSH pivot)"
    brew_install_formula sqlcmd "sqlcmd (read-only MSSQL client for the tunnel)"
    db_tunnel_manual_notes
    return 0
  fi

  # Ask the opt-in question only when absent; once tailscale is owned the shared Step
  # asks its own "already present, reinstall?" question, and asking both would be two
  # prompts for one decision.
  if ! brew_owns_cask tailscale-app; then
    if ! prompt_yes_no "Set up the client DB tunnel (Tailscale + sqlcmd) on this machine?" n; then
      return 0
    fi
  fi

  brew_install_cask tailscale "Tailscale (mesh VPN to the home SSH pivot)"
  brew_install_formula sqlcmd "sqlcmd (read-only MSSQL client for the tunnel)"
  db_tunnel_manual_notes
}

# Human-only steps this module cannot perform: interactive Tailscale login, enabling
# Remote Login on the home Mac, the client-side allowlist, and the untracked creds file.
db_tunnel_manual_notes() {
  record_manual "db-tunnel" "sign into Tailscale on this Mac AND on the home Mac (same tailnet)"
  record_manual "db-tunnel" "on the home Mac (the pivot): sudo systemsetup -f -setremotelogin on"
  record_manual "db-tunnel" "client must allowlist the home Mac's public IP; it is dynamic, so re-whitelisting is needed if it changes"
  record_manual "db-tunnel" "create scripts/db-tunnel.env (gitignored) from scripts/db-tunnel.env.example with the prod host + read-only creds"
  record_manual "db-tunnel" "for GUI mode: advertise the home Mac as a Tailscale exit node and approve it once in the admin console"
  record_manual "db-tunnel" "sudo scripts/install-tailscale-mtu.sh — Tailscale's default 1280 MTU does not fit this site's ~1280-byte uplink; without it SSH connects and then large packets vanish"
}
