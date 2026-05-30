# shellcheck shell=bash
#
# lib/pkg.sh — package-manager abstraction over apt (debian/ubuntu) and
# dnf/yum (centos/rocky/almalinux). Hides the distro-family split from the rest
# of the code (Decision 6) and installs runtime dependencies uniformly.
#
# PUBLIC CONTRACT (Task 8 install flow depends on these):
#   pkg_detect_manager              print the active manager (apt-get|dnf|yum);
#                                   die if none is available
#   pkg_install <pkgs...>           install the given packages non-interactively
#                                   and idempotently; no packages == no-op success
#   pkg_ensure_runtime_deps         install exactly: whiptail qrencode curl jq
#
# Manager selection prefers the family detected by preflight (SS_DISTRO_FAMILY);
# when that is unset it falls back to whichever manager binary is on PATH.
#
# Sourcing this file has no side effects: only definitions.

# Guard against double-sourcing in the assembled bundle / nested sources.
if [ -n "${_SS_EASY_PKG_LOADED:-}" ]; then
  # shellcheck disable=SC2317  # reached only on re-source of this module.
  return 0 2>/dev/null || true
fi
_SS_EASY_PKG_LOADED=1

# Depend on common.sh (die, logging). In the assembled bundle the modules are
# inlined and the guard is already set, so this is a no-op there; in dev/test
# the module sources its sibling so it is usable standalone.
if [ -z "${_SS_EASY_COMMON_LOADED:-}" ]; then
  # Resolve our own directory with pure-bash parameter expansion (no external
  # dirname), so the module sources cleanly even under a restricted test PATH.
  _ss_pkg_self="${BASH_SOURCE[0]}"
  _ss_pkg_dir="${_ss_pkg_self%/*}"
  [ "$_ss_pkg_dir" = "$_ss_pkg_self" ] && _ss_pkg_dir="."
  # shellcheck source=lib/common.sh disable=SC1091
  . "${_ss_pkg_dir}/common.sh"
  unset _ss_pkg_self _ss_pkg_dir
fi

# Runtime dependencies (tech-spec Dependencies + Decision 7: jq). Same package
# names on apt and dnf/yum, so no per-family name mapping is needed today.
SS_RUNTIME_DEPS="whiptail qrencode curl jq"

# --- detect -----------------------------------------------------------------

# pkg_detect_manager — print the package manager to use. Honours the family
# from preflight first, then probes PATH. Unknown manager -> die.
pkg_detect_manager() {
  case "${SS_DISTRO_FAMILY:-}" in
    deb)
      if command -v apt-get >/dev/null 2>&1; then printf 'apt-get'; return 0; fi
      ;;
    rhel)
      if command -v dnf >/dev/null 2>&1; then printf 'dnf'; return 0; fi
      if command -v yum >/dev/null 2>&1; then printf 'yum'; return 0; fi
      ;;
  esac

  # Family unset or its preferred binary missing: fall back to PATH probing.
  if command -v apt-get >/dev/null 2>&1; then printf 'apt-get'; return 0; fi
  if command -v dnf >/dev/null 2>&1; then printf 'dnf'; return 0; fi
  if command -v yum >/dev/null 2>&1; then printf 'yum'; return 0; fi

  die "no supported package manager found (need apt-get, dnf or yum)."
}

# --- install ----------------------------------------------------------------

# pkg_install <pkgs...> — install the given packages non-interactively. apt runs
# a single 'apt-get update' first; dnf/yum need no separate refresh. Installing
# already-present packages is a no-op for both managers, so this is idempotent.
pkg_install() {
  # No packages requested: nothing to do.
  [ "$#" -gt 0 ] || return 0

  local mgr
  mgr="$(pkg_detect_manager)" || return $?

  case "$mgr" in
    apt-get)
      log_info "updating package index (apt-get update)"
      DEBIAN_FRONTEND=noninteractive apt-get update || return $?
      log_info "installing packages: $*"
      DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" || return $?
      ;;
    dnf|yum)
      log_info "installing packages: $*"
      "$mgr" install -y "$@" || return $?
      ;;
    *)
      die "pkg_install: unsupported package manager '${mgr}'."
      ;;
  esac
  return 0
}

# --- ensure runtime deps ----------------------------------------------------

# pkg_ensure_runtime_deps — install exactly the runtime dependencies the tool
# needs. Idempotent: re-running on a fully provisioned host is a no-op success.
pkg_ensure_runtime_deps() {
  # Word-splitting of SS_RUNTIME_DEPS is intentional: it is a fixed, internal
  # space-separated list of package names with no special characters.
  # shellcheck disable=SC2086
  pkg_install $SS_RUNTIME_DEPS
}
