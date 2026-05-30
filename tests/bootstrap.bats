#!/usr/bin/env bats
#
# Unit tests for install.sh — the curl|bash bootstrap (Decision 9).
#
# The bootstrap is exercised end-to-end WITHOUT touching the network or the real
# /usr/local/bin: `curl` is replaced by a PATH stub that serves a local fixture
# "release host" (a temp dir), $SS_EASY_BIN points at a temp path, and the
# installed bundle is a tiny mock `ss-easy` that records that `install` was
# reached. Each test asserts the verify-before-exec contract.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  BOOT="$REPO_ROOT/install.sh"

  TMP="$(mktemp -d)"
  STUB_DIR="$TMP/bin"
  HOST="$TMP/host"            # fixture "release host" tree (dist/ + checksums/)
  mkdir -p "$STUB_DIR" "$HOST/dist" "$HOST/checksums"

  CALLS="$TMP/calls.log"

  # The bundle the bootstrap will "download": a mock ss-easy that, when invoked
  # as `ss-easy install ...`, logs the call so the test can assert exec happened.
  cat > "$HOST/dist/ss-easy" <<EOF
#!/usr/bin/env bash
printf 'BUNDLE-EXEC %s\n' "\$*" >> "$CALLS"
exit 0
EOF
  chmod +x "$HOST/dist/ss-easy"

  # The published checksum for that bundle (the canonical "release" value).
  ( cd "$HOST/dist" && sha256sum ss-easy ) > "$HOST/checksums/bootstrap.sha256"

  # curl stub: translate the pinned base URL back into a path under $HOST and
  # copy the file. Honours `-o <dest>`; fails (like --fail) when the source is
  # missing. Knows nothing about TLS — it only proves wiring + verify logic.
  cat > "$STUB_DIR/curl" <<EOF
#!/usr/bin/env bash
dest=""; url=""
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    -o) dest="\$2"; shift 2 ;;
    *://*) url="\$1"; shift ;;
    *) shift ;;
  esac
done
printf 'curl %s\n' "\$url" >> "$CALLS"
rel="\${url#FIXTURE://}"
src="$HOST/\$rel"
[ -f "\$src" ] || { echo "curl: 404 \$url" >&2; exit 22; }
cp "\$src" "\$dest"
EOF
  chmod +x "$STUB_DIR/curl"

  # Common env: fixture base URL (scheme FIXTURE:// so the stub maps it), a temp
  # install target, and a fast/no-network retry profile.
  export PATH="$STUB_DIR:$PATH"
  export SS_EASY_BASE_URL="FIXTURE://"
  export SS_EASY_BIN="$TMP/usr-local-bin/ss-easy"
  export SS_DOWNLOAD_PROTO="=https"
  export SS_DOWNLOAD_RETRIES=3
  export SS_DOWNLOAD_BACKOFF_BASE=0   # no real sleeping in tests
  # Force the root guard to pass without sudo by stubbing id -u -> 0.
  cat > "$STUB_DIR/id" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "-u" ]; then echo 0; exit 0; fi
exec /usr/bin/id "$@"
EOF
  chmod +x "$STUB_DIR/id"
}

teardown() {
  [ -n "${TMP:-}" ] && rm -rf "$TMP"
}

# --- happy path: matching checksum -> install + exec ------------------------

@test "test_checksum_match_executes: valid bundle + matching SHA256 reaches install" {
  run bash "$BOOT" --silent --name probe
  [ "$status" -eq 0 ]
  # The verified bundle was installed at the target path, mode 0755.
  [ -x "$SS_EASY_BIN" ]
  [ "$(stat -c '%a' "$SS_EASY_BIN")" = "755" ]
  # exec ss-easy install "$@" happened, with flags forwarded verbatim.
  grep -q 'BUNDLE-EXEC install --silent --name probe' "$CALLS"
}

# --- tampered bundle: hash differs from published -> abort, no install ------

@test "test_tampered_bundle_aborts: swapped bundle fails verify, nothing installed" {
  # Replace the bundle AFTER its checksum was published -> hash no longer matches.
  printf '#!/usr/bin/env bash\necho PWNED\n' > "$HOST/dist/ss-easy"
  chmod +x "$HOST/dist/ss-easy"

  run bash "$BOOT" --silent
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi 'mismatch'
  # No partial artifact at the install target, and install/exec never reached.
  [ ! -e "$SS_EASY_BIN" ]
  run grep -q 'BUNDLE-EXEC' "$CALLS"; [ "$status" -ne 0 ]
}

@test "test_tampered_checksum_aborts: forged published SHA256 fails verify" {
  # Tamper the published checksum instead of the bundle (asset-swap variant).
  printf '%s  ss-easy\n' "$(printf 'deadbeef%.0s' {1..8})" \
    > "$HOST/checksums/bootstrap.sha256"

  run bash "$BOOT"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi 'mismatch'
  [ ! -e "$SS_EASY_BIN" ]
}

# --- download failure: 404 -> retries then abort, no partial file -----------

@test "test_download_failure_aborts: missing bundle 404s, aborts cleanly" {
  rm -f "$HOST/dist/ss-easy"

  run bash "$BOOT" --silent
  [ "$status" -ne 0 ]
  # curl was retried SS_DOWNLOAD_RETRIES times for the bundle URL.
  [ "$(grep -c 'curl FIXTURE://*dist/ss-easy' "$CALLS")" -eq 3 ]
  # Nothing installed; exec never happened.
  [ ! -e "$SS_EASY_BIN" ]
  run grep -q 'BUNDLE-EXEC' "$CALLS"; [ "$status" -ne 0 ]
}

# --- non-root: clear sudo hint, no install ----------------------------------

@test "test_requires_root: non-root aborts with a sudo hint" {
  # Override the id stub to report a non-root uid.
  cat > "$STUB_DIR/id" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "-u" ]; then echo 1000; exit 0; fi
exec /usr/bin/id "$@"
EOF
  chmod +x "$STUB_DIR/id"

  run bash "$BOOT" --silent
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi 'root'
  echo "$output" | grep -qi 'sudo'
  [ ! -e "$SS_EASY_BIN" ]
}

# --- static hardening assertions on the script itself -----------------------

@test "test_no_insecure_curl_flags: no -k/--insecure, has --proto and --fail" {
  # Strip comments first so a comment that merely MENTIONS -k/--insecure (e.g.
  # "NEVER use -k") is not a false positive; assert on real code lines only.
  local code
  code="$(grep -vE '^[[:space:]]*#' "$BOOT")"
  run grep -Eq -- '(^|[[:space:]])(-k|--insecure)([[:space:]]|$)' <<<"$code"
  [ "$status" -ne 0 ]   # the insecure flags must be ABSENT from real code
  grep -q -- "--proto" "$BOOT"
  grep -q -- "--tlsv1.2" "$BOOT"
  grep -q -- "--fail" "$BOOT"
}

@test "test_verify_before_exec_ordering: sha256sum -c precedes exec in source" {
  local verify_ln exec_ln
  verify_ln="$(grep -n 'sha256sum -c' "$BOOT" | head -n1 | cut -d: -f1)"
  exec_ln="$(grep -n 'exec ..SS_EASY_BIN. install' "$BOOT" | head -n1 | cut -d: -f1)"
  [ -n "$verify_ln" ]
  [ -n "$exec_ln" ]
  [ "$verify_ln" -lt "$exec_ln" ]
}

@test "test_tag_pinned: pins a release tag, not a moving branch" {
  # The default base URL must reference a tag variable, never main/master/HEAD.
  grep -q 'SS_EASY_TAG' "$BOOT"
  run grep -Eq 'githubusercontent\.com/[^/]+/[^/]+/(main|master|HEAD)' "$BOOT"
  [ "$status" -ne 0 ]   # must NOT pin a moving branch
}
