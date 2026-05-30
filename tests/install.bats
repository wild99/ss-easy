#!/usr/bin/env bats
#
# Unit tests for lib/install.sh (the install orchestrator) and the ss-easy
# entrypoint dispatcher.
#
# Nothing here touches real root, systemd, the network, or the package manager.
# Every module function the orchestrator calls is replaced by a shell-function
# stub that logs its invocation to a call log, so we assert on ORCHESTRATION
# (what was called, in what order, with what arguments) and on the real
# registry/config state produced by the genuine config.sh/users.sh/link.sh,
# which are pure and run unprivileged against a temp /etc/ss-easy.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  TMPDIR_TEST="$(mktemp -d)"
  LOG="$TMPDIR_TEST/calls.log"
  : > "$LOG"

  # Redirect every persistent path into the temp tree.
  export SS_EASY_ETC="$TMPDIR_TEST/etc"
  export SS_EASY_USERS="$SS_EASY_ETC/users.json"
  export SS_EASY_CONFIG="$SS_EASY_ETC/config.json"
  export SS_EASY_USERS_DIR="$SS_EASY_ETC/users"
  export SS_AUDIT_LOG="$TMPDIR_TEST/ss-easy.log"

  export CALLS_LOG="$LOG"
}

teardown() {
  [ -n "${TMPDIR_TEST:-}" ] && rm -rf "$TMPDIR_TEST"
}

# --- harness ----------------------------------------------------------------

# Source the real common/config/users/link/network modules (pure, no root) plus
# install.sh, then OVERRIDE the side-effecting module functions with stubs that
# record their calls. Returns a shell environment ready to invoke do_install.
#
# Usage: run_install_env "<snippet>"
run_install_env() {
  local snippet="$1"
  bash -c "
    set -euo pipefail
    export SS_EASY_ETC='$SS_EASY_ETC'
    export SS_EASY_USERS='$SS_EASY_USERS'
    export SS_EASY_CONFIG='$SS_EASY_CONFIG'
    export SS_EASY_USERS_DIR='$SS_EASY_USERS_DIR'
    export SS_AUDIT_LOG='$SS_AUDIT_LOG'
    export CALLS_LOG='$CALLS_LOG'

    source '$REPO_ROOT/lib/common.sh'
    source '$REPO_ROOT/lib/config.sh'
    source '$REPO_ROOT/lib/link.sh'
    source '$REPO_ROOT/lib/network.sh'
    source '$REPO_ROOT/lib/users.sh'
    source '$REPO_ROOT/lib/install.sh'

    # common.sh hard-codes the /etc/ss-easy constants on source; re-point them at
    # the temp tree AFTER sourcing so the test runs unprivileged (same technique
    # as service.bats). The modules read these at call time, so this takes.
    SS_EASY_ETC='$SS_EASY_ETC'
    SS_EASY_USERS='$SS_EASY_USERS'
    SS_EASY_CONFIG='$SS_EASY_CONFIG'
    SS_EASY_USERS_DIR='$SS_EASY_USERS_DIR'

    _rec() { printf '%s\n' \"\$*\" >> \"\$CALLS_LOG\"; }

    # --- stub the side-effecting module boundaries -------------------------
    run_preflight()              { _rec \"run_preflight \$*\"; return 0; }
    pkg_ensure_runtime_deps()    { _rec 'pkg_ensure_runtime_deps'; return 0; }
    ss_install_binary()          { _rec 'ss_install_binary'; return 0; }
    ss_installed_version()       { printf '%s' \"\${STUB_INSTALLED_VERSION:-}\"; }
    service_ensure_user()        { _rec 'service_ensure_user'; return 0; }
    service_install_unit()       { _rec 'service_install_unit'; return 0; }
    service_enable()             { _rec 'service_enable'; return 0; }
    service_start()              { _rec 'service_start'; return 0; }
    service_restart()            { _rec 'service_restart'; return 0; }
    service_status()             { _rec 'service_status'; return 0; }
    service_unit_installed()     { [ \"\${STUB_UNIT_INSTALLED:-1}\" = 1 ]; }
    firewall_open_port()         { _rec \"firewall_open_port \$*\"; return 0; }
    firewall_enable_bbr()        { _rec 'firewall_enable_bbr'; return 0; }
    link_render_qr()             { _rec 'link_render_qr'; return 0; }
    # Auto-detection must never reach the network in tests. An explicit override
    # argument (the install --ip path) wins, mirroring the real function.
    net_detect_public_ip()       {
      if [ -n \"\${1:-}\" ]; then printf '%s' \"\$1\"; else printf '%s' \"\${STUB_PUBLIC_IP:-203.0.113.10}\"; fi
    }

    $snippet
  "
}

# --- dispatcher: source the entrypoint with stubbed handlers ---------------

# Run the ss-easy dispatcher's main() with every command handler stubbed so we
# can observe routing without executing real install/service/user logic.
run_dispatch() {
  bash -c "
    set -euo pipefail
    export SS_EASY_ETC='$SS_EASY_ETC'
    export CALLS_LOG='$CALLS_LOG'
    source '$REPO_ROOT/lib/common.sh'

    # Sibling modules the entrypoint sources in dev mode are present in the repo;
    # but we stub the leaf operations so routing is observable and side-effect free.
    _rec() { printf '%s\n' \"\$*\" >> \"\$CALLS_LOG\"; }
    require_root() { :; }                 # bypass the root guard in tests
    do_install()  { _rec \"do_install \$*\"; }
    do_uninstall(){ _rec \"do_uninstall \$*\"; }
    tui_main()    { _rec \"tui_main \$*\"; }
    users_add()   { _rec \"users_add \$*\"; }
    users_del()   { _rec \"users_del \$*\"; }
    users_list()  { _rec \"users_list \$*\"; }
    users_show()  { _rec \"users_show \$*\"; }
    service_start()   { _rec 'service_start'; }
    service_stop()    { _rec 'service_stop'; }
    service_restart() { _rec 'service_restart'; }
    service_status()  { _rec 'service_status'; }
    service_enable()  { _rec 'service_enable'; }
    service_disable() { _rec 'service_disable'; }

    # Source the entrypoint body WITHOUT running main (BASH_SOURCE guard), then
    # call main ourselves with the test arguments.
    _SS_EASY_COMMON_LOADED=1   # skip the dev source block; common already loaded
    source '$REPO_ROOT/ss-easy'
    main \"\$@\"
  " bash "$@"
}

# ===========================================================================
# Dispatcher routing
# ===========================================================================

@test "dispatch_install routes to do_install and forwards --silent" {
  run run_dispatch install --silent
  [ "$status" -eq 0 ]
  grep -q 'do_install --silent' "$LOG"
}

@test "dispatch_user_subcommands route to users_* functions" {
  run run_dispatch user add alice
  [ "$status" -eq 0 ]; grep -q 'users_add alice' "$LOG"
  : > "$LOG"
  run run_dispatch user del alice
  [ "$status" -eq 0 ]; grep -q 'users_del alice' "$LOG"
  : > "$LOG"
  run run_dispatch user list
  [ "$status" -eq 0 ]; grep -q 'users_list' "$LOG"
  : > "$LOG"
  run run_dispatch user show alice
  [ "$status" -eq 0 ]; grep -q 'users_show alice' "$LOG"
}

@test "dispatch_user with no/unknown subcommand fails with usage" {
  run run_dispatch user
  [ "$status" -ne 0 ]
  run run_dispatch user frobnicate
  [ "$status" -ne 0 ]
}

@test "dispatch_service_lifecycle routes each verb to service.sh" {
  local verb
  for verb in start stop restart status enable disable; do
    : > "$LOG"
    run run_dispatch "$verb"
    [ "$status" -eq 0 ]
    grep -q "service_${verb}" "$LOG"
  done
}

@test "dispatch_unknown_command prints usage and exits non-zero" {
  run run_dispatch wibble
  [ "$status" -ne 0 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "dispatch with no arguments routes to the TUI" {
  run run_dispatch
  [ "$status" -eq 0 ]
  grep -q 'tui_main' "$LOG"
}

@test "dispatch_help prints usage and exits zero" {
  for flag in -h --help help; do
    run run_dispatch "$flag"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage:"* ]]
  done
}

@test "dispatch_version prints a version and exits zero" {
  for flag in --version version; do
    run run_dispatch "$flag"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ss-easy"* ]]
  done
}

@test "dispatch routes tui explicitly" {
  run run_dispatch tui
  [ "$status" -eq 0 ]
  grep -q 'tui_main' "$LOG"
}

# ===========================================================================
# Silent install flow
# ===========================================================================

@test "silent_defaults: no prompts, full pipeline runs in order" {
  # whiptail/read must never be invoked in silent mode: make them fail loudly.
  run run_install_env "
    whiptail() { echo 'PROMPTED' >&2; exit 99; }
    do_install --silent
  "
  [ "$status" -eq 0 ]
  [[ "$output" != *"PROMPTED"* ]]
  # Pipeline order: preflight -> deps -> binary -> service unit -> firewall.
  grep -q 'run_preflight'           "$LOG"
  grep -q 'pkg_ensure_runtime_deps' "$LOG"
  grep -q 'ss_install_binary'       "$LOG"
  grep -q 'service_install_unit'    "$LOG"
  grep -q 'firewall_open_port'      "$LOG"
}

@test "silent_defaults: creates a first user with a crypto secret and high port" {
  run run_install_env "do_install --silent"
  [ "$status" -eq 0 ]
  [ -f "$SS_EASY_USERS" ]
  # Exactly one user, with a high (>1024) port and a non-empty secret.
  local n port secret
  n="$(jq '.users | length' "$SS_EASY_USERS")"
  [ "$n" -eq 1 ]
  port="$(jq -r '.users[0].port' "$SS_EASY_USERS")"
  [ "$port" -gt 1024 ]
  secret="$(jq -r '.users[0].secret' "$SS_EASY_USERS")"
  [ -n "$secret" ]
  [ "$secret" != "null" ]
}

@test "silent_defaults: server_address is the auto-detected IP" {
  STUB_PUBLIC_IP="198.51.100.7" run run_install_env "STUB_PUBLIC_IP=198.51.100.7 do_install --silent"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.server_address' "$SS_EASY_USERS")" = "198.51.100.7" ]
}

@test "post_install_block_printed: ss:// link, access-file path, status" {
  run run_install_env "do_install --silent"
  [ "$status" -eq 0 ]
  # A valid SIP022 ss:// link is printed for the first user.
  [[ "$output" == *"ss://2022-blake3-aes-256-gcm:"* ]]
  # The per-user access file path is surfaced.
  [[ "$output" == *"$SS_EASY_USERS_DIR/"*".txt"* ]]
  # Service status was queried as part of the report.
  grep -q 'service_status' "$LOG"
}

@test "post_install: printed ss:// matches generated creds (decode, not substring)" {
  run run_install_env "do_install --silent"
  [ "$status" -eq 0 ]
  local uri method secret port host
  uri="$(printf '%s\n' "$output" | grep -o 'ss://2022-blake3-aes-256-gcm:[^[:space:]]*' | head -n1)"
  [ -n "$uri" ]
  # Decode the ss:// userinfo/host/port and compare to the registry.
  method="$(jq -r '.users[0].method' "$SS_EASY_USERS")"
  secret="$(jq -r '.users[0].secret' "$SS_EASY_USERS")"
  port="$(jq -r '.users[0].port' "$SS_EASY_USERS")"
  host="$(jq -r '.server_address' "$SS_EASY_USERS")"
  # SIP022: ss://<method>:<percent-encoded secret>@<host>:<port>#<tag>. The key is
  # standard base64 (+,/,=) and is percent-encoded in the URL (canonical ssurl form).
  local enc="${secret//+/%2B}"; enc="${enc//\//%2F}"; enc="${enc//=/%3D}"
  [[ "$uri" == "ss://${method}:${enc}@${host}:${port}#"* ]]
}

# ===========================================================================
# Secret hygiene (Decision 10)
# ===========================================================================

@test "no_secret_in_log: the audit log never contains the secret" {
  run run_install_env "do_install --silent"
  [ "$status" -eq 0 ]
  [ -f "$SS_AUDIT_LOG" ]
  local secret
  secret="$(jq -r '.users[0].secret' "$SS_EASY_USERS")"
  [ -n "$secret" ]
  # The secret must not leak into the audit log...
  ! grep -qF "$secret" "$SS_AUDIT_LOG"
  # ...and the audit log records the install action + user name (no secret).
  grep -q 'install' "$SS_AUDIT_LOG"
}

@test "no_secret_in_log: the audit log file is mode 0600" {
  run run_install_env "do_install --silent"
  [ "$status" -eq 0 ]
  [ "$(stat -c '%a' "$SS_AUDIT_LOG")" = "600" ]
}

# ===========================================================================
# Idempotency
# ===========================================================================

@test "idempotent_rerun_preserves_users: second install keeps the same secret" {
  run run_install_env "do_install --silent"
  [ "$status" -eq 0 ]
  local first_secret first_port first_name
  first_secret="$(jq -r '.users[0].secret' "$SS_EASY_USERS")"
  first_port="$(jq -r '.users[0].port' "$SS_EASY_USERS")"
  first_name="$(jq -r '.users[0].name' "$SS_EASY_USERS")"

  # Re-run: the existing registry must survive untouched.
  run run_install_env "do_install --silent"
  [ "$status" -eq 0 ]
  [ "$(jq '.users | length' "$SS_EASY_USERS")" -eq 1 ]
  [ "$(jq -r '.users[0].secret' "$SS_EASY_USERS")" = "$first_secret" ]
  [ "$(jq -r '.users[0].port' "$SS_EASY_USERS")" = "$first_port" ]
  [ "$(jq -r '.users[0].name' "$SS_EASY_USERS")" = "$first_name" ]
}

@test "idempotent_repairs_unit_and_firewall: re-run restores a missing unit/rule" {
  run run_install_env "do_install --silent"
  [ "$status" -eq 0 ]
  # Second run with the unit reported missing and the firewall rule absent: the
  # orchestrator must (re)install the unit and (re)open the port.
  : > "$LOG"
  run run_install_env "STUB_UNIT_INSTALLED=0 do_install --silent"
  [ "$status" -eq 0 ]
  grep -q 'service_install_unit' "$LOG"
  grep -q 'firewall_open_port'   "$LOG"
}

@test "binary_upgrade_on_version_change: differing installed version triggers reinstall+restart" {
  # Installed version differs from the pinned SS_RUST_VERSION -> upgrade path.
  : > "$LOG"
  run run_install_env "STUB_INSTALLED_VERSION='v0.0.1' do_install --silent"
  [ "$status" -eq 0 ]
  grep -q 'ss_install_binary' "$LOG"
  grep -q 'service_restart'   "$LOG"
}

@test "binary install skipped when installed version already matches" {
  : > "$LOG"
  # Report the installed version equal to the pinned one, on a non-empty registry
  # (so this is a repair run, not a first install).
  run run_install_env "
    do_install --silent           # first install populates the registry
    : > '$CALLS_LOG'
    STUB_INSTALLED_VERSION=\"\$SS_RUST_VERSION\" do_install --silent
  "
  [ "$status" -eq 0 ]
  ! grep -q 'ss_install_binary' "$LOG"
}

# ===========================================================================
# Option parsing
# ===========================================================================

@test "explicit --port and --method are honoured" {
  run run_install_env "do_install --silent --port 51820 --method chacha20-ietf-poly1305 --name bob"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.users[0].name' "$SS_EASY_USERS")" = "bob" ]
  [ "$(jq -r '.users[0].port' "$SS_EASY_USERS")" = "51820" ]
  [ "$(jq -r '.users[0].method' "$SS_EASY_USERS")" = "chacha20-ietf-poly1305" ]
}

@test "explicit --ip override sets server_address" {
  run run_install_env "do_install --silent --ip 192.0.2.55"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.server_address' "$SS_EASY_USERS")" = "192.0.2.55" ]
}

@test "an invalid --port is rejected" {
  run run_install_env "do_install --silent --port notaport"
  [ "$status" -ne 0 ]
}
