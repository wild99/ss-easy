#!/usr/bin/env bats
#
# Unit tests for lib/service.sh — generation of the single ss-easy.service unit
# and the systemctl lifecycle wrappers.
#
# Nothing here touches the real systemd or the real user database: systemctl,
# useradd and getent are mocked as PATH stubs that log their arguments, and the
# unit file plus config paths are redirected into a temp dir via the overridable
# path variables. So the suite runs unprivileged and without systemd.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  COMMON="$REPO_ROOT/lib/common.sh"
  SERVICE="$REPO_ROOT/lib/service.sh"
  TMPDIR_TEST="$(mktemp -d)"
  STUB_DIR="$TMPDIR_TEST/bin"
  mkdir -p "$STUB_DIR"
  LOG="$TMPDIR_TEST/calls.log"

  # Redirect every path the module writes to / reads from into the temp dir.
  export SS_UNIT_FILE="$TMPDIR_TEST/ss-easy.service"
  export SS_EASY_ETC="$TMPDIR_TEST/etc"
  export SS_EASY_CONFIG="$SS_EASY_ETC/config.json"
}

teardown() {
  [ -n "${TMPDIR_TEST:-}" ] && rm -rf "$TMPDIR_TEST"
}

# Stub $1 that appends "name <args>" to $LOG and exits with $2 (default 0). The
# shebang points at an absolute bash so the stub runs even under a stub-only
# PATH where /usr/bin/env bash could not find an interpreter.
make_logging_stub() {
  local name="$1" rc="${2:-0}" sh
  sh="$(command -v bash)"
  printf '#!%s\nprintf "%%s %%s\\n" "%s" "$*" >> "%s"\nexit %s\n' \
    "$sh" "$name" "$LOG" "$rc" > "$STUB_DIR/$name"
  chmod +x "$STUB_DIR/$name"
}

# Stub $1 that prints $2 to stdout then exits $3 (default 0). Used for systemctl
# is-active and getent lookups whose stdout the code inspects.
make_output_stub() {
  local name="$1" out="$2" rc="${3:-0}" sh
  sh="$(command -v bash)"
  printf '#!%s\nprintf "%%s\\n" "%s"\nexit %s\n' "$sh" "$out" "$rc" \
    > "$STUB_DIR/$name"
  chmod +x "$STUB_DIR/$name"
}

# Run a snippet in a fresh bash sourcing common+service with the overridden
# paths and a chosen PATH prefix. Usage: run_env "<extra PATH dir>" "<snippet>"
run_env() {
  local extra_path="$1" snippet="$2" pure="${3:-}"
  # Default: prepend the stub dir to the host PATH (stubs win, real coreutils
  # remain available). When $pure is set, use ONLY the stub dir — needed by the
  # "no systemctl" test, which must NOT inherit a systemctl from the host PATH
  # (otherwise it fails on any systemd host). The code paths exercised in pure
  # mode reach the `command -v systemctl` guard using shell builtins only.
  local path_expr="$extra_path:$PATH"
  [ -n "$pure" ] && path_expr="$extra_path"
  bash -c "
    set -euo pipefail
    PATH='$path_expr'
    export SS_UNIT_FILE='$SS_UNIT_FILE'
    export SS_EASY_ETC='$SS_EASY_ETC'
    export SS_EASY_CONFIG='$SS_EASY_CONFIG'
    source '$COMMON'
    SS_EASY_ETC='$SS_EASY_ETC'
    SS_EASY_CONFIG='$SS_EASY_CONFIG'
    source '$SERVICE'
    $snippet
  "
}

# --- sourcing has no side effects ------------------------------------------

@test "sourcing service.sh has no side effects (no output, exit 0)" {
  run bash -c "source '$COMMON'; source '$SERVICE'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- unit generation: runs as non-root ------------------------------------

@test "generates_unit_runs_as_non_root" {
  run run_env "$STUB_DIR" "service_write_unit; cat '$SS_UNIT_FILE'"
  [ "$status" -eq 0 ]
  # User/Group are the dedicated unprivileged account from the constant.
  [[ "$output" == *"User=ss-easy"* ]]
  [[ "$output" == *"Group=ss-easy"* ]]
  # And never root.
  [[ "$output" != *"User=root"* ]]
}

# --- unit generation: hardening directives --------------------------------

@test "unit_has_all_hardening_directives" {
  make_logging_stub systemctl
  run run_env "$STUB_DIR" "service_write_unit; cat '$SS_UNIT_FILE'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"NoNewPrivileges=yes"* ]]
  [[ "$output" == *"ProtectSystem=strict"* ]]
  [[ "$output" == *"ProtectHome=yes"* ]]
  [[ "$output" == *"PrivateTmp=yes"* ]]
}

# --- unit generation: config read-only ------------------------------------

@test "unit_config_is_read_only" {
  run run_env "$STUB_DIR" "service_write_unit; cat '$SS_UNIT_FILE'"
  [ "$status" -eq 0 ]
  # The generated config must be exposed read-only to the service.
  [[ "$output" == *"ReadOnlyPaths=$SS_EASY_CONFIG"* ]]
}

# --- unit generation: absolute ExecStart ----------------------------------

@test "unit_execstart_uses_generated_config" {
  run run_env "$STUB_DIR" "service_write_unit; cat '$SS_UNIT_FILE'"
  [ "$status" -eq 0 ]
  # Absolute binary path (from SS_SERVER_BIN) + the generated config; a bare
  # name would fail under ProtectSystem=strict.
  [[ "$output" == *"ExecStart=/usr/local/bin/ssserver -c $SS_EASY_CONFIG"* ]]
}

@test "unit has Type=simple and Restart=on-failure and WantedBy" {
  run run_env "$STUB_DIR" "service_write_unit; cat '$SS_UNIT_FILE'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Type=simple"* ]]
  [[ "$output" == *"Restart=on-failure"* ]]
  [[ "$output" == *"WantedBy=multi-user.target"* ]]
}

@test "writing the unit triggers daemon-reload" {
  make_logging_stub systemctl
  # service_install_unit also ensures the user; stub the lookup so it is a no-op.
  make_output_stub getent "ss-easy:x:998:998::/nonexistent:/usr/sbin/nologin" 0
  run run_env "$STUB_DIR" "service_install_unit"
  [ "$status" -eq 0 ]
  grep -q 'systemctl daemon-reload' "$LOG"
  [ -f "$SS_UNIT_FILE" ]
}

@test "unit file is written with 0644 perms" {
  run run_env "$STUB_DIR" "service_write_unit"
  [ "$status" -eq 0 ]
  [ "$(stat -c '%a' "$SS_UNIT_FILE")" = "644" ]
}

# --- service user creation -------------------------------------------------

@test "service_user_creation_idempotent" {
  # getent succeeds -> user already exists -> useradd must NOT be called.
  make_output_stub getent "ss-easy:x:998:998::/nonexistent:/usr/sbin/nologin" 0
  make_logging_stub useradd
  run run_env "$STUB_DIR" "service_ensure_user"
  [ "$status" -eq 0 ]
  [ ! -f "$LOG" ] || ! grep -q 'useradd' "$LOG"
}

@test "service_ensure_user creates a system account without shell or home" {
  # getent fails -> user absent -> useradd called as a system, no-home, nologin.
  make_output_stub getent "" 2
  make_logging_stub useradd
  run run_env "$STUB_DIR" "service_ensure_user"
  [ "$status" -eq 0 ]
  line="$(grep 'useradd' "$LOG")"
  [[ "$line" == *"--system"* ]]
  [[ "$line" == *"--no-create-home"* ]]
  [[ "$line" == *"--shell"* ]]
  [[ "$line" == *"ss-easy"* ]]
}

# --- lifecycle: start ------------------------------------------------------

@test "start_success_exit_zero" {
  make_logging_stub systemctl 0
  run run_env "$STUB_DIR" "service_start"
  [ "$status" -eq 0 ]
  grep -q 'systemctl start ss-easy.service' "$LOG"
}

@test "start_failure_exit_nonzero" {
  make_logging_stub systemctl 1
  run run_env "$STUB_DIR" "service_start"
  [ "$status" -ne 0 ]
  # Error message is actionable (mentions journalctl).
  [[ "$output" == *"journalctl"* ]]
}

# --- lifecycle: stop / restart --------------------------------------------

@test "stop invokes systemctl stop" {
  make_logging_stub systemctl 0
  run run_env "$STUB_DIR" "service_stop"
  [ "$status" -eq 0 ]
  grep -q 'systemctl stop ss-easy.service' "$LOG"
}

@test "restart invokes systemctl restart" {
  make_logging_stub systemctl 0
  run run_env "$STUB_DIR" "service_restart"
  [ "$status" -eq 0 ]
  grep -q 'systemctl restart ss-easy.service' "$LOG"
}

# --- lifecycle: reload -----------------------------------------------------

@test "reload_after_config_regen" {
  make_logging_stub systemctl 0
  run run_env "$STUB_DIR" "service_reload"
  [ "$status" -eq 0 ]
  # reload-or-restart re-reads config without a full downtime.
  grep -q 'systemctl reload-or-restart ss-easy.service' "$LOG"
}

# --- lifecycle: enable / disable ------------------------------------------

@test "enable_disable_invoke_systemctl" {
  make_logging_stub systemctl 0
  run run_env "$STUB_DIR" "service_enable"
  [ "$status" -eq 0 ]
  grep -q 'systemctl enable ss-easy.service' "$LOG"

  : > "$LOG"
  run run_env "$STUB_DIR" "service_disable"
  [ "$status" -eq 0 ]
  grep -q 'systemctl disable ss-easy.service' "$LOG"
}

# --- status ----------------------------------------------------------------

@test "status_active_reports_listening_ports" {
  # systemctl is-active -> "active"; config carries one server port.
  cat > "$STUB_DIR/systemctl" <<EOF
#!$(command -v bash)
if [ "\$1" = "is-active" ]; then echo active; exit 0; fi
exit 0
EOF
  chmod +x "$STUB_DIR/systemctl"
  mkdir -p "$SS_EASY_ETC"
  printf '%s\n' '{"servers":[{"server":"0.0.0.0","server_port":18342,"password":"x","method":"m","mode":"tcp_and_udp"}]}' > "$SS_EASY_CONFIG"
  run run_env "$STUB_DIR" "service_status"
  [ "$status" -eq 0 ]
  [[ "$output" == *"active"* ]]
  # Listening port derived from config (no ss needed).
  [[ "$output" == *"18342"* ]]
}

@test "status_inactive_exit_nonzero" {
  make_output_stub systemctl "inactive" 3
  run run_env "$STUB_DIR" "service_status"
  [ "$status" -ne 0 ]
  [[ "$output" == *"inactive"* ]]
}

# --- no systemctl available ------------------------------------------------

@test "start without systemctl in PATH dies actionably" {
  # Pure PATH = only the empty stub dir, so systemctl is genuinely absent
  # regardless of whether the host has it (robust on systemd dev machines/CI).
  run run_env "$TMPDIR_TEST/empty" "service_start" pure
  [ "$status" -ne 0 ]
  [[ "$output" == *"systemctl"* ]]
}
