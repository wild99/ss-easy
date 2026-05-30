# shellcheck shell=bash
#
# lib/firewall.sh — thin abstraction over the two host firewalls (ufw on the
# debian family, firewalld on the rhel family) plus BBR enablement via sysctl.
#
# The module does exactly one firewall thing: open and close TCP/UDP ports that
# ss-easy allocates to Shadowsocks users. It deliberately does NOT manage the
# firewall as a whole.
#
# CRITICAL SSH-SAFETY INVARIANT (Decision 6 / tech-spec risk table):
#   * No function ever forms a command that touches the SSH rule — port 22, any
#     other SSH port, or the firewalld `ssh` service. We never lock the operator
#     out of their own box.
#   * We never enable a firewall "from scratch". If the firewall is installed but
#     inactive we warn and skip (silent mode) rather than activating it: bringing
#     a default-deny firewall up unprompted could itself sever the SSH session.
#
# PUBLIC CONTRACT (Tasks 8/9 depend on these names):
#   firewall_detect_backend          -> sets $REPLY to ufw|firewalld|"" ; rc 0/1
#   firewall_is_active <backend>     -> rc 0 if that firewall is active
#   firewall_open_port <port> [proto]  open a user port (proto: tcp|udp; default tcp)
#   firewall_close_port <port> [proto] remove a previously added user-port rule
#   firewall_enable_bbr               enable BBR where the kernel supports it
#
# Overridable for tests / packaging:
#   SYSCTL_DIR   directory for the persistent drop-in (default /etc/sysctl.d)
#
# Sourcing this file has no side effects: only definitions.

# Guard against double-sourcing in the assembled bundle / nested sources.
if [ -n "${_SS_EASY_FIREWALL_LOADED:-}" ]; then
  # shellcheck disable=SC2317  # reached only on re-source of this module.
  return 0 2>/dev/null || true
fi
_SS_EASY_FIREWALL_LOADED=1

# Depend on common.sh (die, logging). In the assembled bundle the modules are
# inlined and the guard is already set, so this is a no-op there; in dev/test the
# module sources its sibling so it is usable standalone.
# build:strip-start
if [ -z "${_SS_EASY_COMMON_LOADED:-}" ]; then
  _ss_fw_self="${BASH_SOURCE[0]}"
  _ss_fw_dir="${_ss_fw_self%/*}"
  [ "$_ss_fw_dir" = "$_ss_fw_self" ] && _ss_fw_dir="."
  # shellcheck source=lib/common.sh disable=SC1091
  . "${_ss_fw_dir}/common.sh"
  unset _ss_fw_self _ss_fw_dir
fi
# build:strip-end

# Tunable default; tests override it per-call via the environment.
: "${SYSCTL_DIR:=/etc/sysctl.d}"

# Persistent BBR drop-in filename. 99- prefix so it wins over distro defaults.
_FW_BBR_FILE="99-ss-easy-bbr.conf"

# --- input validation -------------------------------------------------------

# _fw_valid_port <port> — rc 0 only for an integer in 1..65535. No leading zero
# tricks: the case guard rejects anything non-numeric, the range check the rest.
_fw_valid_port() {
  local port="${1:-}"
  case "$port" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
}

# _fw_valid_proto <proto> — rc 0 only for tcp or udp.
_fw_valid_proto() {
  case "${1:-}" in
    tcp|udp) return 0 ;;
    *) return 1 ;;
  esac
}

# --- backend detection ------------------------------------------------------

# firewall_detect_backend — decide which firewall this host uses and return the
# label in $REPLY (ufw|firewalld), or empty $REPLY + rc 1 when neither is
# present. Presence of the real binary is authoritative; the distro family from
# preflight is only a hint (a debian box can run firewalld and vice versa), so we
# do not rely on it here. ufw is preferred when both somehow exist.
firewall_detect_backend() {
  REPLY=""
  if command -v ufw >/dev/null 2>&1; then
    REPLY="ufw"
    return 0
  fi
  if command -v firewall-cmd >/dev/null 2>&1; then
    REPLY="firewalld"
    return 0
  fi
  return 1
}

# firewall_is_active <backend> — rc 0 only if that firewall is currently active.
# An inactive firewall is a deliberate "skip" signal upstream, never a trigger to
# enable it.
firewall_is_active() {
  case "${1:-}" in
    ufw)
      # `ufw status` prints "Status: active" when enabled.
      ufw status 2>/dev/null | grep -qi 'Status: active'
      ;;
    firewalld)
      # `firewall-cmd --state` prints "running" and exits 0 when active.
      [ "$(firewall-cmd --state 2>/dev/null)" = "running" ]
      ;;
    *)
      return 1
      ;;
  esac
}

# --- open / close a user port ----------------------------------------------

# firewall_open_port <port> [proto] — open a Shadowsocks user port.
# proto defaults to tcp; pass udp for the UDP relay. Validates before any backend
# call. If no firewall is installed, or it is installed but inactive, we warn and
# return 0 (success): not having a managed firewall is not an ss-easy failure, and
# we must never enable one ourselves.
firewall_open_port() {
  local port="${1:-}" proto="${2:-tcp}"

  if ! _fw_valid_port "$port"; then
    log_error "firewall_open_port: invalid port '${port}' (expected 1-65535)."
    return 2
  fi
  if ! _fw_valid_proto "$proto"; then
    log_error "firewall_open_port: invalid protocol '${proto}' (expected tcp or udp)."
    return 2
  fi

  if ! firewall_detect_backend; then
    log_warn "no supported firewall (ufw/firewalld) found; skipping rule for ${port}/${proto}."
    log_warn "open ${port}/${proto} manually if a firewall is added later."
    return 0
  fi
  local backend="$REPLY"

  if ! firewall_is_active "$backend"; then
    log_warn "${backend} is installed but not active; not enabling it for you (SSH safety)."
    log_warn "skipping firewall rule for ${port}/${proto}; enable ${backend} yourself, then re-run."
    return 0
  fi

  _fw_apply "$backend" open "$port" "$proto"
}

# firewall_close_port <port> [proto] — remove a user-port rule previously added
# by firewall_open_port (used on `user del` and `uninstall`). Removes ONLY that
# port's rule; never resets, disables, or reconfigures the firewall.
firewall_close_port() {
  local port="${1:-}" proto="${2:-tcp}"

  if ! _fw_valid_port "$port"; then
    log_error "firewall_close_port: invalid port '${port}' (expected 1-65535)."
    return 2
  fi
  if ! _fw_valid_proto "$proto"; then
    log_error "firewall_close_port: invalid protocol '${proto}' (expected tcp or udp)."
    return 2
  fi

  if ! firewall_detect_backend; then
    log_warn "no supported firewall (ufw/firewalld) found; nothing to close for ${port}/${proto}."
    return 0
  fi
  local backend="$REPLY"

  if ! firewall_is_active "$backend"; then
    log_warn "${backend} is not active; nothing to close for ${port}/${proto}."
    return 0
  fi

  _fw_apply "$backend" close "$port" "$proto"
}

# _fw_apply <backend> <open|close> <port> <proto> — emit the concrete backend
# commands. Inputs are already validated, so every expansion is a quoted literal;
# there is no eval and no string assembly from untrusted data.
_fw_apply() {
  local backend="$1" action="$2" port="$3" proto="$4"

  case "$backend" in
    ufw)
      # ufw rules are addressed by "<port>/<proto>". delete removes the exact
      # rule; we never call enable/disable/reset.
      if [ "$action" = "open" ]; then
        ufw allow "${port}/${proto}" >/dev/null 2>&1 \
          || { log_error "ufw failed to open ${port}/${proto}."; return 1; }
        log_info "opened ${port}/${proto} (ufw)."
      else
        ufw delete allow "${port}/${proto}" >/dev/null 2>&1 \
          || { log_warn "ufw could not delete rule ${port}/${proto} (already absent?)."; return 0; }
        log_info "closed ${port}/${proto} (ufw)."
      fi
      ;;
    firewalld)
      # firewalld keeps runtime and permanent config separate. We must touch
      # BOTH: runtime so the rule is active NOW, --permanent so it survives a
      # reboot. We scope to ports only — never --add-service/--remove-service,
      # so the ssh service rule is left untouched.
      local verb
      if [ "$action" = "open" ]; then verb="--add-port"; else verb="--remove-port"; fi

      # Runtime (no --permanent): active immediately.
      firewall-cmd "${verb}=${port}/${proto}" >/dev/null 2>&1 \
        || log_warn "firewalld runtime ${verb}=${port}/${proto} failed (rule may already be in that state)."
      # Permanent: survives reboot.
      firewall-cmd --permanent "${verb}=${port}/${proto}" >/dev/null 2>&1 \
        || log_warn "firewalld permanent ${verb}=${port}/${proto} failed (rule may already be in that state)."

      if [ "$action" = "open" ]; then
        log_info "opened ${port}/${proto} (firewalld, runtime+permanent)."
      else
        log_info "closed ${port}/${proto} (firewalld, runtime+permanent)."
      fi
      ;;
    *)
      log_error "_fw_apply: unknown backend '${backend}'."
      return 1
      ;;
  esac
  return 0
}

# --- BBR --------------------------------------------------------------------
#
# BBR needs two independent kernel features:
#   * the `fq` qdisc (module sch_fq) for net.core.default_qdisc=fq
#   * the `bbr` congestion algorithm (module tcp_bbr) for
#     net.ipv4.tcp_congestion_control=bbr
# Either can be missing on its own (old kernel, stripped modules). Writing
# default_qdisc=fq without sch_fq makes `sysctl --system` fail, so each key is
# written and applied ONLY when its own capability is present. A missing
# capability is a per-component warn + skip, never a failure: BBR is an
# optimisation, not a requirement.
#
# The capability probes read /proc, not a binary, so they cannot be PATH-stubbed.
# They live in dedicated functions that the test suite overrides to simulate
# support per component independently.

# _fw_has_sch_fq — rc 0 if the kernel exposes the `fq` qdisc. `tc qdisc add ...
# fq` would need root; instead we check the module is loadable/loaded, which is
# the same signal sysctl needs.
_fw_has_sch_fq() {
  # Already loaded?
  if [ -d /sys/module/sch_fq ]; then
    return 0
  fi
  # Available to load? modinfo is read-only and needs no root.
  modinfo sch_fq >/dev/null 2>&1
}

# _fw_has_tcp_bbr — rc 0 if `bbr` is an available congestion-control algorithm.
_fw_has_tcp_bbr() {
  local avail="/proc/sys/net/ipv4/tcp_available_congestion_control"
  if [ -r "$avail" ] && grep -qw bbr "$avail" 2>/dev/null; then
    return 0
  fi
  # Not currently listed, but the module may be loadable.
  modinfo tcp_bbr >/dev/null 2>&1
}

# _fw_sysctl_put <file> <key=value> — append the assignment to the drop-in only
# if that exact key is not already present, keeping the operation idempotent.
_fw_sysctl_put() {
  local file="$1" line="$2" key="${2%%=*}"
  if [ -f "$file" ] && grep -q "^${key}=" "$file" 2>/dev/null; then
    return 0
  fi
  printf '%s\n' "$line" >> "$file"
}

# firewall_enable_bbr — write and apply the supported BBR sysctls. Always exits 0.
firewall_enable_bbr() {
  local file="${SYSCTL_DIR}/${_FW_BBR_FILE}"
  local have_fq=1 have_bbr=1
  _fw_has_sch_fq || have_fq=0
  _fw_has_tcp_bbr || have_bbr=0

  if [ "$have_fq" -eq 0 ] && [ "$have_bbr" -eq 0 ]; then
    log_warn "kernel supports neither fq qdisc nor BBR; skipping BBR (not required)."
    return 0
  fi

  mkdir -p "$SYSCTL_DIR" 2>/dev/null || true

  if [ "$have_fq" -eq 1 ]; then
    _fw_sysctl_put "$file" "net.core.default_qdisc=fq"
    sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1 \
      || log_warn "could not apply net.core.default_qdisc=fq at runtime (will take effect on reboot)."
  else
    log_warn "kernel lacks the fq qdisc (sch_fq); skipping net.core.default_qdisc=fq."
  fi

  if [ "$have_bbr" -eq 1 ]; then
    _fw_sysctl_put "$file" "net.ipv4.tcp_congestion_control=bbr"
    sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1 \
      || log_warn "could not apply tcp_congestion_control=bbr at runtime (will take effect on reboot)."
  else
    log_warn "kernel lacks the BBR algorithm (tcp_bbr); skipping tcp_congestion_control=bbr."
  fi

  log_info "BBR sysctl configuration written to ${file}."
  return 0
}
