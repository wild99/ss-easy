# shellcheck shell=bash
#
# lib/install.sh — the full install orchestrator (Decisions 2, 3, 4, 10).
#
# This is the top layer that wires the Wave 1-3 modules into one turnkey flow:
#
#   preflight -> runtime deps -> ss-rust binary -> /etc/ss-easy + service user
#   -> registry init -> server address -> first user -> config.json
#   -> systemd unit + enable + start -> firewall port + BBR -> post-install block
#
# Two run modes, selected by the caller via the parsed options:
#   - interactive: confirm the auto-detected IP, allow method/port/IP override.
#   - silent (--silent): random high port, crypto-random secret, auto IP, BBR;
#     no prompts at all.
#
# IDEMPOTENCY (Decision 2 — users.json is the source of truth):
#   - empty/absent registry  -> first install (create the first user).
#   - non-empty registry      -> repair/upgrade run: existing users and their
#     secrets are NEVER recreated; a missing/broken unit or firewall rule is
#     restored; the binary is reinstalled (and the service restarted) only when
#     the installed version differs from the pinned SS_RUST_VERSION.
#
# SECRET HYGIENE (Decision 10):
#   secrets reach only the terminal, the QR, and the 0600 access file. The audit
#   log records timestamp + action + user name, NEVER a secret. No `set -x` runs
#   over a credential here.
#
# This module DELEGATES all real work to the modules it sources; it owns no JSON,
# no curl, no systemctl call of its own — only sequencing, idempotency decisions,
# and the operator-facing report. The entrypoint calls do_install with the
# already-parsed CLI options.

# Guard against double-sourcing in the assembled bundle / nested sources.
if [ -n "${_SS_EASY_INSTALL_LOADED:-}" ]; then
  # shellcheck disable=SC2317  # reached only on re-source of this module.
  return 0 2>/dev/null || true
fi
_SS_EASY_INSTALL_LOADED=1

# Depend on common.sh and the Wave 1-3 modules. In the assembled bundle every
# module is inlined ahead of this one and the guards are already set, so this
# block is a no-op there; in dev/test we source our siblings so the orchestrator
# is usable standalone. The test suite sources only the pure modules and stubs
# the side-effecting boundaries, so missing siblings here must not be fatal.
# build:strip-start
if [ -z "${_SS_EASY_COMMON_LOADED:-}" ]; then
  _ss_inst_self="${BASH_SOURCE[0]}"
  _ss_inst_dir="${_ss_inst_self%/*}"
  [ "$_ss_inst_dir" = "$_ss_inst_self" ] && _ss_inst_dir="."
  for _ss_inst_mod in common preflight pkg binary config users link network service firewall; do
    if [ -f "${_ss_inst_dir}/${_ss_inst_mod}.sh" ]; then
      # shellcheck source=/dev/null
      . "${_ss_inst_dir}/${_ss_inst_mod}.sh"
    fi
  done
  unset _ss_inst_self _ss_inst_dir _ss_inst_mod
fi
# build:strip-end

# Audit log target (Decision 10). A 0600 file, root-owned; overridable so the
# test suite can point it at a temp path. Secrets are NEVER written here.
: "${SS_AUDIT_LOG:=/var/log/ss-easy.log}"

# --- audit log --------------------------------------------------------------

# audit_log <action> [detail...] — append "<utc-timestamp> <action> <detail>" to
# the 0600 audit log. The file is created 0600 on first write and the mode is
# re-asserted every time, so it can never become world-readable. Callers MUST
# pass only non-secret values (action name, user name) — never a key/password.
audit_log() {
  local action="${1:-}"; shift || true
  local detail="$*"
  local ts dir
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  dir="$(dirname "$SS_AUDIT_LOG")"
  [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null || true

  # Create with 0600 BEFORE the first write so there is no world-readable window.
  if [ ! -e "$SS_AUDIT_LOG" ]; then
    ( umask 077; : > "$SS_AUDIT_LOG" ) 2>/dev/null || true
  fi
  printf '%s %s %s\n' "$ts" "$action" "$detail" >> "$SS_AUDIT_LOG" 2>/dev/null || true
  chmod 600 "$SS_AUDIT_LOG" 2>/dev/null || true
}

# --- state probes (idempotency inputs) --------------------------------------
#
# These read host state to decide repair/upgrade actions. They are defined here
# (not in the leaf modules) because they are pure install-orchestration concerns;
# the test suite overrides them to drive the idempotency branches deterministically.

# ss_installed_version — print the version string of the already-installed
# ssserver binary, or nothing if it is absent/unparseable. `ssserver --version`
# prints e.g. "shadowsocks 1.23.5"; we normalise to the "vX.Y.Z" tag shape used
# by SS_RUST_VERSION so the comparison is apples-to-apples.
ss_installed_version() {
  [ -x "$SS_SERVER_BIN" ] || return 0
  local raw ver
  raw="$("$SS_SERVER_BIN" --version 2>/dev/null | head -n1)" || return 0
  # Extract the first dotted number group (e.g. 1.23.5) and re-prefix with 'v'.
  ver="$(printf '%s' "$raw" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)"
  [ -n "$ver" ] || return 0
  printf 'v%s' "$ver"
}

# service_unit_installed — rc 0 if the systemd unit file already exists. Used to
# decide whether a repair run must (re)install the unit.
service_unit_installed() {
  local unit="${SS_UNIT_FILE:-/etc/systemd/system/${SS_SERVICE_NAME}}"
  [ -f "$unit" ]
}

# --- registry state ---------------------------------------------------------

# _install_registry_empty — rc 0 if there are no users yet (first-install path).
# A missing registry counts as empty. users.json is the single source of truth.
_install_registry_empty() {
  [ -f "$SS_EASY_USERS" ] || return 0
  local n
  n="$(jq '.users | length' "$SS_EASY_USERS" 2>/dev/null || printf '0')"
  [ "${n:-0}" -eq 0 ]
}

# _install_first_user_name — print the name of the first user in the registry
# (used by the post-install report on a repair run where we created no user).
_install_first_user_name() {
  [ -f "$SS_EASY_USERS" ] || return 1
  jq -r '.users[0].name // empty' "$SS_EASY_USERS" 2>/dev/null
}

# --- server address resolution ---------------------------------------------

# _install_resolve_address <silent> <ip_override> — decide the server address.
#   * explicit override always wins (validated by net_detect_public_ip).
#   * silent: auto-detect; on failure warn and fall back to a placeholder so the
#     install still completes (the operator fixes the IP later).
#   * interactive: auto-detect, then confirm / let the operator override.
# Prints the resolved address on stdout (logs go to stderr).
_install_resolve_address() {
  local silent="$1" override="$2"
  local detected=""

  if [ -n "$override" ]; then
    # net_detect_public_ip validates an explicit override and dies if invalid.
    net_detect_public_ip "$override"
    return 0
  fi

  detected="$(net_detect_public_ip 2>/dev/null || true)"

  if [ "$silent" = "1" ]; then
    if [ -z "$detected" ]; then
      log_warn "could not auto-detect a public IP; using a placeholder."
      log_warn "set the real address later with: ss-easy (TUI) or by editing the link host."
      printf '%s' "SERVER_ADDRESS"
      return 0
    fi
    printf '%s' "$detected"
    return 0
  fi

  # Interactive: confirm or override the detected address.
  if [ -n "$detected" ]; then
    if whiptail --yesno "Detected public IP: ${detected}\n\nUse this as the server address?" 12 60 3>&1 1>&2 2>&3; then
      printf '%s' "$detected"
      return 0
    fi
  fi

  local manual
  manual="$(whiptail --inputbox "Enter the server's public IP or hostname:" 10 60 "${detected}" 3>&1 1>&2 2>&3)" \
    || die "install cancelled: no server address provided"
  [ -n "$manual" ] || die "install cancelled: empty server address"
  # Validate the manual entry the same way as an override.
  net_detect_public_ip "$manual"
}

# --- binary install / upgrade ----------------------------------------------

# _install_binary_if_needed <silent> — install the pinned ss-rust binary, or skip
# the download when the already-installed version matches SS_RUST_VERSION. On an
# upgrade (version differs) it reinstalls AND signals the caller (rc 10) that the
# running service must be restarted onto the new binary.
#   rc 0  -> installed fresh, or skipped (no restart needed)
#   rc 10 -> reinstalled over a different version (restart required)
_install_binary_if_needed() {
  local installed
  installed="$(ss_installed_version || true)"

  if [ -n "$installed" ] && [ "$installed" = "$SS_RUST_VERSION" ]; then
    log_info "ssserver already at pinned version ${SS_RUST_VERSION}; skipping download."
    return 0
  fi

  if [ -n "$installed" ] && [ "$installed" != "$SS_RUST_VERSION" ]; then
    log_info "upgrading ssserver: ${installed} -> ${SS_RUST_VERSION}"
    ss_install_binary
    audit_log "binary-upgrade" "${installed}->${SS_RUST_VERSION}"
    return 10
  fi

  # Not installed yet (fresh install).
  ss_install_binary
  audit_log "binary-install" "$SS_RUST_VERSION"
  return 0
}

# --- post-install report ----------------------------------------------------

# _install_report <name> — print the operator-facing block for the first user:
# service status, the ss:// link, an ASCII QR, the access-file path, and
# next-step hints. The link/QR carry the secret by design (the operator needs
# it); nothing here is written to the audit log.
_install_report() {
  local name="$1"
  local rec port method secret host uri access

  rec="$(config_user_show "$name")"
  port="$(printf '%s' "$rec"   | jq -r '.port')"
  method="$(printf '%s' "$rec" | jq -r '.method')"
  secret="$(printf '%s' "$rec" | jq -r '.secret')"
  host="$(config_get_server_address 2>/dev/null || true)"
  [ -n "$host" ] && [ "$host" != "null" ] || host="SERVER_ADDRESS"
  uri="$(link_build "$method" "$secret" "$host" "$port" "$name")"
  access="${SS_EASY_USERS_DIR}/${name}.txt"

  printf '\n'
  printf '========================================\n'
  printf ' ss-easy install complete\n'
  printf '========================================\n'
  # Service status (stderr logging inside the wrapper); keep it in the block.
  service_status || true
  printf '\n'
  printf 'First user : %s\n' "$name"
  printf 'Server     : %s\n' "$host"
  printf 'Port       : %s\n' "$port"
  printf 'Method     : %s\n' "$method"
  printf '\n'
  printf 'Connection link (also written to %s):\n' "$access"
  printf '%s\n' "$uri"
  printf '\n'
  printf 'Scan to import:\n'
  link_render_qr "$uri"
  printf '\n'
  printf 'Access file (mode 0600): %s\n' "$access"
  printf '\n'
  printf 'Next steps:\n'
  printf '  - Add another user : ss-easy user add <name>\n'
  printf '  - List users       : ss-easy user list\n'
  printf '  - Open the menu    : ss-easy\n'
  printf '\n'
}

# --- orchestrator -----------------------------------------------------------

# do_install [options] — the full install flow. Options (parsed here so the
# entrypoint can pass them through verbatim):
#   --silent              no prompts; auto IP, random port, crypto secret, BBR
#   --method <method>     cipher for the first user (default DEFAULT_METHOD)
#   --port <port>         explicit port for the first user (else auto-allocated)
#   --ip <addr>           explicit server address (skips auto-detection)
#   --name <name>         name of the first user (default 'default')
do_install() {
  local silent=0
  local method="$DEFAULT_METHOD"
  local port=""
  local ip=""
  local name="default"

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --silent)        silent=1; shift ;;
      --method)        method="${2:?--method requires an argument}"; shift 2 ;;
      --method=*)      method="${1#*=}"; shift ;;
      --port)          port="${2:?--port requires an argument}"; shift 2 ;;
      --port=*)        port="${1#*=}"; shift ;;
      --ip)            ip="${2:?--ip requires an argument}"; shift 2 ;;
      --ip=*)          ip="${1#*=}"; shift ;;
      --name)          name="${2:?--name requires an argument}"; shift 2 ;;
      --name=*)        name="${1#*=}"; shift ;;
      *) die "install: unknown option '$1'" ;;
    esac
  done

  # Validate an explicit port up front (a clear error beats a later jq failure).
  if [ -n "$port" ]; then
    case "$port" in
      ''|*[!0-9]*) die "install: invalid --port '${port}' (expected a number)" ;;
    esac
    if [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
      die "install: --port out of range '${port}' (expected 1-65535)"
    fi
  fi

  if [ "$silent" = "1" ]; then
    log_info "starting ss-easy install (silent mode)"
  else
    log_info "starting ss-easy install (interactive mode)"
  fi

  # 1) Preflight: root, distro, systemd, network, and (if pinned) port freedom.
  run_preflight "$port" || die "preflight checks failed; aborting install."

  # 2) Runtime dependencies (jq, curl, qrencode, whiptail).
  pkg_ensure_runtime_deps || die "failed to install runtime dependencies."

  # 3) ss-rust binary: install fresh, skip if version matches, or upgrade.
  local restart_needed=0
  _install_binary_if_needed "$silent" || {
    local rc=$?
    if [ "$rc" -eq 10 ]; then restart_needed=1; else
      die "failed to install/verify the ssserver binary."
    fi
  }

  # 4) Config dir (0700) + dedicated service user + registry skeleton.
  service_ensure_user
  config_init

  # 5) Server address (auto/confirm/override), persisted to the registry.
  local address
  address="$(_install_resolve_address "$silent" "$ip")"
  config_set_server_address "$address"
  config_set_default_method "$method"

  # 6) First user — ONLY when the registry is empty (idempotency: never recreate
  #    an existing user or its secret). users_add prints the ss:// link itself,
  #    which carries the secret; capture+discard it so it does not double-print.
  local first_user
  if _install_registry_empty; then
    if [ -n "$port" ]; then
      # An explicit first-user port: add the record directly so it is honoured.
      local secret created
      _users_require_valid_name "$name"
      secret="$(users_gen_secret "$method")"
      created="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      config_user_add "$name" "$port" "$method" "$secret" "$created"
      config_generate
      link_write_access_file "$name" "$address" "$port" "$method" "$secret" \
        "$(link_build "$method" "$secret" "$address" "$port" "$name")"
    else
      users_add "$name" "$method" >/dev/null
    fi
    first_user="$name"
    audit_log "install" "first-user=${name}"
  else
    # Repair/upgrade run: keep the existing registry; regenerate config from it.
    config_generate
    first_user="$(_install_first_user_name || printf '%s' "$name")"
    audit_log "install" "repair first-user=${first_user}"
  fi

  # Recompute the first user's port for the firewall step (it may be auto-allocated).
  local first_port first_rec
  first_rec="$(config_user_show "$first_user" 2>/dev/null || true)"
  first_port="$(printf '%s' "$first_rec" | jq -r '.port // empty' 2>/dev/null || true)"

  # 7) systemd unit: (re)install on every run. service_install_unit is idempotent
  #    and re-asserts the unit content, so a missing/manually-broken unit is
  #    healed here (the service_unit_installed probe drives the repair log only).
  if ! service_unit_installed; then
    log_info "systemd unit missing; (re)installing it."
  fi
  service_install_unit
  service_enable

  if [ "$restart_needed" -eq 1 ]; then
    service_restart
  else
    service_start
  fi

  # 8) Firewall: open the user's port (tcp+udp). firewall_open_port is itself
  #    idempotent (re-adding an existing rule is a no-op) and SSH-safe, so a
  #    repair run that finds a missing rule simply re-creates it. Then BBR.
  if [ -n "$first_port" ]; then
    firewall_open_port "$first_port" tcp
    firewall_open_port "$first_port" udp
  fi
  firewall_enable_bbr

  # 9) Operator-facing report (secrets only here / in the QR / access file).
  _install_report "$first_user"
}
