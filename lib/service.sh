# shellcheck shell=bash
#
# lib/service.sh — the single systemd unit (ss-easy.service) and the systemctl
# lifecycle wrappers (Decisions 5, 11).
#
# One unit runs `ssserver -c <config>` as a dedicated unprivileged system user,
# with hardening directives, so an internet-facing proxy never holds root. The
# CLI (run as root) installs the unit and drives its lifecycle.
#
# PUBLIC CONTRACT (consumed by install/uninstall orchestration, Tasks 8/9):
#   service_ensure_user             idempotently create the dedicated system user
#   service_write_unit              (re)write the unit file atomically (no reload)
#   service_install_unit            ensure user, write unit, then daemon-reload
#   service_remove_unit             remove the unit file, then daemon-reload
#   service_start / service_stop / service_restart
#   service_reload                  reload-or-restart (re-read config, no downtime)
#   service_enable / service_disable
#   service_status                  print active/inactive + listening ports;
#                                   non-zero unless the service is active
#
# Identity/paths come ONLY from common.sh constants (SS_SERVICE_USER,
# SS_SERVER_BIN, SS_SERVICE_NAME, SS_EASY_CONFIG) — never redefined here.
#
# Overridable for testing (default to the real system locations):
#   SS_UNIT_FILE   path of the unit file  (default /etc/systemd/system/<name>)
#
# Sourcing this file has no side effects: only definitions.

# Guard against double-sourcing in the assembled bundle / nested sources.
if [ -n "${_SS_EASY_SERVICE_LOADED:-}" ]; then
  # shellcheck disable=SC2317  # reached only on re-source of this module.
  return 0 2>/dev/null || true
fi
_SS_EASY_SERVICE_LOADED=1

# Depend on common.sh (die, logging, atomic_write, constants). In the assembled
# bundle the modules are inlined and the guard is already set, so this is a
# no-op there; in dev/test the module sources its sibling so it works standalone.
# build:strip-start
if [ -z "${_SS_EASY_COMMON_LOADED:-}" ]; then
  # Resolve our own directory with pure-bash parameter expansion (no external
  # dirname), so the module sources cleanly even under a restricted test PATH.
  _ss_svc_self="${BASH_SOURCE[0]}"
  _ss_svc_dir="${_ss_svc_self%/*}"
  [ "$_ss_svc_dir" = "$_ss_svc_self" ] && _ss_svc_dir="."
  # shellcheck source=lib/common.sh disable=SC1091
  . "${_ss_svc_dir}/common.sh"
  unset _ss_svc_self _ss_svc_dir
fi
# build:strip-end

# Where the unit file lives. Overridable so tests write into a temp dir.
: "${SS_UNIT_FILE:=/etc/systemd/system/${SS_SERVICE_NAME}}"

# --- helpers ----------------------------------------------------------------

# _service_require_systemctl — die unless systemctl is on PATH. The lifecycle
# wrappers are useless without it; fail with an actionable message rather than
# a bare "command not found".
_service_require_systemctl() {
  command -v systemctl >/dev/null 2>&1 \
    || die "systemctl not found: ss-easy manages a systemd service and needs systemd."
}

# _service_nologin_path — print the host's nologin shell. The path differs
# across distros (Debian: /usr/sbin/nologin, RHEL: /sbin/nologin); fall back to
# /bin/false when neither exists so the account still cannot log in.
_service_nologin_path() {
  if [ -x /usr/sbin/nologin ]; then
    printf '/usr/sbin/nologin'
  elif [ -x /sbin/nologin ]; then
    printf '/sbin/nologin'
  else
    printf '/bin/false'
  fi
}

# --- service user -----------------------------------------------------------

# service_ensure_user — create the dedicated unprivileged system account
# (name from SS_SERVICE_USER) if it does not already exist. Idempotent: an
# existing account is left untouched. The account is system-scoped, has no home
# and no interactive shell, so it cannot be used to log in.
service_ensure_user() {
  if getent passwd "$SS_SERVICE_USER" >/dev/null 2>&1; then
    return 0
  fi
  local shell
  shell="$(_service_nologin_path)"
  if ! useradd --system --no-create-home --shell "$shell" "$SS_SERVICE_USER"; then
    die "failed to create system user: $SS_SERVICE_USER"
  fi
  log_info "created system user: $SS_SERVICE_USER"
}

# --- unit file --------------------------------------------------------------

# service_write_unit — render the unit file and write it atomically (0644).
# ExecStart uses the ABSOLUTE binary path from SS_SERVER_BIN: under
# ProtectSystem=strict systemd does not resolve a bare name through PATH.
# The generated config is exposed read-only via ReadOnlyPaths.
service_write_unit() {
  local dir
  dir="$(dirname "$SS_UNIT_FILE")"
  [ -d "$dir" ] || mkdir -p "$dir" || die "cannot create unit dir: $dir"

  # Heredoc the unit, then write atomically (0600 temp -> mv) and relax to 0644
  # so systemd (and operators) can read it.
  cat <<EOF | atomic_write "$SS_UNIT_FILE" || die "failed to write unit: $SS_UNIT_FILE"
[Unit]
Description=ss-easy shadowsocks-rust server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${SS_SERVER_BIN} -c ${SS_EASY_CONFIG}
Restart=on-failure
RestartSec=5
User=${SS_SERVICE_USER}
Group=${SS_SERVICE_USER}

# Hardening (Decision 11): least privilege for an internet-facing proxy.
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
# The service only reads its generated config; expose it read-only explicitly.
ReadOnlyPaths=${SS_EASY_CONFIG}

[Install]
WantedBy=multi-user.target
EOF

  chmod 644 "$SS_UNIT_FILE" || die "cannot chmod 0644: $SS_UNIT_FILE"
}

# service_install_unit — full install: ensure the service user, write the unit,
# and reload systemd so it picks up the new/changed unit.
service_install_unit() {
  _service_require_systemctl
  service_ensure_user
  service_write_unit
  if ! systemctl daemon-reload; then
    die "systemctl daemon-reload failed after writing $SS_UNIT_FILE"
  fi
  log_info "installed unit: $SS_SERVICE_NAME"
}

# service_remove_unit — remove the unit file and reload systemd. Missing file is
# not an error (idempotent uninstall).
service_remove_unit() {
  _service_require_systemctl
  if [ -f "$SS_UNIT_FILE" ]; then
    rm -f "$SS_UNIT_FILE" || die "failed to remove unit: $SS_UNIT_FILE"
  fi
  if ! systemctl daemon-reload; then
    die "systemctl daemon-reload failed after removing $SS_UNIT_FILE"
  fi
  log_info "removed unit: $SS_SERVICE_NAME"
}

# --- lifecycle wrappers -----------------------------------------------------
#
# Each wrapper follows the same shape: require systemctl, call it, check the
# return code, log a human-readable result, propagate the code.

# _service_action <verb> <human-phrase> — run `systemctl <verb> <unit>` and
# report success/failure with an actionable hint.
_service_action() {
  local verb="$1" phrase="$2"
  _service_require_systemctl
  if systemctl "$verb" "$SS_SERVICE_NAME"; then
    log_info "${phrase} ${SS_SERVICE_NAME}"
    return 0
  fi
  log_error "failed to ${phrase%ed} ${SS_SERVICE_NAME}."
  log_error "inspect logs: journalctl -u ${SS_SERVICE_NAME} -n 50 --no-pager"
  return 1
}

service_start()   { _service_action start   "started"; }
service_stop()    { _service_action stop    "stopped"; }
service_restart() { _service_action restart "restarted"; }
service_enable()  { _service_action enable  "enabled"; }
service_disable() { _service_action disable "disabled"; }

# service_reload — re-read the regenerated config without a full downtime.
# reload-or-restart restarts if the unit does not support a live reload, which
# is correct for ss-rust. Called after lib/config.sh regenerates config.json.
service_reload() {
  _service_require_systemctl
  if systemctl reload-or-restart "$SS_SERVICE_NAME"; then
    log_info "reloaded ${SS_SERVICE_NAME}"
    return 0
  fi
  log_error "failed to reload ${SS_SERVICE_NAME}."
  log_error "inspect logs: journalctl -u ${SS_SERVICE_NAME} -n 50 --no-pager"
  return 1
}

# --- status -----------------------------------------------------------------

# _service_listening_ports — print the ports the service should be listening on,
# one per line, derived from the generated config (the authoritative source).
# Falls back silently to nothing if jq or the config is unavailable, so status
# still works on a slim host without iproute2/netstat.
_service_listening_ports() {
  [ -f "$SS_EASY_CONFIG" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  jq -r '.servers[]?.server_port' "$SS_EASY_CONFIG" 2>/dev/null || true
}

# service_status — print whether the service is active and which ports it should
# be listening on. Exit 0 only when active; non-zero otherwise (including a
# never-installed service, which systemctl reports as inactive/unknown).
service_status() {
  _service_require_systemctl
  local state
  state="$(systemctl is-active "$SS_SERVICE_NAME" 2>/dev/null || true)"

  local ports
  ports="$(_service_listening_ports)"

  if [ "$state" = "active" ]; then
    log_info "${SS_SERVICE_NAME}: active"
    if [ -n "$ports" ]; then
      log_info "listening ports (from config): $(printf '%s' "$ports" | tr '\n' ' ')"
    else
      log_info "listening ports (from config): none (no users configured)"
    fi
    return 0
  fi

  log_warn "${SS_SERVICE_NAME}: ${state:-inactive}"
  log_warn "start it with: ss-easy ... (or systemctl start ${SS_SERVICE_NAME})"
  return 1
}
