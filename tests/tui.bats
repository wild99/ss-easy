#!/usr/bin/env bats
#
# Unit tests for lib/tui.sh — the whiptail presentation layer.
#
# Nothing here renders a real dialog: `whiptail` is replaced by a PATH stub that
# returns canned selections on the file descriptor the FD-swap expects (stderr,
# i.e. FD 3 after `3>&1 1>&2 2>&3`), so the menu-reading code path is exercised
# deterministically. The lib functions the TUI dispatches to (users_*, service_*,
# config_*, do_uninstall) are replaced by shell-function stubs that log their
# call + arguments to a file, so we assert routing and forwarded arguments rather
# than pixels. The suite runs unprivileged, without whiptail or systemd.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  COMMON="$REPO_ROOT/lib/common.sh"
  TUI="$REPO_ROOT/lib/tui.sh"
  TMPDIR_TEST="$(mktemp -d)"
  STUB_DIR="$TMPDIR_TEST/bin"
  mkdir -p "$STUB_DIR"
  LOG="$TMPDIR_TEST/calls.log"
  : > "$LOG"
}

teardown() {
  [ -n "${TMPDIR_TEST:-}" ] && rm -rf "$TMPDIR_TEST"
}

# Install a `whiptail` PATH stub that, on the Nth invocation, emits the Nth
# scripted value on STDERR (where the FD-swap routes the captured selection) and
# exits with the Nth scripted return code. The scripts are read from a queue file
# so multi-dialog flows replay in order. A line "<rc>|<value>" per invocation.
#
# We log each whiptail invocation to $LOG too, so menu titles/options are
# assertable. Format logged: "whiptail <all-args>".
make_whiptail_stub() {
  local sh queue
  sh="$(command -v bash)"
  queue="$TMPDIR_TEST/wt.queue"
  : > "$queue"
  local item
  for item in "$@"; do
    printf '%s\n' "$item" >> "$queue"
  done
  cat > "$STUB_DIR/whiptail" <<EOF
#!$sh
printf 'whiptail %s\n' "\$*" >> "$LOG"
state="$TMPDIR_TEST/wt.state"
n=0
[ -f "\$state" ] && n="\$(cat "\$state")"
n=\$((n + 1))
printf '%s' "\$n" > "\$state"
total="\$(wc -l < "$queue")"
# Queue exhausted -> behave like a cancel (rc 1) so no flow loops forever.
if [ "\$n" -gt "\$total" ]; then
  exit 1
fi
line="\$(sed -n "\${n}p" "$queue")"
rc="\${line%%|*}"
val="\${line#*|}"
# Mimic real whiptail: the selected value goes to STDERR, not stdout.
[ -n "\$val" ] && printf '%s' "\$val" >&2
exit "\${rc:-0}"
EOF
  chmod +x "$STUB_DIR/whiptail"
}

# Run tui_main in a fresh bash under errexit, with:
#   - the stub PATH ahead of the real one (so whiptail = our stub),
#   - common+tui sourced,
#   - lib functions replaced by logging shell-function stubs.
# $1 = extra shell snippet defining stub functions / overrides (may be empty).
run_tui() {
  local overrides="$1"
  run bash -c "
    set -euo pipefail
    PATH='$STUB_DIR:$PATH'
    source '$COMMON'
    source '$TUI'
    LOG='$LOG'
    # Default no-op stubs; tests override per-case via \$overrides.
    users_add()  { printf 'users_add %s\n'  \"\$*\" >> \"\$LOG\"; printf 'ss://STUB#%s\n' \"\$1\"; }
    users_del()  { printf 'users_del %s\n'  \"\$*\" >> \"\$LOG\"; }
    users_list() { printf 'users_list %s\n' \"\$*\" >> \"\$LOG\"; }
    users_show() { printf 'users_show %s\n' \"\$*\" >> \"\$LOG\"; printf 'link   : ss://STUB#%s\n' \"\$1\"; }
    service_start()   { printf 'service_start\n'   >> \"\$LOG\"; }
    service_stop()    { printf 'service_stop\n'    >> \"\$LOG\"; }
    service_restart() { printf 'service_restart\n' >> \"\$LOG\"; }
    service_status()  { printf 'service_status\n'  >> \"\$LOG\"; }
    service_enable()  { printf 'service_enable\n'  >> \"\$LOG\"; }
    service_disable() { printf 'service_disable\n' >> \"\$LOG\"; }
    config_list_names()         { printf 'config_list_names\n' >> \"\$LOG\"; printf '%s\n' \"\${TEST_USERS:-}\"; }
    config_get_server_address() { printf '203.0.113.7\n'; }
    link_render_qr() { printf 'link_render_qr %s\n' \"\$*\" >> \"\$LOG\"; printf 'QR\n'; }
    do_uninstall()  { printf 'do_uninstall\n' >> \"\$LOG\"; }
    $overrides
    tui_main
  "
}

# --- whiptail absence ------------------------------------------------------

@test "whiptail-absent path gives a clear, actionable message and exits non-zero" {
  # No whiptail in PATH: empty stub dir only.
  run bash -c "
    set -euo pipefail
    PATH='$TMPDIR_TEST/empty'
    source '$COMMON'
    source '$TUI'
    tui_main
  "
  [ "$status" -ne 0 ]
  [[ "$output" == *"whiptail"* ]]
}

# --- sourcing has no side effects ------------------------------------------

@test "sourcing tui.sh has no side effects (no output, exit 0)" {
  run bash -c "source '$COMMON'; source '$TUI'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- main menu routing -----------------------------------------------------

@test "main menu routes 'Users' to the users submenu, then both menus cancel" {
  # 1: main menu -> select "users"; 2: users submenu -> cancel (rc 1); back at
  # main; 3: main menu -> cancel -> exit 0.
  make_whiptail_stub "0|users" "1|" "1|"
  run_tui ""
  [ "$status" -eq 0 ]
  # The users submenu must have been rendered (its title/tag appears in args).
  grep -qi 'Users' "$LOG"
}

# --- service routing -------------------------------------------------------

@test "service action invokes the matching service.sh function (restart)" {
  # 1: main -> "service"; 2: service submenu -> "restart"; 3: service submenu
  # -> cancel (back to main); 4: main -> cancel -> exit.
  make_whiptail_stub "0|service" "0|restart" "1|" "1|"
  run_tui ""
  [ "$status" -eq 0 ]
  grep -q '^service_restart$' "$LOG"
}

@test "service status action invokes service_status" {
  make_whiptail_stub "0|service" "0|status" "1|" "1|"
  run_tui ""
  [ "$status" -eq 0 ]
  grep -q '^service_status$' "$LOG"
}

# --- add user --------------------------------------------------------------

@test "add user passes the entered name to users_add and shows link + QR" {
  # 1: main -> "users"; 2: users -> "add"; 3: inputbox -> name "alice";
  # 4: msgbox (link/QR) acknowledged; 5: users -> cancel; 6: main -> cancel.
  make_whiptail_stub "0|users" "0|add" "0|alice" "0|" "1|" "1|"
  run_tui ""
  [ "$status" -eq 0 ]
  # Name forwarded verbatim.
  grep -q '^users_add alice$' "$LOG"
  # QR rendered for the produced link.
  grep -q '^link_render_qr ' "$LOG"
}

@test "add user: cancelling the inputbox does not call users_add" {
  # 1: main -> "users"; 2: users -> "add"; 3: inputbox CANCELLED (rc 1);
  # 4: users -> cancel; 5: main -> cancel.
  make_whiptail_stub "0|users" "0|add" "1|" "1|" "1|"
  run_tui ""
  [ "$status" -eq 0 ]
  ! grep -q '^users_add' "$LOG"
}

# --- delete user -----------------------------------------------------------

@test "delete user lists existing users and calls delete with the chosen name" {
  # 1: main -> "users"; 2: users -> "del"; 3: pick "bob" from the list;
  # 4: yesno confirm (rc 0); 5: msgbox ack; 6: users -> cancel; 7: main cancel.
  make_whiptail_stub "0|users" "0|del" "0|bob" "0|" "0|" "1|" "1|"
  run_tui 'TEST_USERS=$(printf "alice\nbob\ncarol")'
  [ "$status" -eq 0 ]
  grep -q '^users_del bob$' "$LOG"
}

@test "delete with no users shows a graceful message and does not call delete" {
  # 1: main -> "users"; 2: users -> "del"; (empty registry -> info msgbox);
  # 3: msgbox ack; 4: users -> cancel; 5: main -> cancel.
  make_whiptail_stub "0|users" "0|del" "0|" "1|" "1|"
  run_tui 'TEST_USERS=""'
  [ "$status" -eq 0 ]
  ! grep -q '^users_del' "$LOG"
  # A friendly "no users" message was shown.
  grep -qi 'no users' "$LOG"
}

# --- list / show users -----------------------------------------------------

@test "list users renders the registry in a msgbox" {
  make_whiptail_stub "0|users" "0|list" "0|" "1|" "1|"
  run_tui 'TEST_USERS=$(printf "alice\nbob")'
  [ "$status" -eq 0 ]
  grep -q '^users_list' "$LOG"
}

@test "show user picks from the list and displays link + QR" {
  # 1: main -> users; 2: users -> show; 3: pick "alice"; 4: msgbox ack;
  # 5: users cancel; 6: main cancel.
  make_whiptail_stub "0|users" "0|show" "0|alice" "0|" "1|" "1|"
  run_tui 'TEST_USERS=$(printf "alice\nbob")'
  [ "$status" -eq 0 ]
  grep -q '^users_show alice$' "$LOG"
  grep -q '^link_render_qr ' "$LOG"
}

# --- server info -----------------------------------------------------------

@test "server info shows status and is reachable from the main menu" {
  # 1: main -> "info"; 2: msgbox ack; 3: main -> cancel.
  make_whiptail_stub "0|info" "0|" "1|"
  run_tui 'TEST_USERS=$(printf "alice\nbob")'
  [ "$status" -eq 0 ]
  grep -q '^service_status$' "$LOG"
}

# --- uninstall confirmation ------------------------------------------------

@test "uninstall declining the yesno does NOT call do_uninstall" {
  # 1: main -> "uninstall"; 2: yesno DECLINED (rc 1 = No); 3: main -> cancel.
  make_whiptail_stub "0|uninstall" "1|" "1|"
  run_tui ""
  [ "$status" -eq 0 ]
  ! grep -q '^do_uninstall$' "$LOG"
}

@test "uninstall confirming the yesno calls do_uninstall" {
  # 1: main -> "uninstall"; 2: yesno CONFIRMED (rc 0 = Yes); 3: msgbox ack;
  # 4: main -> cancel.
  make_whiptail_stub "0|uninstall" "0|" "0|" "1|"
  run_tui ""
  [ "$status" -eq 0 ]
  grep -q '^do_uninstall$' "$LOG"
}

# --- cancel / errexit safety -----------------------------------------------

@test "cancel/ESC at main menu exits with code 0" {
  make_whiptail_stub "1|"
  run_tui ""
  [ "$status" -eq 0 ]
}

@test "error from a lib function is surfaced in a msgbox and does not crash" {
  # users_add fails (e.g. duplicate name). Under errexit this must NOT abort the
  # TUI; the error is shown and control returns to the menu, which then cancels.
  # 1: main -> users; 2: users -> add; 3: inputbox name "dup"; 4: error msgbox
  # ack; 5: users -> cancel; 6: main -> cancel.
  make_whiptail_stub "0|users" "0|add" "0|dup" "0|" "1|" "1|"
  run_tui 'users_add() { printf "users_add %s\n" "$*" >> "$LOG"; echo "user already exists: dup" >&2; return 1; }'
  [ "$status" -eq 0 ]
  # users_add was attempted...
  grep -q '^users_add dup$' "$LOG"
  # ...and an error msgbox was rendered carrying the failure text.
  grep -qi 'already exists' "$LOG"
}
