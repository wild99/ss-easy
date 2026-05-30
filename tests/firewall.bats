#!/usr/bin/env bats
#
# Unit tests for lib/firewall.sh — the ufw/firewalld abstraction and BBR.
#
# Every backend binary (ufw, firewall-cmd) is mocked with a PATH stub that logs
# its own "$@" to $CALLS so the assertions are a plain grep over the call log.
# The central invariants are NEGATIVE: prove that no function ever emits a
# command touching the SSH rule (port 22 / service ssh) or enabling a firewall
# from scratch. BBR kernel-capability probing reads /proc, not a binary, so it
# cannot be PATH-stubbed: the two checks are isolated in internal functions that
# each test overrides to simulate support per component independently.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  FIREWALL="$REPO_ROOT/lib/firewall.sh"
  TMPDIR_TEST="$(mktemp -d)"
  STUB_DIR="$TMPDIR_TEST/bin"
  mkdir -p "$STUB_DIR"
  CALLS="$TMPDIR_TEST/calls.log"
  : > "$CALLS"
  # Where the module writes the persistent sysctl drop-in (overridable).
  SYSCTL_DIR="$TMPDIR_TEST/sysctl.d"
  mkdir -p "$SYSCTL_DIR"
}

teardown() {
  [ -n "${TMPDIR_TEST:-}" ] && rm -rf "$TMPDIR_TEST"
}

# Drop an executable stub named $1 into the PATH-shadowing dir. The body $2 runs
# after the call has already been logged to $CALLS, so it only sets exit status.
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

# Run a snippet with the stub dir prepended to PATH and the module sourced.
fw() {
  run bash -c "PATH=\"$STUB_DIR:\$PATH\"; CALLS='$CALLS' SYSCTL_DIR='$SYSCTL_DIR'; export CALLS SYSCTL_DIR; source '$FIREWALL'; $1"
}

# Same as fw(), but with a minimal PATH that excludes the system sbin dirs where
# a real `ufw` lives. This forces firewall_detect_backend down the firewalld
# branch on hosts that happen to ship ufw, so the firewalld behaviour is what is
# actually exercised. Only the firewall-cmd stub is reachable as a "firewall".
fw_isolated() {
  run bash -c "PATH=\"$STUB_DIR:/usr/bin:/bin\"; CALLS='$CALLS' SYSCTL_DIR='$SYSCTL_DIR'; export CALLS SYSCTL_DIR; source '$FIREWALL'; $1"
}

# --- sourcing has no side effects ------------------------------------------

@test "sourcing firewall.sh has no side effects (no output, exit 0)" {
  run bash -c "source '$FIREWALL'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- backend detection ------------------------------------------------------

@test "ufw_backend_selected_when_ufw_present" {
  make_stub ufw 'exit 0'
  fw 'firewall_detect_backend; printf "%s" "$REPLY"'
  [ "$status" -eq 0 ]
  [ "$output" = "ufw" ]
}

@test "firewalld_backend_selected_when_firewall_cmd_present" {
  make_stub firewall-cmd 'exit 0'
  fw_isolated 'firewall_detect_backend; printf "%s" "$REPLY"'
  [ "$status" -eq 0 ]
  [ "$output" = "firewalld" ]
}

@test "no backend present -> soft skip with warning, exit 0" {
  fw 'firewall_open_port 9000 tcp'
  [ "$status" -eq 0 ]
  [[ "$output" == *"firewall"* ]]
  [ ! -s "$CALLS" ]
}

# --- ufw: open / close touch only the user port -----------------------------

@test "open_port_touches_only_user_port" {
  # status verb prints an active banner; rule verb is a no-op (logged anyway).
  make_stub ufw 'case "$1" in status) echo "Status: active";; esac; exit 0'
  fw 'firewall_open_port 9000 tcp'
  [ "$status" -eq 0 ]
  grep -q '9000' "$CALLS"
  ! grep -q '22' "$CALLS"
}

@test "close_port_removes_only_that_port" {
  make_stub ufw 'case "$1" in status) echo "Status: active";; esac; exit 0'
  fw 'firewall_close_port 9000 tcp'
  [ "$status" -eq 0 ]
  grep -q 'delete' "$CALLS"
  grep -q '9000' "$CALLS"
  ! grep -q '8000' "$CALLS"
}

# --- the SSH-safety invariant (negative proofs) -----------------------------

@test "never_touches_ssh_rule (ufw, open + close)" {
  make_stub ufw 'case "$1" in status) echo "Status: active";; esac; exit 0'
  fw 'firewall_open_port 9000 tcp; firewall_close_port 9000 tcp'
  [ "$status" -eq 0 ]
  # No SSH port, no ssh service, no whole-firewall enable/disable/reset.
  ! grep -Eq '(^| )22( |$)|ssh|enable|disable|reset' "$CALLS"
}

@test "never_touches_ssh_rule (firewalld, open + close)" {
  make_stub firewall-cmd 'case "$1" in --state) echo running; exit 0;; esac; exit 0'
  fw_isolated 'firewall_open_port 9000 tcp; firewall_close_port 9000 tcp'
  [ "$status" -eq 0 ]
  ! grep -Eq '(^| )22( |$)|ssh|--add-service|--remove-service|--state.*enable' "$CALLS"
}

@test "never_enables_firewall_from_scratch (ufw inactive -> warn, skip, exit 0)" {
  make_stub ufw 'case "$1" in status) echo "Status: inactive";; esac; exit 0'
  fw 'firewall_open_port 9000 tcp'
  [ "$status" -eq 0 ]
  [[ "$output" == *"inactive"* || "$output" == *"not active"* ]]
  # No enable, and no rule was added either.
  ! grep -q 'enable' "$CALLS"
  ! grep -q 'allow' "$CALLS"
}

@test "never_enables_firewall_from_scratch (firewalld not running -> warn, skip, exit 0)" {
  make_stub firewall-cmd 'case "$1" in --state) echo "not running"; exit 1;; esac; exit 0'
  fw_isolated 'firewall_open_port 9000 tcp'
  [ "$status" -eq 0 ]
  ! grep -q -- '--add-port' "$CALLS"
}

# --- port validation --------------------------------------------------------

@test "open_port_rejects_invalid_port (non-numeric)" {
  make_stub ufw 'case "$1" in status) echo "Status: active";; esac; exit 0'
  fw 'firewall_open_port abc tcp'
  [ "$status" -ne 0 ]
  [ ! -s "$CALLS" ]
}

@test "open_port_rejects_invalid_port (out of range)" {
  make_stub ufw 'case "$1" in status) echo "Status: active";; esac; exit 0'
  fw 'firewall_open_port 70000 tcp'
  [ "$status" -ne 0 ]
  [ ! -s "$CALLS" ]
}

@test "open_port_rejects_invalid_proto" {
  make_stub ufw 'case "$1" in status) echo "Status: active";; esac; exit 0'
  fw 'firewall_open_port 9000 sctp'
  [ "$status" -ne 0 ]
  [ ! -s "$CALLS" ]
}

# --- firewalld: rule must be active now AND survive reboot ------------------

@test "firewalld_open_applies_runtime_and_permanent" {
  make_stub firewall-cmd 'case "$1" in --state) echo running; exit 0;; esac; exit 0'
  fw_isolated 'firewall_open_port 9000 tcp'
  [ "$status" -eq 0 ]
  # Runtime: an --add-port call WITHOUT --permanent.
  grep -E -- '--add-port=9000/tcp' "$CALLS" | grep -qv -- '--permanent'
  # Permanent: an --add-port call WITH --permanent.
  grep -E -- '--add-port=9000/tcp' "$CALLS" | grep -q -- '--permanent'
}

@test "firewalld_close_applies_runtime_and_permanent" {
  make_stub firewall-cmd 'case "$1" in --state) echo running; exit 0;; esac; exit 0'
  fw_isolated 'firewall_close_port 9000 tcp'
  [ "$status" -eq 0 ]
  grep -E -- '--remove-port=9000/tcp' "$CALLS" | grep -qv -- '--permanent'
  grep -E -- '--remove-port=9000/tcp' "$CALLS" | grep -q -- '--permanent'
}

# --- BBR: each capability checked and applied independently -----------------

@test "bbr_enabled_when_kernel_supports" {
  fw '_fw_has_sch_fq() { return 0; }; _fw_has_tcp_bbr() { return 0; }; firewall_enable_bbr'
  [ "$status" -eq 0 ]
  f="$SYSCTL_DIR/99-ss-easy-bbr.conf"
  grep -q 'net.core.default_qdisc=fq' "$f"
  grep -q 'net.ipv4.tcp_congestion_control=bbr' "$f"
}

@test "bbr_skipped_with_warning_when_unsupported" {
  fw '_fw_has_sch_fq() { return 1; }; _fw_has_tcp_bbr() { return 1; }; firewall_enable_bbr'
  [ "$status" -eq 0 ]
  [[ "$output" == *"BBR"* || "$output" == *"bbr"* ]]
  [ ! -e "$SYSCTL_DIR/99-ss-easy-bbr.conf" ]
}

@test "bbr_fq_skipped_when_sch_fq_unavailable" {
  fw '_fw_has_sch_fq() { return 1; }; _fw_has_tcp_bbr() { return 0; }; firewall_enable_bbr'
  [ "$status" -eq 0 ]
  f="$SYSCTL_DIR/99-ss-easy-bbr.conf"
  ! grep -q 'default_qdisc=fq' "$f"
  grep -q 'net.ipv4.tcp_congestion_control=bbr' "$f"
}

@test "bbr_cc_skipped_when_tcp_bbr_unavailable" {
  fw '_fw_has_sch_fq() { return 0; }; _fw_has_tcp_bbr() { return 1; }; firewall_enable_bbr'
  [ "$status" -eq 0 ]
  f="$SYSCTL_DIR/99-ss-easy-bbr.conf"
  grep -q 'net.core.default_qdisc=fq' "$f"
  ! grep -q 'tcp_congestion_control=bbr' "$f"
}

@test "bbr never writes default_qdisc=fq without sch_fq (combined with cc on)" {
  # The most dangerous combination: cc supported, qdisc not. Must NOT write fq.
  fw '_fw_has_sch_fq() { return 1; }; _fw_has_tcp_bbr() { return 0; }; firewall_enable_bbr'
  [ "$status" -eq 0 ]
  ! grep -q 'fq' "$SYSCTL_DIR/99-ss-easy-bbr.conf"
}

@test "bbr is idempotent (re-run does not duplicate lines)" {
  fw '_fw_has_sch_fq() { return 0; }; _fw_has_tcp_bbr() { return 0; }; firewall_enable_bbr; firewall_enable_bbr'
  [ "$status" -eq 0 ]
  f="$SYSCTL_DIR/99-ss-easy-bbr.conf"
  [ "$(grep -c 'default_qdisc=fq' "$f")" -eq 1 ]
  [ "$(grep -c 'tcp_congestion_control=bbr' "$f")" -eq 1 ]
}
