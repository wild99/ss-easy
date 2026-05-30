# shellcheck shell=bash
#
# lib/uninstall.sh — full, clean purge of ss-easy from the host (do_uninstall).
#
# This is the inverse of install (Task 8): it stops and removes the systemd
# unit, deletes /etc/ss-easy (registry, config, per-user access files), removes
# the ssserver binary, closes ONLY the firewall rules this tool added (the user
# ports from the registry), and removes the dedicated unprivileged service user.
# When it is done, nothing ss-easy installed remains — but the box stays up and
# reachable over SSH.
#
# CRITICAL SAFETY INVARIANTS:
#   * The SSH rule is never touched. We close only the per-user ports read from
#     the registry, via firewall.sh, which is itself SSH-safe and never enables/
#     disables the firewall as a whole (Decision 6).
#   * The service user is removed ONLY when it both exists AND equals the
#     SS_SERVICE_USER constant from common.sh — i.e. it is the account this tool
#     creates. We never delete an arbitrary operator account.
#   * Every destructive step "forgives" a missing target (guards on existence),
#     so the operation is idempotent and survives a partially-removed host.
#   * No secrets ever reach the audit log (Decision 10).
#
# PUBLIC CONTRACT (consumed by the ss-easy dispatcher, Task 8):
#   do_uninstall [--silent|--yes]   orchestrate the purge; prompt only when
#                                   interactive and no skip-flag was given.
#
# Identity/paths come ONLY from common.sh constants (SS_SERVICE_USER,
# SS_SERVER_BIN, SS_EASY_ETC, SS_UNIT_FILE) — never redefined here. Service and
# firewall lifecycle is delegated to service.sh / firewall.sh; registry reads to
# config.sh. This module orchestrates; it does not duplicate their logic.
#
# Overridable for testing (default to the real system location):
#   SS_AUDIT_LOG   audit log path  (default /var/log/ss-easy.log)
#
# Sourcing this file has no side effects: only definitions.

# Guard against double-sourcing in the assembled bundle / nested sources.
if [ -n "${_SS_EASY_UNINSTALL_LOADED:-}" ]; then
  # shellcheck disable=SC2317  # reached only on re-source of this module.
  return 0 2>/dev/null || true
fi
_SS_EASY_UNINSTALL_LOADED=1

# Depend on the sibling modules (common/config/service/firewall). In the
# assembled bundle they are inlined ahead of this file and the guards are set, so
# this block is a no-op there; in dev/test the module sources its siblings so it
# works standalone.
# build:strip-start
if [ -z "${_SS_EASY_COMMON_LOADED:-}" ] \
   || [ -z "${_SS_EASY_CONFIG_LOADED:-}" ] \
   || [ -z "${_SS_EASY_SERVICE_LOADED:-}" ] \
   || [ -z "${_SS_EASY_FIREWALL_LOADED:-}" ]; then
  _ss_un_self="${BASH_SOURCE[0]}"
  _ss_un_dir="${_ss_un_self%/*}"
  [ "$_ss_un_dir" = "$_ss_un_self" ] && _ss_un_dir="."
  # shellcheck source=lib/common.sh disable=SC1091
  [ -n "${_SS_EASY_COMMON_LOADED:-}" ]   || . "${_ss_un_dir}/common.sh"
  # shellcheck source=lib/config.sh disable=SC1091
  [ -n "${_SS_EASY_CONFIG_LOADED:-}" ]   || . "${_ss_un_dir}/config.sh"
  # shellcheck source=lib/service.sh disable=SC1091
  [ -n "${_SS_EASY_SERVICE_LOADED:-}" ]  || . "${_ss_un_dir}/service.sh"
  # shellcheck source=lib/firewall.sh disable=SC1091
  [ -n "${_SS_EASY_FIREWALL_LOADED:-}" ] || . "${_ss_un_dir}/firewall.sh"
  unset _ss_un_self _ss_un_dir
fi
# build:strip-end

# Audit log location (Decision 10). Overridable so tests redirect it to a temp
# tree; defaults to the host log. Only non-secret action records are appended.
: "${SS_AUDIT_LOG:=/var/log/ss-easy.log}"

# --- audit ------------------------------------------------------------------

# _uninstall_audit <action> — append "<iso-timestamp> <action>" to the audit log
# (created 0600), without any secret. Best-effort: a log that cannot be written
# must never abort the purge, so failures are swallowed with a warning.
_uninstall_audit() {
  local action="$1" ts dir
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf 'unknown-time')"
  dir="$(dirname "$SS_AUDIT_LOG")"
  mkdir -p "$dir" 2>/dev/null || true
  if printf '%s %s\n' "$ts" "$action" >> "$SS_AUDIT_LOG" 2>/dev/null; then
    chmod 600 "$SS_AUDIT_LOG" 2>/dev/null || true
  else
    log_warn "could not write audit log: ${SS_AUDIT_LOG} (continuing)."
  fi
}

# --- confirmation -----------------------------------------------------------

# _uninstall_confirm — show what will be removed and ask for an explicit yes.
# rc 0 only when the operator types y/yes (case-insensitive); any other answer
# (including empty) is a decline. Reads one line from stdin so tests can pipe an
# answer in. The silent branch in do_uninstall never calls this.
_uninstall_confirm() {
  log_warn "This will completely remove ss-easy from this host:"
  log_warn "  - stop, disable and delete the systemd unit (${SS_SERVICE_NAME})"
  log_warn "  - delete ${SS_EASY_ETC} (registry, config, per-user access files)"
  log_warn "  - delete the binary ${SS_SERVER_BIN}"
  log_warn "  - close the user ports this tool opened (SSH is left untouched)"
  log_warn "  - remove the dedicated service user '${SS_SERVICE_USER}' (if tool-created)"
  printf 'Proceed with full uninstall? [y/N] ' >&2

  local answer=""
  IFS= read -r answer || answer=""
  case "$answer" in
    y|Y|yes|YES|Yes) return 0 ;;
    *) return 1 ;;
  esac
}

# --- individual purge steps -------------------------------------------------

# _uninstall_close_ports — close every user port from the registry via
# firewall.sh. A missing/invalid registry is not an error: we simply skip the
# firewall step (nothing was opened that we can read). Never touches SSH and
# never enables/disables the firewall — firewall_close_port enforces that.
_uninstall_close_ports() {
  if [ ! -f "$SS_EASY_USERS" ]; then
    log_info "no registry at ${SS_EASY_USERS}; skipping firewall cleanup."
    return 0
  fi

  local ports port
  # config_used_ports dies on a corrupt registry; guard so a bad file cannot
  # abort the whole purge. An empty/absent list simply closes nothing.
  ports="$(config_used_ports 2>/dev/null)" || {
    log_warn "could not read ports from ${SS_EASY_USERS}; skipping firewall cleanup."
    return 0
  }

  [ -n "$ports" ] || return 0
  while IFS= read -r port; do
    [ -n "$port" ] || continue
    # ss-easy serves tcp_and_udp; close both protocols for the user port.
    firewall_close_port "$port" tcp || true
    firewall_close_port "$port" udp || true
  done <<< "$ports"
}

# _uninstall_service — stop, disable and remove the unit, then daemon-reload.
# Stop/disable on an absent or already-inactive unit is not an error here, so the
# wrapper return codes are deliberately ignored; service_remove_unit handles the
# unit file + daemon-reload (and tolerates a missing file). If systemctl itself
# is unavailable the whole step is skipped — a host without systemd has no unit.
_uninstall_service() {
  if ! command -v systemctl >/dev/null 2>&1; then
    log_warn "systemctl not found; skipping service teardown."
    return 0
  fi
  service_stop    || true
  service_disable || true
  service_remove_unit || true
}

# _uninstall_files — delete the config tree and the server binary. Both are
# guarded on existence so a partial state is fine.
_uninstall_files() {
  if [ -e "$SS_EASY_ETC" ]; then
    if rm -rf -- "$SS_EASY_ETC"; then
      log_info "removed ${SS_EASY_ETC}"
    else
      log_warn "could not fully remove ${SS_EASY_ETC}."
    fi
  fi
  if [ -e "$SS_SERVER_BIN" ]; then
    if rm -f -- "$SS_SERVER_BIN"; then
      log_info "removed ${SS_SERVER_BIN}"
    else
      log_warn "could not remove ${SS_SERVER_BIN}."
    fi
  fi
}

# _uninstall_user — remove the dedicated service user ONLY when it exists AND its
# name equals the SS_SERVICE_USER constant (the account this tool creates). An
# empty constant, a missing user, or an unavailable userdel are all clean no-ops.
_uninstall_user() {
  local user="${SS_SERVICE_USER:-}"
  if [ -z "$user" ]; then
    return 0
  fi
  if ! command -v userdel >/dev/null 2>&1; then
    log_warn "userdel not found; leaving system user '${user}' in place."
    return 0
  fi
  if ! getent passwd "$user" >/dev/null 2>&1; then
    log_info "system user '${user}' is absent; nothing to remove."
    return 0
  fi
  # --remove? No: the account is created --no-create-home, so there is no home to
  # purge; userdel removes the passwd/group entry. Tolerate failure (e.g. a
  # lingering process) without aborting the rest of the purge.
  if userdel "$user" >/dev/null 2>&1; then
    log_info "removed system user '${user}'."
  else
    log_warn "could not remove system user '${user}' (in use?); remove it manually."
  fi
}

# --- public entrypoint ------------------------------------------------------

# do_uninstall [--silent|--yes] — orchestrate the full purge. In interactive mode
# (no flag) it prints a warning and requires an explicit yes; declining is a
# clean no-op (exit 0). With --silent / --yes it proceeds without prompting.
# Order: confirm -> close user ports -> stop/disable/remove service -> delete
# config dir + binary -> remove service user -> audit -> summary.
do_uninstall() {
  local assume_yes=0
  local arg
  for arg in "$@"; do
    case "$arg" in
      --silent|--yes|-y) assume_yes=1 ;;
      *) log_warn "do_uninstall: ignoring unknown argument '${arg}'." ;;
    esac
  done

  if [ "$assume_yes" -ne 1 ]; then
    if ! _uninstall_confirm; then
      log_info "uninstall aborted; nothing was removed."
      return 0
    fi
  fi

  _uninstall_close_ports
  _uninstall_service
  _uninstall_files
  _uninstall_user
  _uninstall_audit "uninstall"

  log_info "ss-easy fully removed. SSH and the rest of the host are untouched."
  return 0
}
