# shellcheck shell=bash
#
# lib/common.sh — shared constants and primitives for ss-easy.
#
# PUBLIC CONTRACT (stable; Tasks 2-11 depend on these names and behaviour):
#
#   Constants:
#     SS_EASY_ETC            base config dir            (/etc/ss-easy)
#     SS_EASY_USERS          user registry path         (users.json)   — source of truth
#     SS_EASY_CONFIG         generated ss-rust config   (config.json)
#     SS_EASY_USERS_DIR      per-user access files dir  (users/)
#     SS_EASY_CHECKSUMS_DIR  repo SHA256 table dir      (checksums/)
#     SS_SERVICE_NAME        systemd unit name          (ss-easy.service)
#     SS_SERVICE_USER        dedicated unprivileged service user  — single source of truth
#     SS_SERVER_BIN          absolute path to ssserver  — single source of truth
#     SS_RUST_VERSION        pinned shadowsocks-rust release tag
#     DEFAULT_METHOD         default cipher             (2022-blake3-aes-256-gcm)
#
#   Functions:
#     log_info / log_warn / log_error <msg...>   stderr logging; colours auto-off when not a tty
#     die <msg> [code]                           log error and exit (default code 1)
#     require_root                               die unless effective uid is 0
#     atomic_write <target>                      write stdin to <target> via a 0600 temp + mv
#
# This module MUST have no side effects on source: only definitions, no global
# shell options, no I/O. The entrypoint / bundle owns `set -euo pipefail`.
#
# Constants are `export`ed: they are the shared contract consumed by the other
# modules (and the test suite), not by this file — exporting documents that and
# keeps them available to any child process the modules spawn.

# Guard against double-sourcing in the assembled bundle / nested sources.
if [ -n "${_SS_EASY_COMMON_LOADED:-}" ]; then
  # shellcheck disable=SC2317  # reached only on re-source of this module.
  return 0 2>/dev/null || true
fi
_SS_EASY_COMMON_LOADED=1

# --- Paths & constants ------------------------------------------------------

export SS_EASY_ETC="/etc/ss-easy"
export SS_EASY_USERS="${SS_EASY_ETC}/users.json"
export SS_EASY_CONFIG="${SS_EASY_ETC}/config.json"
export SS_EASY_USERS_DIR="${SS_EASY_ETC}/users"

# Repo directory holding the human/CI-readable SHA256 table for the pinned
# ss-rust binary (checksums/ss-rust.sha256). This is the SOURCE OF TRUTH; the
# installed single-file bundle does NOT read it (it verifies against the hashes
# embedded in binary.sh, which build.sh keeps in sync from this file). Relative
# path: meaningful only from the repo root in dev/CI, never at install time.
export SS_EASY_CHECKSUMS_DIR="checksums"

# Single systemd unit running ssserver against the generated config.
export SS_SERVICE_NAME="ss-easy.service"

# Dedicated unprivileged system user the service runs as (Decision 11).
# Owned here; read by Task 6/8 (create) and Task 9 (remove). Do not duplicate.
export SS_SERVICE_USER="ss-easy"

# Absolute path to the shadowsocks-rust server binary (Decision 3/11).
# Owned here; read by Task 3 (install target) and Task 6 (ExecStart).
export SS_SERVER_BIN="/usr/local/bin/ssserver"

# Pinned shadowsocks-rust release (by tag, never a moving branch — Decision 3).
# Bumping this is a reviewed PR that also refreshes checksums/ss-rust.sha256.
export SS_RUST_VERSION="v1.23.5"

# Default cipher: AEAD-2022, linked per SIP022 (Decision 4).
export DEFAULT_METHOD="2022-blake3-aes-256-gcm"

# --- Logging ----------------------------------------------------------------

# Colour codes are resolved per-call against the current stderr, so a library
# sourced at load time (no tty) still colourises an interactive later call.
# Secrets must never be passed to these functions (Decision 10).

_ss_color() {
  # _ss_color <code-var-name> — echo the ANSI sequence only when stderr is a tty.
  if [ -t 2 ]; then
    printf '%s' "$1"
  else
    printf ''
  fi
}

log_info() {
  printf '%s[*]%s %s\n' "$(_ss_color $'\033[0;34m')" "$(_ss_color $'\033[0m')" "$*" >&2
}

log_warn() {
  printf '%s[!]%s %s\n' "$(_ss_color $'\033[0;33m')" "$(_ss_color $'\033[0m')" "$*" >&2
}

log_error() {
  printf '%s[x]%s %s\n' "$(_ss_color $'\033[0;31m')" "$(_ss_color $'\033[0m')" "$*" >&2
}

# --- Error handling ---------------------------------------------------------

# die <msg> [code] — report an error on stderr and exit with [code] (default 1).
die() {
  local msg="${1:-unspecified error}"
  local code="${2:-1}"
  log_error "$msg"
  exit "$code"
}

# require_root — abort unless running with effective uid 0.
require_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    die "this command must be run as root (try: sudo ss-easy ...)"
  fi
}

# --- Atomic write -----------------------------------------------------------

# atomic_write <target> — read stdin and write it to <target> atomically.
# The temp file is created with 0600 from the start (no world-readable window),
# and is removed if anything fails before the final mv (Decision 10).
atomic_write() {
  local target="${1:?atomic_write: target path required}"
  local dir tmp
  dir="$(dirname "$target")"

  # Create the temp alongside the target so the final mv is a same-filesystem
  # rename (atomic). mktemp respects TMPDIR; honour the target dir instead.
  tmp="$(mktemp "${dir}/.ss-easy.XXXXXX")" || return 1
  chmod 600 "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }

  # shellcheck disable=SC2064  # expand tmp now: the path is fixed for this call.
  trap "rm -f '$tmp'" RETURN

  if ! cat > "$tmp"; then
    return 1
  fi

  if ! mv -f "$tmp" "$target"; then
    return 1
  fi

  # Successful move consumed the temp; nothing left for the trap to clean.
  trap - RETURN
  return 0
}
