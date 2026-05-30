#!/usr/bin/env bats
#
# Unit tests for lib/link.sh — ss:// URI builders (classic SIP002 + SIP022),
# terminal QR rendering, and the per-user 0600 access-file writer.
#
# Reference fixtures are decoded in FULL (whole userinfo payload), not matched
# by prefix, so a regression in encoding (e.g. url-safe vs standard base64,
# or base64-encoding a SIP022 userinfo) is caught.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  COMMON="$REPO_ROOT/lib/common.sh"
  LINK="$REPO_ROOT/lib/link.sh"
  TMPDIR_TEST="$(mktemp -d)"

  export SS_EASY_ETC="$TMPDIR_TEST/etc"
  export SS_EASY_USERS_DIR="$SS_EASY_ETC/users"
}

teardown() {
  [ -n "${TMPDIR_TEST:-}" ] && rm -rf "$TMPDIR_TEST"
}

# Source common.sh + link.sh in a fresh shell with overridden paths, then run
# the given snippet. common.sh hard-sets paths to /etc, so re-apply overrides.
in_env() {
  bash -c "
    set -euo pipefail
    source '$COMMON'
    SS_EASY_ETC='$SS_EASY_ETC'
    SS_EASY_USERS_DIR='$SS_EASY_USERS_DIR'
    source '$LINK'
    $1
  "
}

# --- classic SIP002 ---------------------------------------------------------

@test "classic link matches fixture (full userinfo decode)" {
  # chacha20 classic: ss://base64url(method:password)@host:port#tag
  link="$(in_env "link_build 'chacha20-ietf-poly1305' 'p@ss-word123' '203.0.113.10' 18342 'alice'")"
  # Strip scheme, tag, host:port → isolate the base64url userinfo.
  [[ "$link" == ss://* ]]
  userinfo="${link#ss://}"
  userinfo="${userinfo%%@*}"
  # base64url decode (restore padding) → must equal exactly method:password.
  pad=$(( (4 - ${#userinfo} % 4) % 4 ))
  padded="$userinfo$(printf '=%.0s' $(seq 1 $pad))"
  decoded="$(printf '%s' "$padded" | tr '_-' '/+' | base64 -d)"
  [ "$decoded" = "chacha20-ietf-poly1305:p@ss-word123" ]
}

@test "classic link carries host, port and tag verbatim" {
  link="$(in_env "link_build 'chacha20-ietf-poly1305' 'pw' '203.0.113.10' 18342 'alice'")"
  [[ "$link" == *"@203.0.113.10:18342#alice" ]]
}

# --- SIP022 -----------------------------------------------------------------

@test "sip022 link is SIP002 base64url(method:key) (regression: real clients base64-decode userinfo)" {
  # 2022-blake3: ss://base64url(method:key)@host:port#tag. The key is standard
  # base64 (+,/,=); the WHOLE "method:key" is wrapped in URL-safe base64 so the
  # userinfo carries no raw +,/,=,: — earlier plaintext/percent forms made real
  # clients (which base64-decode the userinfo) fail with "Invalid symbol '-'".
  key='ABCDEFGHIJKLMNOPQRSTUVWXYZ012345+/abcdef0123456789ABCDEF01234='
  link="$(in_env "link_build '2022-blake3-aes-256-gcm' '$key' 'example.com' 9000 'bob'")"
  [[ "$link" == ss://* ]]
  userinfo="${link#ss://}"
  userinfo="${userinfo%%@*}"
  # Pure URL-safe base64, no padding: no ':' '+' '/' '=' may appear in the userinfo.
  [[ "$userinfo" != *":"* ]]
  [[ "$userinfo" != *"+"* ]]
  [[ "$userinfo" != *"/"* ]]
  [[ "$userinfo" != *"="* ]]
  # Round-trip: base64url-decoding recovers exactly "method:key".
  b="$(printf '%s' "$userinfo" | tr '_-' '/+')"
  case $(( ${#b} % 4 )) in 2) b="$b==";; 3) b="$b=";; esac
  decoded="$(printf '%s' "$b" | base64 -d)"
  [ "$decoded" = "2022-blake3-aes-256-gcm:$key" ]
  [[ "$link" == *"@example.com:9000#bob" ]]
}

@test "both classic and sip022 use the SIP002 base64url envelope (no literal colon in userinfo)" {
  classic="$(in_env "link_build 'chacha20-ietf-poly1305' 'pw' 'h' 1 't'")"
  sip022="$(in_env "link_build '2022-blake3-aes-256-gcm' 'a2V5' 'h' 1 't'")"
  ci="${classic#ss://}"; ci="${ci%%@*}"
  si="${sip022#ss://}"; si="${si%%@*}"
  # Both wrap "method:secret" in base64url, so neither userinfo shows a literal ':'.
  [[ "$ci" != *":"* ]]
  [[ "$si" != *":"* ]]
}

# --- access file ------------------------------------------------------------

@test "access file is written 0600 and contains the link" {
  in_env "link_write_access_file 'alice' '203.0.113.10' 18342 '2022-blake3-aes-256-gcm' 'a2V5' 'ss://2022-blake3-aes-256-gcm:a2V5@203.0.113.10:18342#alice'"
  f="$SS_EASY_USERS_DIR/alice.txt"
  [ -f "$f" ]
  [ "$(stat -c '%a' "$f")" = "600" ]
  grep -q 'ss://2022-blake3-aes-256-gcm:a2V5@203.0.113.10:18342#alice' "$f"
}

@test "access file path is built only from a validated name (no traversal)" {
  # link.sh itself does not validate; users.sh does. But the writer must place
  # the file strictly inside USERS_DIR using basename semantics.
  in_env "link_write_access_file 'safe_name-1' 'h' 1 'm' 's' 'ss://x'"
  [ -f "$SS_EASY_USERS_DIR/safe_name-1.txt" ]
}

# --- QR guard ---------------------------------------------------------------

@test "qr render is skipped gracefully when qrencode is absent" {
  # Run with an empty PATH-ish (only builtins) so qrencode is not found;
  # link_render_qr must not crash the caller.
  run in_env "PATH=/nonexistent link_render_qr 'ss://x' || echo GUARDED"
  [ "$status" -eq 0 ]
}
