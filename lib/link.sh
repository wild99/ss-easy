# shellcheck shell=bash
#
# lib/link.sh — Shadowsocks ss:// URI construction and per-user output.
#
# PUBLIC CONTRACT (consumed by users.sh):
#   link_build <method> <secret> <host> <port> <tag>
#       print the ss:// connection URI. Two encodings, picked by method:
#         - SIP022 (2022-blake3-*): ss://<method>:<pct(base64key)>@host:port#tag
#           The userinfo is "method:key" with the key PERCENT-ENCODED: the 32-byte
#           key is STANDARD base64 (Decision 4) and may contain +,/,= which are
#           URL-unsafe in userinfo and break parsing if emitted raw. This matches
#           the canonical form ss-rust's own `ssurl` produces.
#         - classic AEAD (everything else, e.g. chacha20-ietf-poly1305):
#           ss://<base64url(method:password)>@host:port#tag  (SIP002).
#   link_render_qr <uri>
#       render the URI as a terminal QR via `qrencode -t ANSIUTF8`. If qrencode
#       is absent it warns and returns 0 (never aborts the caller).
#   link_write_access_file <name> <host> <port> <method> <secret> <uri>
#       write /etc/ss-easy/users/<name>.txt with mode 0600 (atomic temp+mv),
#       containing the link and human-readable connection details. The name is
#       expected pre-validated by users.sh; the path is built with basename
#       semantics so it can never escape SS_EASY_USERS_DIR.
#
# Decision 4: SIP022 links are structurally distinct and silently break if
# emitted as a plain-password classic link, so the format branch is explicit.
# Decision 10: secrets are written only to the 0600 access file, never to a log.

# Guard against double-sourcing in the assembled bundle / nested sources.
if [ -n "${_SS_EASY_LINK_LOADED:-}" ]; then
  # shellcheck disable=SC2317  # reached only on re-source of this module.
  return 0 2>/dev/null || true
fi
_SS_EASY_LINK_LOADED=1

# --- internal helpers -------------------------------------------------------

# _link_is_sip022 <method> — exit 0 if the method uses the SIP022 (2022-blake3)
# key-based scheme, non-zero for classic password-based AEAD ciphers.
_link_is_sip022() {
  case "$1" in
    2022-blake3-*) return 0 ;;
    *)             return 1 ;;
  esac
}

# _link_b64url <string> — encode stdin-less argument as URL-safe base64 WITHOUT
# padding, the SIP002 userinfo encoding for classic links.
_link_b64url() {
  printf '%s' "$1" | base64 | tr '+/' '-_' | tr -d '=\n'
}

# _link_pct <string> — percent-encode bytes outside the RFC3986 "unreserved" set
# (A-Z a-z 0-9 - . _ ~). A standard-base64 SIP022 key contains +,/,= which are
# unsafe in URL userinfo; encoding them yields the canonical ss-rust `ssurl` form.
_link_pct() {
  local s="$1" out="" i c hex
  for (( i = 0; i < ${#s}; i++ )); do
    c="${s:i:1}"
    case "$c" in
      [A-Za-z0-9._~-]) out+="$c" ;;
      *) printf -v hex '%02X' "'$c"; out+="%${hex}" ;;
    esac
  done
  printf '%s' "$out"
}

# --- URI builder ------------------------------------------------------------

# link_build <method> <secret> <host> <port> <tag>
link_build() {
  local method="$1" secret="$2" host="$3" port="$4" tag="$5"

  if _link_is_sip022 "$method"; then
    # SIP022: userinfo is "method:percent-encode(key)". The key is standard base64
    # (+,/,=), which is URL-unsafe in userinfo and breaks parsing if emitted raw;
    # percent-encoding matches the canonical form ss-rust's `ssurl` produces.
    printf 'ss://%s:%s@%s:%s#%s\n' "$method" "$(_link_pct "$secret")" "$host" "$port" "$tag"
  else
    # Classic SIP002: userinfo is base64url(method:password).
    local userinfo
    userinfo="$(_link_b64url "${method}:${secret}")"
    printf 'ss://%s@%s:%s#%s\n' "$userinfo" "$host" "$port" "$tag"
  fi
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
  qrencode -t ANSIUTF8 "$uri"
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
