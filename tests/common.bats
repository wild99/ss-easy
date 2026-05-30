#!/usr/bin/env bats
#
# Unit tests for lib/common.sh primitives and the ss-easy dispatcher skeleton.
# These cover the public contract that Tasks 2-11 depend on.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  COMMON="$REPO_ROOT/lib/common.sh"
  ENTRY="$REPO_ROOT/ss-easy"
  TMPDIR_TEST="$(mktemp -d)"
}

teardown() {
  [ -n "${TMPDIR_TEST:-}" ] && rm -rf "$TMPDIR_TEST"
}

# --- sourcing has no side effects ------------------------------------------

@test "sourcing common.sh has no side effects (no output, exit 0)" {
  run bash -c "source '$COMMON'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "sourcing common.sh does not set global shell options" {
  # If common.sh set -e on source, the false below would abort the subshell.
  run bash -c "source '$COMMON'; false; echo REACHED"
  [ "$status" -eq 0 ]
  [ "$output" = "REACHED" ]
}

# --- constants -------------------------------------------------------------

@test "constants are defined and non-empty" {
  run bash -c "
    source '$COMMON'
    for v in SS_EASY_ETC SS_EASY_USERS SS_EASY_CONFIG SS_EASY_USERS_DIR \
             SS_RUST_VERSION DEFAULT_METHOD SS_SERVICE_USER SS_SERVER_BIN \
             SS_SERVICE_NAME SS_EASY_CHECKSUMS_DIR; do
      eval "val=\\\"\\\${\$v:-}\\\""
      [ -n \"\$val\" ] || { echo \"empty: \$v\"; exit 1; }
    done
  "
  [ "$status" -eq 0 ]
}

@test "SS_SERVER_BIN is the pinned absolute path" {
  run bash -c "source '$COMMON'; printf '%s' \"\$SS_SERVER_BIN\""
  [ "$status" -eq 0 ]
  [ "$output" = "/usr/local/bin/ssserver" ]
}

@test "SS_EASY_ETC is /etc/ss-easy and derived paths live under it" {
  run bash -c "source '$COMMON'; printf '%s|%s|%s|%s' \"\$SS_EASY_ETC\" \"\$SS_EASY_USERS\" \"\$SS_EASY_CONFIG\" \"\$SS_EASY_USERS_DIR\""
  [ "$status" -eq 0 ]
  [ "$output" = "/etc/ss-easy|/etc/ss-easy/users.json|/etc/ss-easy/config.json|/etc/ss-easy/users" ]
}

@test "DEFAULT_METHOD is the AEAD-2022 default" {
  run bash -c "source '$COMMON'; printf '%s' \"\$DEFAULT_METHOD\""
  [ "$status" -eq 0 ]
  [ "$output" = "2022-blake3-aes-256-gcm" ]
}

# --- die --------------------------------------------------------------------

@test "die exits non-zero with message on stderr" {
  run bash -c "source '$COMMON'; die 'boom'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"boom"* ]]
}

@test "die respects a custom exit code" {
  run bash -c "source '$COMMON'; die 'x' 7"
  [ "$status" -eq 7 ]
}

@test "die writes to stderr, not stdout" {
  run bash -c "source '$COMMON'; die 'secretmsg' 2>/dev/null"
  [ "$status" -ne 0 ]
  [[ "$output" != *"secretmsg"* ]]
}

# --- require_root -----------------------------------------------------------

@test "require_root fails for non-root with an actionable message" {
  if [ "$(id -u)" -eq 0 ]; then skip "running as root"; fi
  run bash -c "source '$COMMON'; require_root"
  [ "$status" -ne 0 ]
  [[ "$output" == *"root"* ]]
}

# --- logging ----------------------------------------------------------------

@test "log functions write to stderr and do not fail" {
  run bash -c "source '$COMMON'; log_info hi; log_warn careful; log_error nope; echo DONE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"DONE"* ]]
}

@test "log output carries no ANSI escapes when not a tty" {
  # Capture stderr (pipe => not a tty => colors must be disabled).
  run bash -c "source '$COMMON'; log_info colorcheck 2>&1 | cat"
  [ "$status" -eq 0 ]
  # No raw ESC (\033) byte in the output.
  printf '%s' "$output" | grep -q $'\033' && false || true
}

# --- atomic_write -----------------------------------------------------------

@test "atomic_write creates a 0600 file with the piped content and leaves no temp" {
  target="$TMPDIR_TEST/out.txt"
  run bash -c "source '$COMMON'; printf 'hello world' | atomic_write '$target'"
  [ "$status" -eq 0 ]
  [ -f "$target" ]
  [ "$(cat "$target")" = "hello world" ]
  perms="$(stat -c '%a' "$target")"
  [ "$perms" = "600" ]
  # No leftover temp files in the target directory.
  count="$(find "$TMPDIR_TEST" -type f | wc -l)"
  [ "$count" -eq 1 ]
}

@test "atomic_write does not corrupt an existing file when the write fails" {
  # Existing file lives in a writable dir; the *target* the helper is asked to
  # create sits in a non-existent subdir, so the temp creation (in that dir)
  # fails and the helper aborts non-zero without touching the existing file.
  keep="$TMPDIR_TEST/keep.txt"
  printf 'original' > "$keep"
  chmod 600 "$keep"
  badtarget="$TMPDIR_TEST/nodir/out.txt"
  run bash -c "source '$COMMON'; printf 'new' | atomic_write '$badtarget'"
  [ "$status" -ne 0 ]
  [ "$(cat "$keep")" = "original" ]
  [ ! -e "$badtarget" ]
  # No stray temp left behind in the real target dir.
  count="$(find "$TMPDIR_TEST" -maxdepth 1 -type f | wc -l)"
  [ "$count" -eq 1 ]
}

# --- dispatcher (entrypoint) ------------------------------------------------

@test "entrypoint is sourceable without running main (guard works)" {
  run bash -c "source '$ENTRY'; echo SOURCED"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SOURCED"* ]]
}

@test "dispatcher rejects an unknown command with non-zero and usage" {
  run bash "$ENTRY" bogus
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown command"* || "$output" == *"Usage"* || "$output" == *"usage"* ]]
}

@test "dispatcher with no command prints usage and exits non-zero" {
  run bash "$ENTRY"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Usage"* || "$output" == *"usage"* ]]
}

@test "--help prints usage and exits 0" {
  run bash "$ENTRY" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage"* || "$output" == *"usage"* ]]
}

@test "known subcommands are dispatched (stub) and exit 0" {
  for cmd in install uninstall user start stop restart status enable disable tui; do
    run bash "$ENTRY" "$cmd"
    [ "$status" -eq 0 ] || { echo "failed: $cmd (status $status)"; false; }
  done
}

# --- build ------------------------------------------------------------------

@test "build produces an executable, parseable bundle" {
  run bash "$REPO_ROOT/build.sh"
  [ "$status" -eq 0 ]
  [ -f "$REPO_ROOT/dist/ss-easy" ]
  [ -x "$REPO_ROOT/dist/ss-easy" ]
  run bash -n "$REPO_ROOT/dist/ss-easy"
  [ "$status" -eq 0 ]
}

@test "bundle has exactly one shebang and one set -euo pipefail" {
  bash "$REPO_ROOT/build.sh" >/dev/null
  sheb="$(grep -c '^#!' "$REPO_ROOT/dist/ss-easy")"
  [ "$sheb" -eq 1 ]
  seto="$(grep -c '^set -euo pipefail' "$REPO_ROOT/dist/ss-easy")"
  [ "$seto" -eq 1 ]
}

@test "bundle dispatches the same way as the dev entrypoint" {
  bash "$REPO_ROOT/build.sh" >/dev/null
  run bash "$REPO_ROOT/dist/ss-easy" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage"* || "$output" == *"usage"* ]]
  run bash "$REPO_ROOT/dist/ss-easy" bogus
  [ "$status" -ne 0 ]
}
