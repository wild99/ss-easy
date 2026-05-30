#!/usr/bin/env bats
#
# Unit tests for lib/uninstall.sh — the full-purge orchestration (do_uninstall).
#
# Strategy: every external command the module shells out to (systemctl, ufw,
# firewall-cmd, userdel, getent) is replaced with a PATH stub that logs its own
# "$@" to $CALLS, so assertions are a plain grep over the call log. The config
# dir, binary and audit log are redirected into a temp tree via the same
# overridable variables the production modules expose, so the tests exercise the
# real removal logic without touching the host.
#
# The load-bearing invariants are NEGATIVE and behavioural:
#   * the SSH rule (port 22 / ssh service) is never formed — full purge included;
#   * the firewall is never enabled/disabled/reset from scratch;
#   * the service user is removed ONLY when it equals the SS_SERVICE_USER
#     constant from common.sh (tool-created);
#   * silent mode never reads stdin / never prompts;
#   * a second run over an already-clean host still exits 0 (idempotent).

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  TMPDIR_TEST="$(mktemp -d)"
  STUB_DIR="$TMPDIR_TEST/bin"
  mkdir -p "$STUB_DIR"
  CALLS="$TMPDIR_TEST/calls.log"
  : > "$CALLS"

  # Redirect every host path the module writes/removes into the temp tree.
  SS_EASY_ETC="$TMPDIR_TEST/etc/ss-easy"
  SS_EASY_USERS="$SS_EASY_ETC/users.json"
  SS_SERVER_BIN="$TMPDIR_TEST/usr/local/bin/ssserver"
  SS_UNIT_FILE="$TMPDIR_TEST/etc/systemd/system/ss-easy.service"
  SS_AUDIT_LOG="$TMPDIR_TEST/var/log/ss-easy.log"

  mkdir -p "$SS_EASY_ETC" "$(dirname "$SS_SERVER_BIN")" \
           "$(dirname "$SS_UNIT_FILE")" "$(dirname "$SS_AUDIT_LOG")"
}

teardown() {
  [ -n "${TMPDIR_TEST:-}" ] && rm -rf "$TMPDIR_TEST"
}

# Drop an executable stub named $1 into the PATH-shadowing dir. The body $2 runs
# after the call has been logged, so it only sets exit status / prints output.
make_stub() {
  local name="$1" body="${2:-:}" sh
  sh="$(command -v bash)"
  {
    printf '#!%s\n' "$sh"
    printf 'printf "%%s\\n" "%s $*" >> "%s"\n' "$name" "$CALLS"
    printf '%s\n' "$body"
  } > "$STUB_DIR/$name"
  chmod +x "$STUB_DIR/$name"
}

# Seed a registry with two user ports so the firewall step has something to close.
seed_registry() {
  cat > "$SS_EASY_USERS" <<'JSON'
{
  "schema_version": 1,
  "server_address": "203.0.113.7",
  "default_method": "2022-blake3-aes-256-gcm",
  "users": [
    {"name": "alice", "port": 9001, "method": "m", "secret": "S1", "created": "2026-01-01"},
    {"name": "bob",   "port": 9002, "method": "m", "secret": "S2", "created": "2026-01-02"}
  ]
}
JSON
}

# Lay down a unit file and a binary so the removal steps have real targets.
seed_artifacts() {
  : > "$SS_UNIT_FILE"
  : > "$SS_SERVER_BIN"
}

# The standard mock environment: active firewall (ufw), working systemctl, a
# getent that reports the service user exists, and a userdel that just logs.
stub_full_environment() {
  make_stub systemctl 'exit 0'
  make_stub ufw 'case "$1" in status) echo "Status: active";; esac; exit 0'
  make_stub userdel 'exit 0'
  # getent passwd <name>: succeed (user exists) only for the ss-easy account.
  make_stub getent 'case "$2" in ss-easy) echo "ss-easy:x:998:998::/nonexistent:/usr/sbin/nologin"; exit 0;; esac; exit 2'
}

# Run a snippet with the stub dir prepended to PATH and the module sourced.
# common.sh hard-exports SS_EASY_ETC / SS_EASY_USERS / SS_SERVER_BIN to their
# real host defaults at source time, so — exactly as config.bats does — the
# overrides are re-asserted AFTER the module (and its common.sh) are sourced.
un() {
  run bash -c "
    PATH=\"$STUB_DIR:\$PATH\"
    export CALLS='$CALLS'
    export SS_AUDIT_LOG='$SS_AUDIT_LOG' SS_UNIT_FILE='$SS_UNIT_FILE'
    source '$REPO_ROOT/lib/uninstall.sh'
    SS_EASY_ETC='$SS_EASY_ETC'
    SS_EASY_USERS='$SS_EASY_USERS'
    SS_SERVER_BIN='$SS_SERVER_BIN'
    export SS_EASY_ETC SS_EASY_USERS SS_SERVER_BIN
    $1
  "
}

# --- sourcing has no side effects ------------------------------------------

@test "sourcing uninstall.sh has no side effects (exit 0)" {
  run bash -c "source '$REPO_ROOT/lib/uninstall.sh'"
  [ "$status" -eq 0 ]
}

@test "do_uninstall is exposed after sourcing" {
  un 'type -t do_uninstall'
  [ "$status" -eq 0 ]
  [ "$output" = "function" ]
}

# --- silent mode: no prompt, full purge ------------------------------------

@test "silent mode runs without prompt" {
  seed_registry
  seed_artifacts
  stub_full_environment
  # stdin closed: if the module tried to read a confirmation it would hang/fail.
  un 'do_uninstall --silent </dev/null'
  [ "$status" -eq 0 ]
  grep -q 'stop ss-easy.service' "$CALLS"
  [ ! -e "$SS_EASY_ETC" ]
  [ ! -e "$SS_SERVER_BIN" ]
}

@test "silent mode accepts --yes as an alias" {
  seed_registry
  seed_artifacts
  stub_full_environment
  un 'do_uninstall --yes </dev/null'
  [ "$status" -eq 0 ]
  [ ! -e "$SS_EASY_ETC" ]
}

# --- interactive confirmation ----------------------------------------------

@test "interactive confirm yes purges" {
  seed_registry
  seed_artifacts
  stub_full_environment
  un 'printf "yes\n" | do_uninstall'
  [ "$status" -eq 0 ]
  grep -q 'stop ss-easy.service' "$CALLS"
  grep -q 'disable ss-easy.service' "$CALLS"
  grep -q 'userdel' "$CALLS"
  [ ! -e "$SS_EASY_ETC" ]
  [ ! -e "$SS_SERVER_BIN" ]
}

@test "interactive decline aborts (nothing removed, exit 0)" {
  seed_registry
  seed_artifacts
  stub_full_environment
  un 'printf "no\n" | do_uninstall'
  [ "$status" -eq 0 ]
  # No destructive call happened and the artifacts survive.
  [ ! -s "$CALLS" ]
  [ -e "$SS_EASY_ETC" ]
  [ -e "$SS_SERVER_BIN" ]
}

@test "interactive empty answer aborts (default no)" {
  seed_registry
  seed_artifacts
  stub_full_environment
  un 'printf "\n" | do_uninstall'
  [ "$status" -eq 0 ]
  [ -e "$SS_EASY_ETC" ]
}

# --- firewall: only user ports, never SSH ----------------------------------

@test "firewall closes only user ports, never SSH" {
  seed_registry
  seed_artifacts
  stub_full_environment
  un 'do_uninstall --silent </dev/null'
  [ "$status" -eq 0 ]
  # The two registry ports are closed...
  grep -q 'delete allow 9001' "$CALLS"
  grep -q 'delete allow 9002' "$CALLS"
  # ...nothing anywhere touches the SSH rule (port 22 / ssh service)...
  ! grep -Eq '(^| )22( |$)|ssh' "$CALLS"
  # ...and the firewall itself is never enabled/disabled/reset from scratch.
  # (Scope to the ufw lines so a legitimate `systemctl disable` is not a false
  # positive — the systemd unit, not the firewall, is being disabled.)
  ! grep -E '^ufw ' "$CALLS" | grep -Eq 'enable|disable|reset'
}

@test "firewall ports read from registry" {
  # A different registry must drive a different set of closed ports.
  cat > "$SS_EASY_USERS" <<'JSON'
{"schema_version":1,"server_address":"","default_method":"m",
 "users":[{"name":"x","port":7777,"method":"m","secret":"S","created":"2026-01-01"}]}
JSON
  seed_artifacts
  stub_full_environment
  un 'do_uninstall --silent </dev/null'
  [ "$status" -eq 0 ]
  grep -q '7777' "$CALLS"
  ! grep -q '9001' "$CALLS"
}

@test "missing registry skips firewall step (exit 0)" {
  # No users.json at all.
  rm -f "$SS_EASY_USERS"
  seed_artifacts
  stub_full_environment
  un 'do_uninstall --silent </dev/null'
  [ "$status" -eq 0 ]
  # No port rules attempted, but the rest of the purge still ran.
  ! grep -q 'delete allow' "$CALLS"
  grep -q 'stop ss-easy.service' "$CALLS"
  [ ! -e "$SS_SERVER_BIN" ]
}

# --- service user removal gated on the constant ----------------------------

@test "service user removed only when it matches the constant" {
  seed_registry
  seed_artifacts
  stub_full_environment
  un 'do_uninstall --silent </dev/null'
  [ "$status" -eq 0 ]
  grep -q 'userdel.*ss-easy' "$CALLS"
}

@test "service user not removed when it does not exist" {
  seed_registry
  seed_artifacts
  make_stub systemctl 'exit 0'
  make_stub ufw 'case "$1" in status) echo "Status: active";; esac; exit 0'
  make_stub userdel 'exit 0'
  # getent always fails: the account is absent.
  make_stub getent 'exit 2'
  un 'do_uninstall --silent </dev/null'
  [ "$status" -eq 0 ]
  ! grep -q 'userdel' "$CALLS"
}

# --- removal of config dir and binary --------------------------------------

@test "removes config dir and binary" {
  seed_registry
  seed_artifacts
  stub_full_environment
  # Add per-user access files so we prove the whole tree goes.
  mkdir -p "$SS_EASY_ETC/users"
  : > "$SS_EASY_ETC/users/alice.txt"
  : > "$SS_EASY_ETC/config.json"
  un 'do_uninstall --silent </dev/null'
  [ "$status" -eq 0 ]
  [ ! -e "$SS_EASY_ETC" ]
  [ ! -e "$SS_SERVER_BIN" ]
}

# --- idempotency ------------------------------------------------------------

@test "idempotent on absent service/binary/user" {
  # Nothing seeded: no registry, no unit, no binary, no user.
  make_stub systemctl 'exit 0'
  make_stub ufw 'case "$1" in status) echo "Status: active";; esac; exit 0'
  make_stub userdel 'exit 0'
  make_stub getent 'exit 2'
  rm -rf "$SS_EASY_ETC"
  un 'do_uninstall --silent </dev/null'
  [ "$status" -eq 0 ]
}

@test "idempotent on a second back-to-back run" {
  seed_registry
  seed_artifacts
  stub_full_environment
  un 'do_uninstall --silent </dev/null; do_uninstall --silent </dev/null'
  [ "$status" -eq 0 ]
  [ ! -e "$SS_EASY_ETC" ]
  [ ! -e "$SS_SERVER_BIN" ]
}

# --- audit log --------------------------------------------------------------

@test "audit logged without secrets" {
  seed_registry
  seed_artifacts
  stub_full_environment
  un 'do_uninstall --silent </dev/null'
  [ "$status" -eq 0 ]
  [ -f "$SS_AUDIT_LOG" ]
  grep -q 'uninstall' "$SS_AUDIT_LOG"
  # The registry secrets (S1/S2) must never reach the audit log.
  ! grep -q 'S1' "$SS_AUDIT_LOG"
  ! grep -q 'S2' "$SS_AUDIT_LOG"
}

@test "audit log is created 0600" {
  seed_registry
  seed_artifacts
  stub_full_environment
  un 'do_uninstall --silent </dev/null'
  [ "$status" -eq 0 ]
  perms="$(stat -c '%a' "$SS_AUDIT_LOG")"
  [ "$perms" = "600" ]
}

# --- service teardown order -------------------------------------------------

@test "service stopped, disabled and unit removed with daemon-reload" {
  seed_registry
  seed_artifacts
  stub_full_environment
  un 'do_uninstall --silent </dev/null'
  [ "$status" -eq 0 ]
  grep -q 'stop ss-easy.service' "$CALLS"
  grep -q 'disable ss-easy.service' "$CALLS"
  grep -q 'daemon-reload' "$CALLS"
  [ ! -e "$SS_UNIT_FILE" ]
}
