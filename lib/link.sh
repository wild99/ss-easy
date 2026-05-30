# shellcheck shell=bash
#
# lib/link.sh — Shadowsocks ss:// URI construction and per-user output.
#
# PUBLIC CONTRACT (consumed by users.sh):
#   link_build <method> <secret> <host> <port> <tag>
#       print the ss:// connection URI in the SIP002 form for EVERY method:
#           ss://<base64url(method:secret)>@host:port#tag
#       The whole "method:secret" userinfo is URL-safe-base64 (no padding). For a
#       2022 cipher the secret is the base64 key, so the decoded userinfo is
#       "2022-blake3-aes-256-gcm:<base64key>". This is the form real clients expect
#       (Outline, v2rayN, NekoBox, …): they base64-decode the userinfo, so the
#       earlier plaintext/percent-encoded SIP022 form made them fail with
#       "Invalid symbol '-'". ss-rust accepts this SIP002 form for 2022 too.
#   link_render_qr <uri>
#       render the URI as a terminal QR via `qrencode -t ANSIUTF8`. If qrencode
#       is absent it warns and returns 0 (never aborts the caller).
#   link_write_access_file <name> <host> <port> <method> <secret> <uri>
#       write /etc/ss-easy/users/<name>.txt with mode 0600 (atomic temp+mv),
#       containing the link and human-readable connection details. The name is
#       expected pre-validated by users.sh; the path is built with basename
#       semantics so it can never escape SS_EASY_USERS_DIR.
# Decision 10: secrets are written only to the 0600 access file, never to a log.

# Guard against double-sourcing in the assembled bundle / nested sources.
if [ -n "${_SS_EASY_LINK_LOADED:-}" ]; then
  # shellcheck disable=SC2317  # reached only on re-source of this module.
  return 0 2>/dev/null || true
fi
_SS_EASY_LINK_LOADED=1

# --- internal helpers -------------------------------------------------------

# _link_b64url <string> — encode the argument as URL-safe base64 WITHOUT padding,
# the SIP002 userinfo encoding used for every method (classic and 2022).
_link_b64url() {
  printf '%s' "$1" | base64 | tr '+/' '-_' | tr -d '=\n'
}

# --- URI builder ------------------------------------------------------------

# link_build <method> <secret> <host> <port> <tag>
link_build() {
  local method="$1" secret="$2" host="$3" port="$4" tag="$5"

  # SIP002 for ALL methods: userinfo is base64url(method:secret). This is the
  # broadly-compatible form clients expect (Outline, v2rayN, NekoBox, …). For
  # 2022 ciphers the secret is the base64 key, so the decoded userinfo is
  # "2022-blake3-aes-256-gcm:<base64key>". The earlier plaintext/percent-encoded
  # SIP022 form parsed in ss-rust but real clients base64-decode the userinfo and
  # choke on the literal method (e.g. "Invalid symbol '-'").
  local userinfo
  userinfo="$(_link_b64url "${method}:${secret}")"
  printf 'ss://%s@%s:%s#%s\n' "$userinfo" "$host" "$port" "$tag"
}

# --- QR rendering -----------------------------------------------------------

# link_render_qr <uri> — print a terminal QR for the URI. Guarded: missing
# qrencode is a soft failure (the link itself is still usable as text).
link_render_qr() {
  local uri="$1"
  if ! command -v qrencode >/dev/null 2>&1; then
    log_warn "qrencode not found; skipping QR rendering"
    return 0
  fi
  # -m 1: trim the quiet-zone margin from the default 4 to 1 so the QR fits more
  # terminals (still scannable). ANSIUTF8 uses half-height blocks (compact).
  qrencode -t ANSIUTF8 -m 1 -- "$uri"
}

# --- access file ------------------------------------------------------------

# link_write_access_file <name> <host> <port> <method> <secret> <uri>
# Writes the 0600 per-user access file. The name must already be validated by
# the caller; here we additionally collapse it to a basename so a stray path
# separator can never redirect the write outside SS_EASY_USERS_DIR.
link_write_access_file() {
  local name="$1" host="$2" port="$3" method="$4" secret="$5" uri="$6"
  local dir="$SS_EASY_USERS_DIR"
  local safe target

  # Defence in depth: strip any directory component (path traversal guard).
  safe="$(basename -- "$name")"

  mkdir -p "$dir" || die "cannot create users dir: $dir"
  chmod 700 "$dir" 2>/dev/null || true

  target="$dir/$safe.txt"

  # Build the block, then write atomically at 0600 (atomic_write from common.sh).
  {
    printf 'ss-easy access details\n'
    printf '======================\n'
    printf 'name   : %s\n' "$name"
    printf 'server : %s\n' "$host"
    printf 'port   : %s\n' "$port"
    printf 'method : %s\n' "$method"
    printf 'secret : %s\n' "$secret"
    printf '\n'
    printf 'link:\n%s\n' "$uri"
  } | atomic_write "$target" || die "failed to write access file: $target"

  chmod 600 "$target" || die "cannot chmod 0600: $target"
}
