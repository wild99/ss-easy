# shellcheck shell=bash
#
# lib/preflight.sh — environment checks run before install.
#
# Each check is a standalone function that returns 0 on success or a non-zero
# code on failure, after emitting an actionable message (what is wrong + how to
# fix it) through the common.sh logging helpers. These are the first barrier of
# the install flow: downstream code (binary download, systemd unit, firewall)
# breaks obscurely without root, without systemd, or on an unknown distro — so
# we fail early and clearly instead.
#
# PUBLIC CONTRACT (Tasks 3, 7, 8 depend on these names):
#   pf_require_root                 die-style guard for euid 0 (delegates to common)
#   pf_detect_distro                parse /etc/os-release; export SS_DISTRO_ID /
#                                   SS_DISTRO_FAMILY (deb|rhel); non-zero if unsupported
#   pf_require_systemd              non-zero unless systemd is the active init
#   pf_check_network                non-zero unless an outbound HTTPS probe succeeds
#   pf_port_free <port>             non-zero if a socket is already LISTENing on <port>
#   run_preflight <port>            run all of the above in sequence
#
# Overridable paths/values keep the module testable without root:
#   OS_RELEASE       path to the os-release file        (default /etc/os-release)
#   SYSTEMD_MARKER   dir that exists only under systemd  (default /run/systemd/system)
#   PF_NET_PROBE_URL host probed for the network check   (default a Cloudflare URL)
#
# Sourcing this file has no side effects: only definitions.

# Guard against double-sourcing in the assembled bundle / nested sources.
if [ -n "${_SS_EASY_PREFLIGHT_LOADED:-}" ]; then
  # shellcheck disable=SC2317  # reached only on re-source of this module.
  return 0 2>/dev/null || true
fi
_SS_EASY_PREFLIGHT_LOADED=1

# Depend on common.sh (die, logging, require_root). In the assembled bundle the
# modules are inlined and the guard is already set, so this is a no-op there;
# in dev/test the module sources its sibling so it is usable standalone.
if [ -z "${_SS_EASY_COMMON_LOADED:-}" ]; then
  # Resolve our own directory with pure-bash parameter expansion (no external
  # dirname), so the module sources cleanly even under a restricted test PATH.
  _ss_pf_self="${BASH_SOURCE[0]}"
  _ss_pf_dir="${_ss_pf_self%/*}"
  [ "$_ss_pf_dir" = "$_ss_pf_self" ] && _ss_pf_dir="."
  # shellcheck source=lib/common.sh disable=SC1091
  . "${_ss_pf_dir}/common.sh"
  unset _ss_pf_self _ss_pf_dir
fi

# Tunable defaults; tests override them per-call via the environment.
: "${OS_RELEASE:=/etc/os-release}"
: "${SYSTEMD_MARKER:=/run/systemd/system}"
: "${PF_NET_PROBE_URL:=https://www.cloudflare.com/cdn-cgi/trace}"

# --- root -------------------------------------------------------------------

# pf_require_root — abort unless effective uid is 0. Reuses common.sh's
# require_root so the wording stays in one place.
pf_require_root() {
  require_root
}

# --- distro detection -------------------------------------------------------

# _pf_osr_value <key> — print the value of <key> from $OS_RELEASE without
# sourcing the file (an os-release line may contain command substitutions; we
# never execute it). Strips surrounding single/double quotes from the value.
_pf_osr_value() {
  local key="$1" line val
  line="$(grep -E "^${key}=" "$OS_RELEASE" 2>/dev/null | tail -n 1)" || return 1
  [ -n "$line" ] || return 1
  val="${line#*=}"
  # Strip one layer of matching quotes.
  val="${val%\"}"; val="${val#\"}"
  val="${val%\'}"; val="${val#\'}"
  printf '%s' "$val"
}

# _pf_lc <str> — lowercase helper (POSIX tr; avoids bashisms in shared style).
_pf_lc() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

# pf_detect_distro — classify the host into a package family and export the
# result. Primary signal is ID; ID_LIKE is a fallback for derivatives. On an
# unsupported or missing os-release, emit an actionable error and return 1.
pf_detect_distro() {
  if [ ! -r "$OS_RELEASE" ]; then
    log_error "cannot read os-release file (${OS_RELEASE}): unable to identify the distribution."
    log_error "supported distributions: debian, ubuntu, centos, rocky, almalinux."
    return 1
  fi

  local id id_like
  id="$(_pf_lc "$(_pf_osr_value ID || true)")"
  id_like="$(_pf_lc "$(_pf_osr_value ID_LIKE || true)")"

  local family=""
  case "$id" in
    debian|ubuntu) family="deb" ;;
    centos|rocky|almalinux|alma|rhel|fedora) family="rhel" ;;
    *)
      # Fall back to ID_LIKE for derivatives (e.g. raspbian, ol).
      case " $id_like " in
        *" debian "*|*" ubuntu "*) family="deb" ;;
        *" rhel "*|*" fedora "*|*" centos "*) family="rhel" ;;
      esac
      ;;
  esac

  if [ -z "$family" ]; then
    log_error "unsupported distribution: ID='${id:-?}' ID_LIKE='${id_like:-}'."
    log_error "supported distributions: debian, ubuntu, centos, rocky, almalinux."
    return 1
  fi

  export SS_DISTRO_ID="$id"
  export SS_DISTRO_FAMILY="$family"
  return 0
}

# --- systemd ----------------------------------------------------------------

# pf_require_systemd — confirm systemd is both installed (systemctl in PATH) and
# the active init (the marker dir exists). Containers without an init manager
# fail here with a clear message rather than silently "succeeding".
pf_require_systemd() {
  if ! command -v systemctl >/dev/null 2>&1; then
    log_error "systemctl not found: this tool manages a systemd service and requires systemd."
    log_error "run ss-easy on a systemd-based host (a normal VPS), not a minimal container."
    return 1
  fi
  if [ ! -d "$SYSTEMD_MARKER" ]; then
    log_error "systemd is not the active init system (${SYSTEMD_MARKER} is absent)."
    log_error "run ss-easy on a systemd-based host (a normal VPS), not a minimal container."
    return 1
  fi
  return 0
}

# --- network ----------------------------------------------------------------

# pf_check_network — verify outbound connectivity with a short, silent HTTPS
# probe. A failure means we cannot fetch the ss-rust binary or packages later.
pf_check_network() {
  if curl -fsS --max-time 10 -o /dev/null "$PF_NET_PROBE_URL" 2>/dev/null; then
    return 0
  fi
  log_error "no outbound internet connectivity (failed to reach ${PF_NET_PROBE_URL})."
  log_error "ss-easy needs internet access to download the server binary and packages."
  return 1
}

# --- port -------------------------------------------------------------------

# pf_port_free <port> — succeed only if nothing is LISTENing on <port>. Uses ss
# (iproute2), never netstat: net-tools is absent on debian-slim and minimal
# rocky. Matching is anchored on ":<port> " to avoid 18388 matching 8388.
pf_port_free() {
  local port="${1:-}"
  case "$port" in
    ''|*[!0-9]*)
      log_error "pf_port_free: invalid port '${port}' (expected a number)."
      return 2
      ;;
  esac

  if ! command -v ss >/dev/null 2>&1; then
    log_error "ss (iproute2) not found: cannot verify whether port ${port} is free."
    log_error "install the 'iproute2' package and retry."
    return 1
  fi

  # -H no header, -t TCP, -u UDP, -l listening, -n numeric. A listener prints a
  # local address ending in ":<port>"; anchor the match so 8388 != 18388.
  if ss -Htuln 2>/dev/null | grep -Eq "[:.]${port}[[:space:]]"; then
    log_error "port ${port} is already in use by another listening process."
    log_error "free it (stop the other service) or choose a different port."
    return 1
  fi
  return 0
}

# --- aggregator -------------------------------------------------------------

# run_preflight <port> — run every check in order; the first failure stops the
# sequence and propagates its non-zero code.
run_preflight() {
  local port="${1:-}"
  pf_require_root || return $?
  pf_detect_distro || return $?
  pf_require_systemd || return $?
  pf_check_network || return $?
  if [ -n "$port" ]; then
    pf_port_free "$port" || return $?
  fi
  return 0
}
