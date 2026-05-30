#!/usr/bin/env bash
#
# tests/integration/proxy-e2e.sh — live E2E proxy smoke (runs INSIDE a container).
#
# Proves that a generated ss:// link actually works end-to-end, catching
# SIP022/cipher/key-format regressions a listening-check would miss:
#
#   1. install the pinned ssserver binary via lib/binary.sh (real download +
#      SHA256 verify against checksums/ss-rust.sha256).
#   2. generate a user + config.json + ss:// link via lib/{config,users,link}.sh
#      — the SAME code the real installer uses, but with no systemd/firewall.
#   3. start `ssserver -c <generated config.json>` in the background.
#   4. start `sslocal` (from the SAME ss-rust archive) as a SOCKS5 proxy,
#      configured FROM the generated ss:// link.
#   5. `curl --socks5-hostname <sslocal>` a target THROUGH the proxy -> success.
#
# Exits non-zero on any failure. Designed to be the body of the CI e2e job and
# to be runnable locally: `docker run ... debian /src/tests/integration/proxy-e2e.sh`.
#
# It deliberately does NOT use systemd: a plain container has no PID 1 systemd,
# so we drive the ssserver/sslocal processes directly. The systemd unit itself
# is covered by the lifecycle script (which skips only the `systemctl` asserts
# when systemd is absent).

set -euo pipefail

REPO="${SS_EASY_SRC:-/src}"
METHOD="${E2E_METHOD:-2022-blake3-aes-256-gcm}"
TARGET_URL="${E2E_TARGET:-http://example.com}"

log() { printf '[e2e] %s\n' "$*"; }
fail() { printf '[e2e] FAIL: %s\n' "$*" >&2; exit 1; }

# Isolate all state under a temp root so the host /etc is never touched and the
# script is re-runnable. The lib modules read SS_EASY_* at call time.
WORK="$(mktemp -d)"
export SS_EASY_ETC="$WORK/etc"
export SS_EASY_USERS="$SS_EASY_ETC/users.json"
export SS_EASY_CONFIG="$SS_EASY_ETC/config.json"
export SS_EASY_USERS_DIR="$SS_EASY_ETC/users"
export SS_SERVER_BIN="$WORK/bin/ssserver"

SERVER_PID=""; LOCAL_PID=""
cleanup() {
  [ -n "$LOCAL_PID" ]  && kill "$LOCAL_PID"  2>/dev/null
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
  rm -rf "$WORK"
  return 0
}
trap cleanup EXIT

# dump_logs — print BOTH process logs to stderr so any failure (ssserver/sslocal
# never bound, a process died, or curl failed) is diagnosable from CI output. The
# single CI flake (rocky:9 + 2022-blake3) was invisible precisely because the
# readiness timeout did not dump sslocal.log. Tolerate either log being absent.
dump_logs() {
  echo "--- ssserver.log ---" >&2; cat "$WORK/ssserver.log" >&2 2>/dev/null || echo "(no ssserver.log)" >&2
  echo "--- sslocal.log ---"  >&2; cat "$WORK/sslocal.log"  >&2 2>/dev/null || echo "(no sslocal.log)"  >&2
}

# --- source the real modules (dev mode) -------------------------------------
# shellcheck source=/dev/null
. "$REPO/lib/common.sh"
# shellcheck source=/dev/null
. "$REPO/lib/binary.sh"
# shellcheck source=/dev/null
. "$REPO/lib/config.sh"
# shellcheck source=/dev/null
. "$REPO/lib/link.sh"
# shellcheck source=/dev/null
. "$REPO/lib/users.sh"

# NOTE: ss_install_binary verifies against the SHA256 table EMBEDDED in
# lib/binary.sh (build.sh keeps it in sync with checksums/ss-rust.sha256); it
# reads no sibling checksum file at runtime, so nothing extra is wired here.

# --- 1) install the pinned ssserver binary (real download + verify) ---------
log "installing pinned ssserver (${SS_RUST_VERSION}) via lib/binary.sh"
mkdir -p "$(dirname "$SS_SERVER_BIN")"
ss_install_binary || fail "ss_install_binary failed"
[ -x "$SS_SERVER_BIN" ] || fail "ssserver not installed at $SS_SERVER_BIN"

# sslocal ships in the same archive; ss_install_binary only copies ssserver, so
# re-extract sslocal from the freshly downloaded archive next to ssserver. We
# reuse the exact pinned asset + checksum the binary module just verified.
SSLOCAL="$WORK/bin/sslocal"
extract_sslocal() {
  local triple asset url tmp
  triple="$(ss_detect_arch)"
  asset="shadowsocks-${SS_RUST_VERSION}.${triple}.tar.xz"
  url="${SS_RELEASE_BASE_URL}/${asset}"
  tmp="$(mktemp -d)"
  log "fetching ${asset} for sslocal"
  ss_download_url "$url" "$tmp/$asset" || { rm -rf "$tmp"; return 1; }
  tar -C "$tmp" -xJf "$tmp/$asset"
  local src
  src="$(find "$tmp" -type f -name sslocal -print -quit)"
  [ -n "$src" ] || { rm -rf "$tmp"; return 1; }
  mkdir -p "$(dirname "$SSLOCAL")"
  cp "$src" "$SSLOCAL"; chmod 0755 "$SSLOCAL"
  rm -rf "$tmp"
}
extract_sslocal || fail "could not extract sslocal from the pinned archive"
[ -x "$SSLOCAL" ] || fail "sslocal not available"

# --- 2) generate registry + user + config.json + ss:// link -----------------
log "generating user 'e2e' (method=${METHOD}) via lib/{config,users,link}.sh"
config_init
# Server is reachable on loopback in this single container; the link host is
# 127.0.0.1 so sslocal connects back to the local ssserver.
config_set_server_address "127.0.0.1"
config_set_default_method "$METHOD"

LINK="$(users_add e2e "$METHOD" | tail -n1)"
[ -n "$LINK" ] || fail "users_add produced no ss:// link"
case "$LINK" in ss://*) : ;; *) fail "not an ss:// link: $LINK" ;; esac
# Do NOT print the link verbatim: the userinfo carries the secret (Decision 10).
log "generated a valid ss:// link (userinfo/secret redacted)"
log "config.json:"; jq . "$SS_EASY_CONFIG" || fail "config.json invalid JSON"

SERVER_PORT="$(jq -r '.servers[0].server_port' "$SS_EASY_CONFIG")"
[ -n "$SERVER_PORT" ] || fail "could not read server port from config.json"

# --- 3) start ssserver from the generated config ----------------------------
log "starting ssserver -c config.json (port ${SERVER_PORT})"
"$SS_SERVER_BIN" -c "$SS_EASY_CONFIG" >"$WORK/ssserver.log" 2>&1 &
SERVER_PID=$!

# Wait for the server to be listening on its TCP port. Budget ~30s (150 × 0.2s):
# a cold CI runner (rocky image pull + GPG import under load) can push first-bind
# well past the old 10s window — that is exactly the timing flake we are killing.
wait_listen() {
  local port="$1" i
  for i in $(seq 1 150); do
    : "$i"  # loop counter only; bound the wait to ~30s
    if "$SS_SERVER_BIN" --version >/dev/null 2>&1 \
       && (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
      exec 3>&- 3<&- 2>/dev/null || true
      return 0
    fi
    sleep 0.2
  done
  return 1
}
wait_listen "$SERVER_PORT" || { dump_logs; fail "ssserver did not start listening on $SERVER_PORT"; }
kill -0 "$SERVER_PID" 2>/dev/null || { dump_logs; fail "ssserver process died"; }

# --- 4) start sslocal as a SOCKS5 proxy from the ss:// link ------------------
SOCKS_PORT="${E2E_SOCKS_PORT:-11080}"
log "starting sslocal (SOCKS5 on 127.0.0.1:${SOCKS_PORT}) from the ss:// link"
# sslocal accepts the ss:// URL directly via --server-url; this is the cleanest
# proof the LINK itself is correct (no hand-built client config).
"$SSLOCAL" --server-url "$LINK" \
  --local-addr "127.0.0.1:${SOCKS_PORT}" --protocol socks \
  >"$WORK/sslocal.log" 2>&1 &
LOCAL_PID=$!

wait_listen "$SOCKS_PORT" || { dump_logs; fail "sslocal did not start listening on $SOCKS_PORT"; }
kill -0 "$LOCAL_PID" 2>/dev/null || { dump_logs; fail "sslocal process died"; }

# --- 5) curl a target THROUGH the proxy -------------------------------------
# Retry up to 3× with a short sleep: the SOCKS port can be bound a beat before
# sslocal has fully wired its upstream session, so the very first request through
# a just-came-up proxy may transiently fail. We still PROVE a real 2xx/3xx — the
# success criterion is unchanged, the retry only absorbs that startup race.
log "curl ${TARGET_URL} through the SOCKS5 proxy (${METHOD})"
code=""
for attempt in 1 2 3; do
  code="$(curl --silent --show-error --max-time 30 \
          --socks5-hostname "127.0.0.1:${SOCKS_PORT}" \
          -o /dev/null -w '%{http_code}' "$TARGET_URL" || true)"
  log "HTTP status through proxy (attempt ${attempt}/3): ${code}"
  case "$code" in 2*|3*) break ;; esac
  [ "$attempt" -lt 3 ] && sleep 1
done
case "$code" in
  2*|3*) log "PROXY E2E PASSED (method=${METHOD}): traffic flowed through the generated ss:// link" ;;
  *)
    dump_logs
    fail "curl through proxy returned status '${code}' (expected 2xx/3xx)"
    ;;
esac
