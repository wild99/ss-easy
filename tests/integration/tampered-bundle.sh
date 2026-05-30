#!/usr/bin/env bash
#
# tests/integration/tampered-bundle.sh — assert the bootstrap REFUSES to execute
# a bundle whose SHA256 does not match the published checksum (Decision 9).
#
# Runs INSIDE a container. It stands up a local fixture "release host" (a temp
# dir served by a curl stub), publishes a correct checksum, then SWAPS the bundle
# so its hash no longer matches — and asserts install.sh aborts non-zero with
# nothing installed at the target path. This is the negative half of the
# verify-before-exec contract that the happy path (bootstrap.bats) covers.

set -euo pipefail

REPO="${SS_EASY_SRC:-/src}"
log()  { printf '[tampered] %s\n' "$*"; }
fail() { printf '[tampered] FAIL: %s\n' "$*" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
HOST="$WORK/host"; STUB="$WORK/bin"
mkdir -p "$HOST/dist" "$HOST/checksums" "$STUB"
TARGET="$WORK/usr-local-bin/ss-easy"

# A legitimate bundle + its published checksum.
printf '#!/usr/bin/env bash\necho REAL\n' > "$HOST/dist/ss-easy"
chmod +x "$HOST/dist/ss-easy"
( cd "$HOST/dist" && sha256sum ss-easy ) > "$HOST/checksums/bootstrap.sha256"

# curl stub mapping FIXTURE://<path> -> $HOST/<path> (honours -o, 404 on miss).
cat > "$STUB/curl" <<EOF
#!/usr/bin/env bash
dest=""; url=""
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    -o) dest="\$2"; shift 2 ;;
    *://*) url="\$1"; shift ;;
    *) shift ;;
  esac
done
src="$HOST/\${url#FIXTURE://}"
[ -f "\$src" ] || { echo "curl: 404 \$url" >&2; exit 22; }
cp "\$src" "\$dest"
EOF
chmod +x "$STUB/curl"
export PATH="$STUB:$PATH"

# Now TAMPER: replace the bundle after its checksum was published.
printf '#!/usr/bin/env bash\necho PWNED; touch /tmp/PWNED_MARKER\n' > "$HOST/dist/ss-easy"
chmod +x "$HOST/dist/ss-easy"

export SS_EASY_BASE_URL="FIXTURE://"
export SS_EASY_BIN="$TARGET"
export SS_DOWNLOAD_BACKOFF_BASE=0

log "running bootstrap against a tampered bundle (expect abort)"
set +e
SS_EASY_BIN="$TARGET" bash "$REPO/install.sh" --silent
rc=$?
set -e

[ "$rc" -ne 0 ] || fail "bootstrap exited 0 on a tampered bundle (must abort)"
[ ! -e "$TARGET" ] || fail "a bundle was installed at $TARGET despite the mismatch"
[ ! -e /tmp/PWNED_MARKER ] || fail "the tampered bundle EXECUTED (marker present)"
log "TAMPERED-BUNDLE PASSED: bootstrap aborted (rc=$rc), nothing installed, nothing executed"
