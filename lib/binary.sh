# shellcheck shell=bash
#
# lib/binary.sh — supplies the proxy engine: the statically linked (musl)
# `ssserver` binary from the official shadowsocks/shadowsocks-rust releases.
#
# This is one of the two most security-sensitive modules of the feature (with
# bootstrap): it fetches executable code that is then run on an internet-facing
# server. Supply-chain safety here does NOT rest on trusting TLS — it rests on
# verifying the download's SHA256 against values committed to this repo
# (checksums/ss-rust.sha256), per Rust target triple (Decision 3).
#
# PUBLIC CONTRACT (Task 6/8 install flow depends on these):
#   ss_detect_arch        print the Rust target triple for the host CPU
#                         (x86_64 -> x86_64-unknown-linux-musl,
#                          aarch64 -> aarch64-unknown-linux-musl); die on others.
#   ss_install_binary     download + verify SHA256 + install ssserver to
#                         SS_SERVER_BIN (0755). Any failure -> non-zero, no
#                         partial artifacts left behind.
#
# Internal (overridable via env for testing only):
#   SS_RELEASE_BASE_URL   release-asset base URL (default: upstream releases).
#   SS_DOWNLOAD_PROTO     curl --proto value      (default: '=https').
#   SS_DOWNLOAD_RETRIES   max download attempts   (default: 3).
#   SS_DOWNLOAD_BACKOFF_BASE  backoff seconds base (default: 2; 0 disables sleep).
#   ss_download_url <url> <dest>   hardened curl with retries -> dest.
#
# Sourcing this file has no side effects: only definitions.

# Guard against double-sourcing in the assembled bundle / nested sources.
if [ -n "${_SS_EASY_BINARY_LOADED:-}" ]; then
  # shellcheck disable=SC2317  # reached only on re-source of this module.
  return 0 2>/dev/null || true
fi
_SS_EASY_BINARY_LOADED=1

# Depend on common.sh (die, logging, SS_RUST_VERSION, SS_SERVER_BIN). In the
# assembled bundle the modules are inlined and the guard is already set, so this
# is a no-op; in dev/test we source our sibling so the module is usable
# standalone.
# build:strip-start
if [ -z "${_SS_EASY_COMMON_LOADED:-}" ]; then
  _ss_bin_self="${BASH_SOURCE[0]}"
  _ss_bin_dir="${_ss_bin_self%/*}"
  [ "$_ss_bin_dir" = "$_ss_bin_self" ] && _ss_bin_dir="."
  # shellcheck source=lib/common.sh disable=SC1091
  . "${_ss_bin_dir}/common.sh"
  unset _ss_bin_self _ss_bin_dir
fi
# build:strip-end

# --- embedded checksum table ------------------------------------------------
#
# Expected SHA256 of each pinned ss-rust release asset, keyed by Rust target
# triple. These are EMBEDDED so the single-file bundle verifies the download
# with NO sibling files (the installed /usr/local/bin/ss-easy has no checksums/
# dir). The repo file checksums/ss-rust.sha256 stays the human/CI-readable
# source of truth; build.sh keeps the values below in sync from it on each build
# (see _ss_sync_embedded_checksums in build.sh). Bumping SS_RUST_VERSION updates
# checksums/ss-rust.sha256, then `bash
# build.sh` refreshes these constants.
#
# EMBEDDED-CHECKSUMS:BEGIN (managed by build.sh — do not edit by hand)
_SS_RUST_SHA256_x86_64_unknown_linux_musl="d37e9f6484aced51188ed6c8beea3538be7a73b072259b65a47e91ebf6530dfc"
_SS_RUST_SHA256_aarch64_unknown_linux_musl="42ec15a594dd61b5eae9feb6d7819405e7bd261b8c4cceeda0b6bc7f8b05395f"
# EMBEDDED-CHECKSUMS:END

# ss_expected_sha256 <triple> — print the embedded expected SHA256 for <triple>.
# Returns non-zero (no output) if there is no embedded entry for that triple.
ss_expected_sha256() {
  local triple="${1:?ss_expected_sha256: triple required}"
  # Map the triple to its constant name: dashes/dots are not valid in bash
  # identifiers, so the constants use underscores. Indirect-expand the result.
  local key="_SS_RUST_SHA256_${triple//[-.]/_}"
  local val="${!key:-}"
  [ -n "$val" ] || return 1
  printf '%s' "$val"
}

# Upstream release-asset base URL for the pinned tag. Overridable in tests to
# point at a local fixture host; never used to relax the curl protocol guard.
: "${SS_RELEASE_BASE_URL:=https://github.com/shadowsocks/shadowsocks-rust/releases/download/${SS_RUST_VERSION}}"

# --- arch detect ------------------------------------------------------------

# ss_detect_arch — map `uname -m` DIRECTLY to the Rust target triple. This one
# value drives BOTH the asset URL and the checksum lookup; there is no
# intermediate amd64/arm64 in the logic. Unknown arch -> die (do not attempt to
# download a non-existent asset).
ss_detect_arch() {
  local machine
  machine="$(uname -m)"
  case "$machine" in
    x86_64)  printf 'x86_64-unknown-linux-musl' ;;
    aarch64) printf 'aarch64-unknown-linux-musl' ;;
    *)
      die "unsupported CPU architecture '${machine}': ss-easy ships ss-rust only for x86_64 and aarch64."
      ;;
  esac
}

# --- hardened download ------------------------------------------------------

# ss_download_url <url> <dest> — fetch <url> into <dest> with a hardened curl
# and bounded retries. On total failure the partial <dest> is removed and a
# non-zero status is returned (no partial artifacts).
#
# Hardening (Decision 3): --fail (HTTP errors are failures), --proto '=https'
# (no scheme downgrade / no plaintext redirect), --tlsv1.2 (floor), --location
# (follow CDN redirects, still under the proto guard). NEVER -k/--insecure.
ss_download_url() {
  local url="${1:?ss_download_url: url required}"
  local dest="${2:?ss_download_url: dest required}"
  local proto="${SS_DOWNLOAD_PROTO:-=https}"
  local retries="${SS_DOWNLOAD_RETRIES:-3}"
  local backoff_base="${SS_DOWNLOAD_BACKOFF_BASE:-2}"

  local attempt=1 delay
  while [ "$attempt" -le "$retries" ]; do
    if curl --fail --proto "$proto" --tlsv1.2 --location \
            --connect-timeout 15 --max-time 120 \
            -o "$dest" "$url"; then
      return 0
    fi

    # This attempt failed: drop any partial bytes before retrying or aborting.
    rm -f "$dest"

    if [ "$attempt" -lt "$retries" ]; then
      # Increasing backoff: 1st retry waits base, 2nd 2*base, ... (base=0: none).
      delay=$(( backoff_base * attempt ))
      if [ "$delay" -gt 0 ]; then
        log_warn "download failed (attempt ${attempt}/${retries}); retrying in ${delay}s"
        sleep "$delay"
      else
        log_warn "download failed (attempt ${attempt}/${retries}); retrying"
      fi
    fi
    attempt=$(( attempt + 1 ))
  done

  log_error "download failed after ${retries} attempts: ${url}"
  return 1
}

# --- install ----------------------------------------------------------------

# ss_install_binary — full supply flow: detect arch, download the pinned asset,
# verify SHA256 against the repo-committed table, extract and install ssserver
# to SS_SERVER_BIN (0755). Idempotent (overwrites an existing binary). Any
# failure removes all temp artifacts and returns non-zero (no partial install).
ss_install_binary() {
  local triple asset url expected tmpdir archive extract_root
  triple="$(ss_detect_arch)" || return $?
  asset="shadowsocks-${SS_RUST_VERSION}.${triple}.tar.xz"
  url="${SS_RELEASE_BASE_URL}/${asset}"

  # Resolve the expected hash from the EMBEDDED table so a single-file install
  # (no sibling checksums/ dir) verifies. No embedded entry -> refuse to install.
  expected="$(ss_expected_sha256 "$triple")" || \
    die "no embedded SHA256 for ${triple}: cannot verify ss-rust ${SS_RUST_VERSION}."

  # Single scratch dir for the archive and extraction; one trap cleans it all,
  # so every error path (download, verify, extract) leaves nothing behind.
  tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/ss-easy-binary.XXXXXX")" || return 1
  # shellcheck disable=SC2064  # expand tmpdir now: fixed for this call.
  trap "rm -rf '$tmpdir'" RETURN

  # The downloaded file MUST be named exactly like the asset so that
  # `sha256sum -c`, run from tmpdir, matches the committed `<hash>  <asset>`
  # line by filename.
  archive="${tmpdir}/${asset}"

  log_info "downloading ${asset} (${SS_RUST_VERSION})"
  if ! ss_download_url "$url" "$archive"; then
    die "failed to download ss-rust ${SS_RUST_VERSION} for ${triple}"
  fi

  # Verify against the EMBEDDED hash. Feed `<hash>  <asset>` to `sha256sum -c`
  # from tmpdir so it checks exactly our archive by name (full-hash compare, no
  # substrings, no external file needed).
  log_info "verifying SHA256 of ${asset}"
  if ! ( cd "$tmpdir" && printf '%s  %s\n' "$expected" "$asset" | sha256sum -c --status - ); then
    die "SHA256 mismatch for ${asset}: refusing to install (possible tampered or wrong asset)"
  fi

  # Extract into a subdir of the same scratch tree.
  extract_root="${tmpdir}/extract"
  mkdir -p "$extract_root"
  log_info "extracting ${asset}"
  if ! tar -C "$extract_root" -xJf "$archive"; then
    die "failed to extract ${asset} (corrupt or truncated archive)"
  fi

  # Locate the ssserver binary inside the extracted tree (release layout puts it
  # at the archive root, but find tolerates layout changes).
  local src
  src="$(find "$extract_root" -type f -name ssserver -print -quit)"
  if [ -z "$src" ] || [ ! -f "$src" ]; then
    die "ssserver not found inside ${asset}"
  fi

  # Install: copy to a temp next to the target then atomic-rename into place, so
  # a concurrent reader never sees a half-written binary (idempotent overwrite).
  local dest_dir dest_tmp
  dest_dir="$(dirname "$SS_SERVER_BIN")"
  if ! mkdir -p "$dest_dir"; then
    die "cannot create install directory: ${dest_dir}"
  fi
  dest_tmp="$(mktemp "${dest_dir}/.ssserver.XXXXXX")" || die "cannot create temp in ${dest_dir}"
  if ! cp "$src" "$dest_tmp"; then
    rm -f "$dest_tmp"
    die "failed to stage ssserver into ${dest_dir}"
  fi
  chmod 0755 "$dest_tmp"
  if ! mv -f "$dest_tmp" "$SS_SERVER_BIN"; then
    rm -f "$dest_tmp"
    die "failed to install ssserver to ${SS_SERVER_BIN}"
  fi

  log_info "installed ssserver -> ${SS_SERVER_BIN} (${SS_RUST_VERSION}, ${triple})"
  trap - RETURN
  rm -rf "$tmpdir"
  return 0
}
