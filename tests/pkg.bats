#!/usr/bin/env bats
#
# Unit tests for lib/pkg.sh — package-manager abstraction.
# apt-get / dnf / yum are mocked as PATH stubs that log their args; no package
# is ever really installed and no network is touched.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  PKG="$REPO_ROOT/lib/pkg.sh"
  TMPDIR_TEST="$(mktemp -d)"
  STUB_DIR="$TMPDIR_TEST/bin"
  mkdir -p "$STUB_DIR"
  LOG="$TMPDIR_TEST/calls.log"
}

teardown() {
  [ -n "${TMPDIR_TEST:-}" ] && rm -rf "$TMPDIR_TEST"
}

# Stub $1 that appends "name <args>" to $LOG and exits 0. The shebang points at
# an absolute bash so the stub still executes under a restricted (stub-only)
# PATH, where `/usr/bin/env bash` could not locate an interpreter.
make_logging_stub() {
  local name="$1" sh
  sh="$(command -v bash)"
  printf '#!%s\nprintf "%%s %%s\\n" "%s" "$*" >> "%s"\nexit 0\n' \
    "$sh" "$name" "$LOG" > "$STUB_DIR/$name"
  chmod +x "$STUB_DIR/$name"
}

# --- sourcing has no side effects ------------------------------------------

@test "sourcing pkg.sh has no side effects (no output, exit 0)" {
  run bash -c "source '$PKG'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- detect -----------------------------------------------------------------

@test "detect_apt: deb family -> apt-get" {
  make_logging_stub apt-get
  run bash -c "PATH=\"$STUB_DIR:\$PATH\"; source '$PKG'; SS_DISTRO_FAMILY=deb pkg_detect_manager"
  [ "$status" -eq 0 ]
  [ "$output" = "apt-get" ]
}

@test "detect_dnf: rhel family with dnf present -> dnf" {
  make_logging_stub dnf
  run bash -c "PATH=\"$STUB_DIR:\$PATH\"; source '$PKG'; SS_DISTRO_FAMILY=rhel pkg_detect_manager"
  [ "$status" -eq 0 ]
  [ "$output" = "dnf" ]
}

@test "detect yum: rhel family, only yum present -> yum" {
  make_logging_stub yum
  run bash -c "PATH='$STUB_DIR'; source '$PKG'; SS_DISTRO_FAMILY=rhel pkg_detect_manager"
  [ "$status" -eq 0 ]
  [ "$output" = "yum" ]
}

@test "detect falls back to PATH binary when family is unset" {
  make_logging_stub apt-get
  run bash -c "PATH='$STUB_DIR'; source '$PKG'; pkg_detect_manager"
  [ "$status" -eq 0 ]
  [ "$output" = "apt-get" ]
}

@test "detect_unknown_dies: no manager in PATH -> non-zero die" {
  run bash -c "PATH='$STUB_DIR'; source '$PKG'; pkg_detect_manager"
  [ "$status" -ne 0 ]
}

# --- install ----------------------------------------------------------------

@test "install_apt_invocation: apt-get install -y with all packages" {
  make_logging_stub apt-get
  run bash -c "PATH=\"$STUB_DIR:\$PATH\"; source '$PKG'; SS_DISTRO_FAMILY=deb pkg_install whiptail qrencode curl jq"
  [ "$status" -eq 0 ]
  grep -q 'apt-get update' "$LOG"
  line="$(grep 'install -y' "$LOG")"
  [[ "$line" == *"whiptail"* ]]
  [[ "$line" == *"qrencode"* ]]
  [[ "$line" == *"curl"* ]]
  [[ "$line" == *"jq"* ]]
}

@test "install_apt runs apt-get update exactly once across one install call" {
  make_logging_stub apt-get
  run bash -c "PATH=\"$STUB_DIR:\$PATH\"; source '$PKG'; SS_DISTRO_FAMILY=deb pkg_install whiptail jq"
  [ "$status" -eq 0 ]
  count="$(grep -c 'apt-get update' "$LOG")"
  [ "$count" -eq 1 ]
}

@test "install_dnf_invocation: dnf install -y with all packages" {
  make_logging_stub dnf
  run bash -c "PATH=\"$STUB_DIR:\$PATH\"; source '$PKG'; SS_DISTRO_FAMILY=rhel pkg_install whiptail qrencode curl jq"
  [ "$status" -eq 0 ]
  line="$(grep 'install -y' "$LOG")"
  [[ "$line" == *"dnf"* ]]
  [[ "$line" == *"whiptail"* ]]
  [[ "$line" == *"qrencode"* ]]
  [[ "$line" == *"curl"* ]]
  [[ "$line" == *"jq"* ]]
}

@test "install via yum when dnf absent" {
  make_logging_stub yum
  run bash -c "PATH='$STUB_DIR'; source '$PKG'; SS_DISTRO_FAMILY=rhel pkg_install jq"
  [ "$status" -eq 0 ]
  line="$(grep 'install -y' "$LOG")"
  [[ "$line" == *"yum"* ]]
  [[ "$line" == *"jq"* ]]
}

@test "install with no packages is a no-op success" {
  make_logging_stub apt-get
  run bash -c "PATH=\"$STUB_DIR:\$PATH\"; source '$PKG'; SS_DISTRO_FAMILY=deb pkg_install"
  [ "$status" -eq 0 ]
}

# --- ensure runtime deps ----------------------------------------------------

@test "ensure_runtime_deps: passes exactly whiptail qrencode curl jq (apt)" {
  make_logging_stub apt-get
  run bash -c "PATH=\"$STUB_DIR:\$PATH\"; source '$PKG'; SS_DISTRO_FAMILY=deb pkg_ensure_runtime_deps"
  [ "$status" -eq 0 ]
  line="$(grep 'install -y' "$LOG")"
  # Exactly the four deps after 'install -y'.
  pkgs="${line#*install -y }"
  [ "$pkgs" = "whiptail qrencode curl jq" ]
}

@test "ensure_runtime_deps: same four packages on rhel (dnf)" {
  make_logging_stub dnf
  run bash -c "PATH=\"$STUB_DIR:\$PATH\"; source '$PKG'; SS_DISTRO_FAMILY=rhel pkg_ensure_runtime_deps"
  [ "$status" -eq 0 ]
  line="$(grep 'install -y' "$LOG")"
  pkgs="${line#*install -y }"
  [ "$pkgs" = "whiptail qrencode curl jq" ]
}
