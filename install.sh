#!/usr/bin/env bash
#
# install.sh — curl|bash bootstrap for ss-easy.
#
# This is the single most security-sensitive script in the project: it runs as
# root on someone else's machine, fetched over the network. Its only job is to
# obtain the TAG-PINNED `dist/ss-easy` release bundle, VERIFY its SHA256 against
# the published `checksums/bootstrap.sha256` BEFORE executing anything, install
# the verified bundle to /usr/local/bin/ss-easy, and hand off to
# `ss-easy install "$@"` (Decision 9: bootstrap integrity).
#
# Supply-chain safety here does NOT rest on trusting TLS. TLS only protects the
# transport; the integrity guarantee is the SHA256 comparison against a value
# pinned to a released git tag. A swapped release asset, a moved branch, or a
# compromised CDN is caught by the checksum mismatch and aborts the install
# before a single byte of the downloaded bundle is executed.
#
# THE CHECKSUM IS COMMITTED ALONGSIDE THE BUNDLE AND VERIFIED IN CI.
#   `bash build.sh` is byte-reproducible: building twice yields the same
#   `dist/ss-easy` hash. The committed `checksums/bootstrap.sha256` is therefore
#   the SHA256 of the committed `dist/ss-easy`, regenerated whenever the bundle
#   changes via:
#
#       sha256sum dist/ss-easy | sed 's#dist/##' > checksums/bootstrap.sha256
#
#   so the committed line is `<hash>  ss-easy`. The CI `bundle-checksum` job
#   rebuilds the bundle and FAILS if its hash differs from this committed value,
#   preventing drift between the published bundle and its bootstrap checksum.
#   This bootstrap verifies the downloaded bundle against that committed value
#   before executing a single byte (verify-before-exec).
#
# Usage (the README one-liner). Run the script as a `sudo bash -c "$(…)"` argument
# (NOT `curl | sudo bash`): piping into sudo leaves sudo's stdin on the pipe, and
# with sudo's use_pty (Ubuntu 24.04 default) the interactive dialogs can't read
# arrow keys. As an argument the controlling terminal stays attached.
#   sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/wild99/ss-easy/v1.0.3/install.sh)"
# Non-interactive installs need no terminal, so a plain pipe is fine:
#   curl -fsSL .../install.sh | sudo bash -s -- --silent

set -euo pipefail

# --- Release pin (edit these two lines at release/bump time) ----------------
#
# REPO and TAG fully determine which artifacts are fetched. They are pinned to a
# released git tag — NEVER a moving branch — so the bytes we download and verify
# are immutable. Override via the environment only for CI/self-test against a
# local fixture host (never to relax integrity).
: "${SS_EASY_REPO:=wild99/ss-easy}"
: "${SS_EASY_TAG:=v1.0.3}"

# Base URL for the tag-pinned raw repo content (the bundle + its checksum live in
# the tagged tree). Overridable for tests; defaults to GitHub raw over HTTPS.
: "${SS_EASY_BASE_URL:=https://raw.githubusercontent.com/${SS_EASY_REPO}/${SS_EASY_TAG}}"

# Where the verified bundle is installed and which subcommand we hand off to.
: "${SS_EASY_BIN:=/usr/local/bin/ss-easy}"

# Download hardening / retry knobs (mirrors lib/binary.sh; overridable in tests).
: "${SS_DOWNLOAD_PROTO:==https}"
: "${SS_DOWNLOAD_RETRIES:=3}"
: "${SS_DOWNLOAD_BACKOFF_BASE:=2}"

# --- minimal logging (this script runs standalone, before the bundle loads) -
_boot_log()  { printf '[ss-easy bootstrap] %s\n' "$*" >&2; }
_boot_die()  { printf '[ss-easy bootstrap] error: %s\n' "$*" >&2; exit "${2:-1}"; }

# --- workspace + cleanup ----------------------------------------------------
# A single scratch dir holds the downloaded bundle and its checksum file. The
# trap removes it on ANY exit path (success, failure, signal), so a failed or
# tampered download never leaves a partial artifact behind — and crucially never
# anywhere near $SS_EASY_BIN.
WORKDIR=""
cleanup() { [ -n "$WORKDIR" ] && rm -rf "$WORKDIR"; }
trap cleanup EXIT INT TERM

# --- preconditions ----------------------------------------------------------

require_root_or_hint() {
  if [ "$(id -u)" -ne 0 ]; then
    _boot_die "must run as root. Re-run with sudo, e.g.:
    curl -fsSL ${SS_EASY_BASE_URL}/install.sh | sudo bash"
  fi
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 \
    || _boot_die "required tool not found: $1 (install it and retry)"
}

# --- hardened download ------------------------------------------------------
#
# boot_download <url> <dest> — fetch <url> into <dest> with a hardened curl and
# bounded retries with backoff. Hardening (Decision 9):
#   --fail            HTTP >=400 is a failure (no error page saved as the bundle)
#   --proto '=https'  HTTPS only; no scheme downgrade, no plaintext redirect
#   --tlsv1.2         TLS floor
#   --location        follow CDN redirects, still under the --proto guard
# NEVER -k / --insecure. On total failure the partial <dest> is removed and a
# non-zero status is returned (no partial artifacts).
boot_download() {
  local url="${1:?boot_download: url required}"
  local dest="${2:?boot_download: dest required}"
  local proto="${SS_DOWNLOAD_PROTO}"
  local retries="${SS_DOWNLOAD_RETRIES}"
  local backoff_base="${SS_DOWNLOAD_BACKOFF_BASE}"

  local attempt=1 delay
  while [ "$attempt" -le "$retries" ]; do
    if curl --fail --proto "$proto" --tlsv1.2 --location \
            --connect-timeout 15 --max-time 120 \
            -o "$dest" "$url"; then
      return 0
    fi

    # Drop any partial bytes before retrying or aborting.
    rm -f "$dest"

    if [ "$attempt" -lt "$retries" ]; then
      delay=$(( backoff_base * attempt ))
      if [ "$delay" -gt 0 ]; then
        _boot_log "download failed (attempt ${attempt}/${retries}); retrying in ${delay}s"
        sleep "$delay"
      else
        _boot_log "download failed (attempt ${attempt}/${retries}); retrying"
      fi
    fi
    attempt=$(( attempt + 1 ))
  done

  _boot_log "download failed after ${retries} attempts: ${url}"
  return 1
}

# --- main -------------------------------------------------------------------

main() {
  require_root_or_hint
  require_tool curl
  require_tool sha256sum
  require_tool install

  WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/ss-easy-boot.XXXXXX")" \
    || _boot_die "cannot create a temp working directory"

  local bundle_url="${SS_EASY_BASE_URL}/dist/ss-easy"
  local sum_url="${SS_EASY_BASE_URL}/checksums/bootstrap.sha256"
  local bundle="${WORKDIR}/ss-easy"
  local sumfile="${WORKDIR}/bootstrap.sha256"

  _boot_log "fetching tag-pinned bundle (${SS_EASY_REPO}@${SS_EASY_TAG})"
  boot_download "$bundle_url" "$bundle" \
    || _boot_die "could not download the ss-easy bundle; aborting (nothing installed)."

  _boot_log "fetching published checksum"
  boot_download "$sum_url" "$sumfile" \
    || _boot_die "could not download the published checksum; aborting (nothing installed)."

  # The published file is `<hash>  ss-easy` (filename relative to dist/). The
  # downloaded bundle is named exactly `ss-easy` in WORKDIR, so `sha256sum -c`,
  # run from WORKDIR, matches the line by filename and compares the full hash.
  # This is the VERIFY-BEFORE-EXEC gate: any mismatch aborts here.
  _boot_log "verifying bundle SHA256 against published checksum"
  if ! ( cd "$WORKDIR" && sha256sum -c --status -- "$sumfile" ); then
    local got exp
    got="$(sha256sum -- "$bundle" 2>/dev/null | awk '{print $1}')"
    exp="$(awk '{print $1; exit}' "$sumfile" 2>/dev/null)"
    _boot_log "expected: ${exp:-<none>}"
    _boot_log "got:      ${got:-<none>}"
    _boot_die "SHA256 mismatch: the downloaded bundle does not match the published checksum. \
Refusing to execute it (possible tampered asset, wrong tag, or corrupted download). Nothing installed."
  fi

  # Verified: install atomically with mode 0755, root-owned. `install` creates
  # the parent dir if needed and replaces any existing binary in one step.
  _boot_log "checksum OK; installing verified bundle to ${SS_EASY_BIN}"
  install -d -m 0755 "$(dirname "$SS_EASY_BIN")"
  install -m 0755 "$bundle" "$SS_EASY_BIN" \
    || _boot_die "failed to install the verified bundle to ${SS_EASY_BIN}"

  # Scratch dir no longer needed; the EXIT trap also covers exec's replacement.
  cleanup
  WORKDIR=""

  _boot_log "starting installer: ss-easy install $*"
  # Fetched via `curl | bash`, this bootstrap's stdin is the curl pipe, not the
  # terminal. The interactive installer then mis-handles keyboard input — arrow
  # keys leak as raw ^[[ escape codes in the whiptail dialogs instead of moving
  # the selection. Re-attach the controlling terminal as the installer's stdin
  # when one is actually available; silent / non-interactive runs (cloud-init,
  # CI, no controlling tty) fall through unchanged.
  if { : </dev/tty; } 2>/dev/null; then
    exec "$SS_EASY_BIN" install "$@" </dev/tty
  fi
  exec "$SS_EASY_BIN" install "$@"
}

main "$@"
