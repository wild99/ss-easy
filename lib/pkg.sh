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
#   pkg_ensure_runtime_deps         install the runtime deps for the host family:
#                                     deb : whiptail qrencode jq curl
#                                     rhel: newt qrencode jq  (no curl: curl-minimal
#                                           is already present and `curl` conflicts
#                                           with it; whiptail CLI ships in `newt`;
#                                           qrencode lives in EPEL, enabled first)
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
# build:strip-start
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
# build:strip-end

# Runtime dependencies, per distro family — the CLI tools the tool needs are
# whiptail, qrencode, jq and curl, but the PACKAGES that provide them differ:
#
#   deb  : whiptail qrencode jq curl   (all four exist by name in apt)
#   rhel : newt qrencode jq            (the whiptail CLI ships in `newt`, not a
#                                       `whiptail` package; curl is INTENTIONALLY
#                                       omitted — RHEL ships `curl-minimal`, which
#                                       already provides curl and conflicts with
#                                       the `curl` package; `qrencode` is in EPEL)
#
# Verified on rockylinux:9: `newt` + `qrencode` (EPEL) + `jq` install cleanly and
# `whiptail` ends up on PATH from `newt`.
SS_RUNTIME_DEPS_DEB="whiptail qrencode jq curl"
SS_RUNTIME_DEPS_RHEL="newt qrencode jq"

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

# _pkg_family — resolve the distro family (deb|rhel). Honours SS_DISTRO_FAMILY
# from preflight; when unset, infers it from the active package manager so the
# correct per-family package list is still chosen. Prints deb|rhel, or nothing.
_pkg_family() {
  case "${SS_DISTRO_FAMILY:-}" in
    deb)  printf 'deb';  return 0 ;;
    rhel) printf 'rhel'; return 0 ;;
  esac
  # Unset: infer from the manager on PATH.
  case "$(pkg_detect_manager 2>/dev/null)" in
    apt-get) printf 'deb' ;;
    dnf|yum) printf 'rhel' ;;
  esac
}

# pkg_ensure_runtime_deps — install the runtime dependencies the tool needs,
# using the PER-FAMILY package list (package names differ across deb and rhel).
# On rhel, `qrencode` lives in EPEL, so epel-release is enabled first (idempotent
# no-op if already installed). Idempotent overall: re-running on a fully
# provisioned host is a no-op success.
pkg_ensure_runtime_deps() {
  local family deps
  family="$(_pkg_family)"

  case "$family" in
    rhel)
      # qrencode is not in BaseOS/AppStream; EPEL provides it. Enable EPEL first
      # so the subsequent install can resolve it. Installing epel-release when it
      # is already present is a no-op for dnf/yum.
      log_info "enabling EPEL (provides qrencode on RHEL family)"
      pkg_install epel-release || return $?
      deps="$SS_RUNTIME_DEPS_RHEL"
      ;;
    deb)
      deps="$SS_RUNTIME_DEPS_DEB"
      ;;
    *)
      die "pkg_ensure_runtime_deps: cannot determine distro family (deb|rhel)."
      ;;
  esac

  # Word-splitting of the chosen list is intentional: a fixed, internal
  # space-separated list of package names with no special characters.
  # shellcheck disable=SC2086
  pkg_install $deps
}
