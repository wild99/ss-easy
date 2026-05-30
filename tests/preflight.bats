#!/usr/bin/env bats
#
# Unit tests for lib/preflight.sh — environment checks run before install.
# Every external command (systemctl, curl, ss) and /etc/os-release is mocked,
# so the suite runs without root, without systemd and without network.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  PREFLIGHT="$REPO_ROOT/lib/preflight.sh"
  COMMON="$REPO_ROOT/lib/common.sh"
  TMPDIR_TEST="$(mktemp -d)"
  STUB_DIR="$TMPDIR_TEST/bin"
  mkdir -p "$STUB_DIR"
}

teardown() {
  [ -n "${TMPDIR_TEST:-}" ] && rm -rf "$TMPDIR_TEST"
}

# Write an os-release fixture and echo its path.
make_os_release() {
  local f="$TMPDIR_TEST/os-release"
  printf '%s\n' "$@" > "$f"
  printf '%s' "$f"
}

# Drop an executable stub named $1 into the PATH-shadowing dir; body is $2.
make_stub() {
  local name="$1" body="$2" sh
  sh="$(command -v bash)"
  printf '#!%s\n%s\n' "$sh" "$body" > "$STUB_DIR/$name"
  chmod +x "$STUB_DIR/$name"
}

# --- sourcing has no side effects ------------------------------------------

@test "sourcing preflight.sh has no side effects (no output, exit 0)" {
  run bash -c "source '$PREFLIGHT'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- root -------------------------------------------------------------------

@test "not_root_rejected: pf_require_root fails for non-root mentioning sudo" {
  if [ "$(id -u)" -eq 0 ]; then skip "running as root"; fi
  run bash -c "source '$PREFLIGHT'; pf_require_root"
  [ "$status" -ne 0 ]
  [[ "$output" == *"sudo"* ]]
}

# --- distro detection -------------------------------------------------------

@test "detect_debian: ID=debian -> family deb" {
  f="$(make_os_release 'ID=debian' 'VERSION_ID="12"')"
  run bash -c "source '$PREFLIGHT'; OS_RELEASE='$f' pf_detect_distro; printf '%s' \"\$SS_DISTRO_FAMILY\""
  [ "$status" -eq 0 ]
  [ "$output" = "deb" ]
}

@test "detect_ubuntu: ID=ubuntu -> family deb" {
  f="$(make_os_release 'ID=ubuntu' 'VERSION_ID="22.04"')"
  run bash -c "source '$PREFLIGHT'; OS_RELEASE='$f' pf_detect_distro; printf '%s' \"\$SS_DISTRO_FAMILY\""
  [ "$status" -eq 0 ]
  [ "$output" = "deb" ]
}

@test "detect_rocky: ID=rocky -> family rhel" {
  f="$(make_os_release 'ID="rocky"' 'VERSION_ID="9.3"')"
  run bash -c "source '$PREFLIGHT'; OS_RELEASE='$f' pf_detect_distro; printf '%s' \"\$SS_DISTRO_FAMILY\""
  [ "$status" -eq 0 ]
  [ "$output" = "rhel" ]
}

@test "detect_alma: ID=almalinux -> family rhel" {
  f="$(make_os_release 'ID=almalinux' 'VERSION_ID="9.3"')"
  run bash -c "source '$PREFLIGHT'; OS_RELEASE='$f' pf_detect_distro; printf '%s' \"\$SS_DISTRO_FAMILY\""
  [ "$status" -eq 0 ]
  [ "$output" = "rhel" ]
}

@test "detect_centos: ID=centos -> family rhel" {
  f="$(make_os_release 'ID="centos"' 'VERSION_ID="9"')"
  run bash -c "source '$PREFLIGHT'; OS_RELEASE='$f' pf_detect_distro; printf '%s' \"\$SS_DISTRO_FAMILY\""
  [ "$status" -eq 0 ]
  [ "$output" = "rhel" ]
}

@test "detect_distro exports the lowercased ID" {
  f="$(make_os_release 'ID=Ubuntu')"
  run bash -c "source '$PREFLIGHT'; OS_RELEASE='$f' pf_detect_distro; printf '%s' \"\$SS_DISTRO_ID\""
  [ "$status" -eq 0 ]
  [ "$output" = "ubuntu" ]
}

@test "detect via ID_LIKE fallback: unknown ID, ID_LIKE=debian -> deb" {
  f="$(make_os_release 'ID=raspbian' 'ID_LIKE=debian')"
  run bash -c "source '$PREFLIGHT'; OS_RELEASE='$f' pf_detect_distro; printf '%s' \"\$SS_DISTRO_FAMILY\""
  [ "$status" -eq 0 ]
  [ "$output" = "deb" ]
}

@test "detect via ID_LIKE fallback: unknown ID, ID_LIKE rhel/fedora -> rhel" {
  f="$(make_os_release 'ID=ol' 'ID_LIKE="rhel fedora"')"
  run bash -c "source '$PREFLIGHT'; OS_RELEASE='$f' pf_detect_distro; printf '%s' \"\$SS_DISTRO_FAMILY\""
  [ "$status" -eq 0 ]
  [ "$output" = "rhel" ]
}

@test "detect_unsupported: ID=arch -> non-zero listing supported distros" {
  f="$(make_os_release 'ID=arch')"
  run bash -c "source '$PREFLIGHT'; OS_RELEASE='$f' pf_detect_distro"
  [ "$status" -ne 0 ]
  [[ "$output" == *"debian"* ]]
  [[ "$output" == *"rocky"* ]]
}

@test "detect_unsupported: missing os-release file -> non-zero actionable" {
  run bash -c "source '$PREFLIGHT'; OS_RELEASE='$TMPDIR_TEST/nope' pf_detect_distro"
  [ "$status" -ne 0 ]
  [[ "$output" == *"os-release"* ]]
}

@test "detect does not execute injected os-release content" {
  f="$(make_os_release 'ID=debian' 'EVIL=$(touch '"$TMPDIR_TEST"'/pwned)')"
  run bash -c "source '$PREFLIGHT'; OS_RELEASE='$f' pf_detect_distro"
  [ "$status" -eq 0 ]
  [ ! -e "$TMPDIR_TEST/pwned" ]
}

# --- systemd ----------------------------------------------------------------

@test "systemd present: systemctl available and marker dir exists -> 0" {
  make_stub systemctl 'exit 0'
  marker="$TMPDIR_TEST/run-systemd"
  mkdir -p "$marker"
  run bash -c "PATH=\"$STUB_DIR:\$PATH\"; source '$PREFLIGHT'; SYSTEMD_MARKER='$marker' pf_require_systemd"
  [ "$status" -eq 0 ]
}

@test "systemd_absent: no systemctl in PATH -> non-zero actionable" {
  run bash -c "PATH='$STUB_DIR'; source '$PREFLIGHT'; SYSTEMD_MARKER='$TMPDIR_TEST/none' pf_require_systemd"
  [ "$status" -ne 0 ]
  [[ "$output" == *"systemd"* ]]
}

@test "systemd_absent: marker dir missing -> non-zero" {
  make_stub systemctl 'exit 0'
  run bash -c "PATH=\"$STUB_DIR:\$PATH\"; source '$PREFLIGHT'; SYSTEMD_MARKER='$TMPDIR_TEST/none' pf_require_systemd"
  [ "$status" -ne 0 ]
  [[ "$output" == *"systemd"* ]]
}

# --- network ----------------------------------------------------------------

@test "network reachable: curl stub succeeds -> 0" {
  make_stub curl 'exit 0'
  run bash -c "PATH=\"$STUB_DIR:\$PATH\"; source '$PREFLIGHT'; pf_check_network"
  [ "$status" -eq 0 ]
}

@test "network_unreachable: curl stub fails -> non-zero with internet hint" {
  make_stub curl 'exit 7'
  run bash -c "PATH=\"$STUB_DIR:\$PATH\"; source '$PREFLIGHT'; pf_check_network"
  [ "$status" -ne 0 ]
  [[ "$output" == *"internet"* || "$output" == *"network"* ]]
}

# --- port -------------------------------------------------------------------

@test "port_free: ss reports nothing listening -> 0" {
  make_stub ss 'exit 0'   # empty stdout => nothing on the port
  run bash -c "PATH=\"$STUB_DIR:\$PATH\"; source '$PREFLIGHT'; pf_port_free 8388"
  [ "$status" -eq 0 ]
}

@test "port_busy: ss reports a listener -> non-zero mentioning the port" {
  make_stub ss 'echo "LISTEN 0 4096 0.0.0.0:8388 0.0.0.0:*"'
  run bash -c "PATH=\"$STUB_DIR:\$PATH\"; source '$PREFLIGHT'; pf_port_free 8388"
  [ "$status" -ne 0 ]
  [[ "$output" == *"8388"* ]]
}

@test "port_free does not false-positive on a different port substring" {
  # A listener on :18388 must not be read as :8388.
  make_stub ss 'echo "LISTEN 0 4096 0.0.0.0:18388 0.0.0.0:*"'
  run bash -c "PATH=\"$STUB_DIR:\$PATH\"; source '$PREFLIGHT'; pf_port_free 8388"
  [ "$status" -eq 0 ]
}

@test "pf_port_free rejects a non-numeric port" {
  run bash -c "source '$PREFLIGHT'; pf_port_free abc"
  [ "$status" -ne 0 ]
}
