#!/usr/bin/env bats
#
# Unit tests for lib/binary.sh — ss-rust binary supply: arch detect, hardened
# download with retries, SHA256 verification, extract + install.
#
# Network, uname, curl, sha256sum and tar are all mocked via PATH stubs or by
# pointing the module at a file:// "release host" served from a temp dir; no real
# network is touched and no real ssserver is fetched.
#
# The SHA256 the installer trusts is the EMBEDDED constant
# _SS_RUST_SHA256_<triple>; make_release computes the real archive hash and
# exports that constant so the self-contained verification path is exercised
# WITHOUT any sibling checksums/ file.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  BINARY="$REPO_ROOT/lib/binary.sh"
  TMPDIR_TEST="$(mktemp -d)"
  STUB_DIR="$TMPDIR_TEST/bin"
  mkdir -p "$STUB_DIR"
  LOG="$TMPDIR_TEST/calls.log"

  # A self-contained checksums dir and a fake release host the tests populate.
  CHK_DIR="$TMPDIR_TEST/checksums"
  HOST_DIR="$TMPDIR_TEST/host"
  INSTALL_DIR="$TMPDIR_TEST/usr-local-bin"
  mkdir -p "$CHK_DIR" "$HOST_DIR" "$INSTALL_DIR"
}

teardown() {
  [ -n "${TMPDIR_TEST:-}" ] && rm -rf "$TMPDIR_TEST"
}

# Stub $1 that appends "name <args>" to $LOG and exits 0.
make_logging_stub() {
  local name="$1" sh
  sh="$(command -v bash)"
  printf '#!%s\nprintf "%%s %%s\\n" "%s" "$*" >> "%s"\nexit 0\n' \
    "$sh" "$name" "$LOG" > "$STUB_DIR/$name"
  chmod +x "$STUB_DIR/$name"
}

# Build a real .tar.xz containing a fake ssserver binary, served from HOST_DIR,
# and emit the bash assignment that pins its EMBEDDED expected hash for the
# given triple. Callers eval the printed assignment inside the install subshell.
# Usage: eval "$(make_release <triple>)"
make_release() {
  local triple="$1"
  local asset="shadowsocks-v1.23.5.${triple}.tar.xz"
  local stage="$TMPDIR_TEST/stage"
  rm -rf "$stage"; mkdir -p "$stage"
  printf '#!/bin/sh\necho "shadowsocks %%s"\n' "v1.23.5" > "$stage/ssserver"
  chmod +x "$stage/ssserver"
  # sslocal/ssservice ship alongside in the real archive; include extras.
  printf '#!/bin/sh\n:\n' > "$stage/sslocal"; chmod +x "$stage/sslocal"
  tar -C "$stage" -cJf "$HOST_DIR/$asset" .
  local sum key
  sum="$(sha256sum "$HOST_DIR/$asset" | awk '{print $1}')"
  key="_SS_RUST_SHA256_${triple//[-.]/_}"
  printf '%s=%s\n' "$key" "$sum"
}

# --- sourcing has no side effects ------------------------------------------

@test "sourcing binary.sh has no side effects (no output, exit 0)" {
  run bash -c "source '$BINARY'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- arch detect ------------------------------------------------------------

@test "detect_arch maps x86_64 to triple" {
  printf '#!/bin/sh\necho x86_64\n' > "$STUB_DIR/uname"; chmod +x "$STUB_DIR/uname"
  run bash -c "PATH=\"$STUB_DIR:\$PATH\"; source '$BINARY'; ss_detect_arch"
  [ "$status" -eq 0 ]
  [ "$output" = "x86_64-unknown-linux-musl" ]
}

@test "detect_arch maps aarch64 to triple" {
  printf '#!/bin/sh\necho aarch64\n' > "$STUB_DIR/uname"; chmod +x "$STUB_DIR/uname"
  run bash -c "PATH=\"$STUB_DIR:\$PATH\"; source '$BINARY'; ss_detect_arch"
  [ "$status" -eq 0 ]
  [ "$output" = "aarch64-unknown-linux-musl" ]
}

@test "detect_arch rejects unknown arch with non-zero and actionable message" {
  printf '#!/bin/sh\necho mips\n' > "$STUB_DIR/uname"; chmod +x "$STUB_DIR/uname"
  run bash -c "PATH=\"$STUB_DIR:\$PATH\"; source '$BINARY'; ss_detect_arch"
  [ "$status" -ne 0 ]
  [[ "$output" == *"mips"* ]]
  [[ "$output" == *"unsupported"* ]] || [[ "$output" == *"not supported"* ]]
}

# --- hardened curl flags ----------------------------------------------------

@test "curl invoked with hardened flags and no -k/--insecure" {
  make_logging_stub curl
  run bash -c "PATH=\"$STUB_DIR:\$PATH\"; source '$BINARY'; ss_download_url 'https://example/x' '$TMPDIR_TEST/out'"
  [ "$status" -eq 0 ]
  line="$(grep '^curl ' "$LOG")"
  [[ "$line" == *"--fail"* ]]
  [[ "$line" == *"--proto =https"* ]]
  [[ "$line" == *"--tlsv1.2"* ]]
  [[ "$line" == *"--location"* ]]
  [[ "$line" != *"-k"* ]]
  [[ "$line" != *"--insecure"* ]]
}

# --- download retries -------------------------------------------------------

@test "download retries then succeeds (fail twice, third ok)" {
  # curl stub fails the first two invocations, succeeds the third.
  cat > "$STUB_DIR/curl" <<EOF
#!$(command -v bash)
n_file="$TMPDIR_TEST/curl.n"
n=\$(cat "\$n_file" 2>/dev/null || echo 0); n=\$((n+1)); echo "\$n" > "\$n_file"
if [ "\$n" -lt 3 ]; then exit 7; fi
# success: write the -o target
out=""; while [ \$# -gt 0 ]; do [ "\$1" = "-o" ] && out="\$2"; shift; done
printf ok > "\$out"; exit 0
EOF
  chmod +x "$STUB_DIR/curl"
  run bash -c "PATH=\"$STUB_DIR:\$PATH\"; source '$BINARY'; SS_DOWNLOAD_BACKOFF_BASE=0 ss_download_url 'https://example/x' '$TMPDIR_TEST/out'"
  [ "$status" -eq 0 ]
  [ -f "$TMPDIR_TEST/out" ]
  [ "$(cat "$TMPDIR_TEST/out")" = "ok" ]
}

@test "download aborts after max retries; no partial file left" {
  # curl always fails (e.g. 404 via --fail -> exit 22).
  cat > "$STUB_DIR/curl" <<EOF
#!$(command -v bash)
out=""; while [ \$# -gt 0 ]; do [ "\$1" = "-o" ] && out="\$2"; shift; done
[ -n "\$out" ] && printf partial > "\$out"
exit 22
EOF
  chmod +x "$STUB_DIR/curl"
  run bash -c "PATH=\"$STUB_DIR:\$PATH\"; source '$BINARY'; SS_DOWNLOAD_BACKOFF_BASE=0 ss_download_url 'https://example/x' '$TMPDIR_TEST/out'"
  [ "$status" -ne 0 ]
  [ ! -e "$TMPDIR_TEST/out" ]
}

# --- full install: success --------------------------------------------------

@test "sha256 match (embedded hash) installs ssserver 0755" {
  printf '#!/bin/sh\necho x86_64\n' > "$STUB_DIR/uname"; chmod +x "$STUB_DIR/uname"
  embed="$(make_release x86_64-unknown-linux-musl)"
  run bash -c "
    PATH=\"$STUB_DIR:\$PATH\"
    source '$BINARY'
    $embed
    SS_SERVER_BIN='$INSTALL_DIR/ssserver'
    SS_RELEASE_BASE_URL='file://$HOST_DIR'
    SS_DOWNLOAD_PROTO='=file'
    SS_DOWNLOAD_BACKOFF_BASE=0
    ss_install_binary
  "
  [ "$status" -eq 0 ]
  [ -x "$INSTALL_DIR/ssserver" ]
  perm="$(stat -c '%a' "$INSTALL_DIR/ssserver")"
  [ "$perm" = "755" ]
}

@test "install is idempotent: overwrites an existing ssserver without error" {
  printf '#!/bin/sh\necho x86_64\n' > "$STUB_DIR/uname"; chmod +x "$STUB_DIR/uname"
  embed="$(make_release x86_64-unknown-linux-musl)"
  printf 'old\n' > "$INSTALL_DIR/ssserver"; chmod 755 "$INSTALL_DIR/ssserver"
  run bash -c "
    PATH=\"$STUB_DIR:\$PATH\"
    source '$BINARY'
    $embed
    SS_SERVER_BIN='$INSTALL_DIR/ssserver'
    SS_RELEASE_BASE_URL='file://$HOST_DIR'
    SS_DOWNLOAD_PROTO='=file'
    SS_DOWNLOAD_BACKOFF_BASE=0
    ss_install_binary
  "
  [ "$status" -eq 0 ]
  [ -x "$INSTALL_DIR/ssserver" ]
  [ "$(cat "$INSTALL_DIR/ssserver")" != "old" ]
}

# --- full install: failure paths -------------------------------------------

@test "sha256 mismatch (tampered) aborts, removes temp, ssserver not installed" {
  printf '#!/bin/sh\necho x86_64\n' > "$STUB_DIR/uname"; chmod +x "$STUB_DIR/uname"
  make_release x86_64-unknown-linux-musl >/dev/null
  # Pin a WRONG embedded hash so the real download cannot match (tamper sim).
  embed="_SS_RUST_SHA256_x86_64_unknown_linux_musl=0000000000000000000000000000000000000000000000000000000000000000"
  run bash -c "
    PATH=\"$STUB_DIR:\$PATH\"
    source '$BINARY'
    $embed
    SS_SERVER_BIN='$INSTALL_DIR/ssserver'
    SS_RELEASE_BASE_URL='file://$HOST_DIR'
    SS_DOWNLOAD_PROTO='=file'
    SS_DOWNLOAD_BACKOFF_BASE=0
    ss_install_binary
  "
  [ "$status" -ne 0 ]
  [ ! -e "$INSTALL_DIR/ssserver" ]
  # No leftover ss-easy temp file/dir in TMPDIR.
  run bash -c "ls -A '$TMPDIR_TEST' | grep -c 'ss-easy' || true"
  [ "$output" = "0" ]
}

@test "truncated archive aborts on extraction; cleanup, ssserver not installed" {
  printf '#!/bin/sh\necho x86_64\n' > "$STUB_DIR/uname"; chmod +x "$STUB_DIR/uname"
  make_release x86_64-unknown-linux-musl >/dev/null
  asset="shadowsocks-v1.23.5.x86_64-unknown-linux-musl.tar.xz"
  # Truncate the served archive AND re-pin the embedded hash to its post-trunc
  # value so download+verify pass but extraction fails on the corrupt tar.
  head -c 32 "$HOST_DIR/$asset" > "$HOST_DIR/$asset.trunc" && mv "$HOST_DIR/$asset.trunc" "$HOST_DIR/$asset"
  newsum="$(sha256sum "$HOST_DIR/$asset" | awk '{print $1}')"
  embed="_SS_RUST_SHA256_x86_64_unknown_linux_musl=$newsum"
  run bash -c "
    PATH=\"$STUB_DIR:\$PATH\"
    source '$BINARY'
    $embed
    SS_SERVER_BIN='$INSTALL_DIR/ssserver'
    SS_RELEASE_BASE_URL='file://$HOST_DIR'
    SS_DOWNLOAD_PROTO='=file'
    SS_DOWNLOAD_BACKOFF_BASE=0
    ss_install_binary
  "
  [ "$status" -ne 0 ]
  [ ! -e "$INSTALL_DIR/ssserver" ]
  run bash -c "ls -A '$TMPDIR_TEST' | grep -c 'ss-easy' || true"
  [ "$output" = "0" ]
}

# --- embedded checksum table ------------------------------------------------

@test "ss_expected_sha256 returns the embedded hash for a known triple" {
  run bash -c "source '$BINARY'; ss_expected_sha256 x86_64-unknown-linux-musl"
  [ "$status" -eq 0 ]
  [ "$output" = "d37e9f6484aced51188ed6c8beea3538be7a73b072259b65a47e91ebf6530dfc" ]
}

@test "ss_expected_sha256 fails (no output) for an unknown triple" {
  run bash -c "source '$BINARY'; ss_expected_sha256 riscv64-unknown-linux-musl"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "embedded checksums stay in sync with checksums/ss-rust.sha256" {
  # The repo file is the human/CI source of truth; build.sh keeps the embedded
  # constants in sync. For every line in the file, the embedded constant for its
  # triple MUST equal the committed hash. Guards against a stale hand edit.
  while read -r sum asset; do
    [ -n "$sum" ] || continue
    # asset: shadowsocks-<version>.<triple>.tar.xz; the version has dots, so match
    # the trailing Rust triple (<cpu>-<vendor>-linux-<libc>) directly.
    base="${asset%.tar.xz}"
    [[ "$base" =~ ([A-Za-z0-9_]+-[A-Za-z0-9_]+-linux-[A-Za-z0-9_]+)$ ]] || { echo "bad asset: $asset"; false; }
    triple="${BASH_REMATCH[1]}"
    embedded="$(bash -c "source '$BINARY'; ss_expected_sha256 '$triple'")"
    [ "$embedded" = "$sum" ] || { echo "out of sync for $triple: file=$sum embedded=$embedded"; false; }
  done < "$REPO_ROOT/checksums/ss-rust.sha256"
}

@test "install refuses when no embedded hash exists for the host triple" {
  # Detect a triple with NO embedded constant -> must die before downloading.
  printf '#!/bin/sh\necho x86_64\n' > "$STUB_DIR/uname"; chmod +x "$STUB_DIR/uname"
  run bash -c "
    PATH=\"$STUB_DIR:\$PATH\"
    source '$BINARY'
    unset _SS_RUST_SHA256_x86_64_unknown_linux_musl
    SS_SERVER_BIN='$INSTALL_DIR/ssserver'
    ss_install_binary
  "
  [ "$status" -ne 0 ]
  [[ "$output" == *"no embedded SHA256"* ]]
  [ ! -e "$INSTALL_DIR/ssserver" ]
}

@test "download failure during install aborts without partial artifacts" {
  printf '#!/bin/sh\necho x86_64\n' > "$STUB_DIR/uname"; chmod +x "$STUB_DIR/uname"
  embed="$(make_release x86_64-unknown-linux-musl)"
  run bash -c "
    PATH=\"$STUB_DIR:\$PATH\"
    source '$BINARY'
    $embed
    SS_SERVER_BIN='$INSTALL_DIR/ssserver'
    SS_RELEASE_BASE_URL='file://$HOST_DIR/does-not-exist'
    SS_DOWNLOAD_PROTO='=file'
    SS_DOWNLOAD_BACKOFF_BASE=0
    ss_install_binary
  "
  [ "$status" -ne 0 ]
  [ ! -e "$INSTALL_DIR/ssserver" ]
  run bash -c "ls -A '$TMPDIR_TEST' | grep -c 'ss-easy' || true"
  [ "$output" = "0" ]
}
