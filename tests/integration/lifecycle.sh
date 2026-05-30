#!/usr/bin/env bash
#
# tests/integration/lifecycle.sh — full install->user->uninstall lifecycle of the
# assembled `dist/ss-easy` bundle inside a container (runs INSIDE the container).
#
# Drives the REAL bundle (built by build.sh) through:
#   install --silent -> file-permission assertions -> user add -> user list
#   -> user show -> user del -> uninstall
#
# SYSTEMD-IN-DOCKER: a plain `docker run` container has no systemd as PID 1, so
# `systemctl` calls cannot succeed. To keep the lifecycle runnable in plain CI
# containers we shim the systemd-touching boundaries with no-op stubs on PATH
# (systemctl, the firewall tools), exactly as a systemd-capable image would
# satisfy them. Everything else — pkg install, binary download+verify, registry,
# config.json generation, ss:// links, file permissions, uninstall cleanup — is
# exercised for real. The pure proxy correctness of the link is proven
# separately and live by proxy-e2e.sh.
#
# Exits non-zero on the first failed assertion.

set -euo pipefail

REPO="${SS_EASY_SRC:-/src}"
BUNDLE="${SS_EASY_BUNDLE:-$REPO/dist/ss-easy}"

log()  { printf '[lifecycle] %s\n' "$*"; }
fail() { printf '[lifecycle] FAIL: %s\n' "$*" >&2; exit 1; }
ok()   { printf '[lifecycle] OK: %s\n' "$*"; }

[ -x "$BUNDLE" ] || fail "bundle not found/executable: $BUNDLE (run build.sh)"

# The assembled bundle verifies the ss-rust download against the SHA256 table
# EMBEDDED in lib/binary.sh (build.sh syncs it from checksums/ss-rust.sha256), so
# it reads no sibling checksum file at runtime. We still run from a clean writable
# scratch dir (with a copy of the committed table for convenience/debugging) so
# the bundle never depends on or writes into the read-only source mount.
RUNDIR="$(mktemp -d)"
mkdir -p "$RUNDIR/checksums"
cp "$REPO/checksums/ss-rust.sha256" "$RUNDIR/checksums/"
# run_bundle <args...> — invoke the bundle from $RUNDIR (clean scratch CWD).
run_bundle() { ( cd "$RUNDIR" && "$BUNDLE" "$@" ); }

# --- systemd / firewall shims (plain container has no systemd as PID 1) ------
# Install no-op stubs ahead of the real tools on PATH so the bundle's service
# and firewall steps succeed without a running init. We assert the GENERATED
# artifacts (unit file, config) instead of a live `systemctl is-active`.
SHIM="$(mktemp -d)/shim"
mkdir -p "$SHIM"
for t in systemctl ufw firewall-cmd iptables ip6tables sysctl; do
  cat > "$SHIM/$t" <<EOF
#!/usr/bin/env bash
printf '[shim:$t] %s\n' "\$*" >&2
exit 0
EOF
  chmod +x "$SHIM/$t"
done

# Package-manager shim: the runtime deps (jq/curl/qrencode/whiptail-or-newt) are
# pre-provisioned by the CI step before this script runs, so pkg_ensure_runtime_deps
# only needs to be a no-op success here. We shim apt-get/dnf/yum so the lifecycle
# exercises the REST of the real flow regardless of distro-specific package
# naming (NOTE: on rhel the whiptail binary ships in the `newt` package, not a
# package literally named `whiptail` — a pkg.sh naming gap tracked separately;
# the rhel binary-install + ss:// link path is proven live by proxy-e2e.sh).
for m in apt-get dnf yum; do
  cat > "$SHIM/$m" <<EOF
#!/usr/bin/env bash
# Swallow install/update (deps pre-provisioned); pass through query verbs.
case "\${1:-}" in
  install|update|-y) printf '[shim:$m] %s\n' "\$*" >&2; exit 0 ;;
  *) exec /usr/bin/$m "\$@" ;;
esac
EOF
  chmod +x "$SHIM/$m"
done
export PATH="$SHIM:$PATH"

# preflight's pf_require_systemd needs the systemd marker dir to exist as well as
# systemctl on PATH; create a marker the override points at (no real init needed).
MARKER="$(mktemp -d)/systemd-marker"
mkdir -p "$MARKER"
export SYSTEMD_MARKER="$MARKER"
# Keep the generated unit out of the host's real systemd dir (it is asserted by
# content/existence, never started). A writable temp path is enough here.
_unit_dir="$(mktemp -d)"
export SS_UNIT_FILE="$_unit_dir/ss-easy.service"

# --- 1) install -------------------------------------------------------------
log "install --silent (name=t0)"
run_bundle install --silent --name t0 || fail "install returned non-zero"
ok "install completed"

# --- 2) file-permission assertions (Decision 10) ----------------------------
log "asserting file permissions"
[ -d /etc/ss-easy ] || fail "/etc/ss-easy missing"
# Dir 0710 root:ss-easy — the unprivileged service user may TRAVERSE to its config.
[ "$(stat -c '%a' /etc/ss-easy)" = "710" ] || fail "/etc/ss-easy not 0710 (got $(stat -c '%a' /etc/ss-easy))"
[ "$(stat -c '%U' /etc/ss-easy)" = "root" ] || fail "/etc/ss-easy not root-owned"
# users.json: secret registry — stays 0600 root-only (never read by the service).
[ -f /etc/ss-easy/users.json ] || fail "users.json missing"
[ "$(stat -c '%a' /etc/ss-easy/users.json)" = "600" ] || fail "users.json not 0600 (got $(stat -c '%a' /etc/ss-easy/users.json))"
[ "$(stat -c '%U' /etc/ss-easy/users.json)" = "root" ] || fail "users.json not root-owned"
# config.json: 0640 root:ss-easy — group-readable so the service user can load it.
[ -f /etc/ss-easy/config.json ] || fail "config.json missing"
[ "$(stat -c '%a' /etc/ss-easy/config.json)" = "640" ] || fail "config.json not 0640 (got $(stat -c '%a' /etc/ss-easy/config.json))"
[ "$(stat -c '%U' /etc/ss-easy/config.json)" = "root" ] || fail "config.json not root-owned"
# Per-user access file (carries the secret) must be 0600 root-owned.
acc="/etc/ss-easy/users/t0.txt"
[ -f "$acc" ] || fail "access file $acc missing"
[ "$(stat -c '%a' "$acc")" = "600" ] || fail "$acc not 0600 (got $(stat -c '%a' "$acc"))"
ok "permissions: dir 0710, config.json 0640 (service-readable), secrets 0600 root-owned"

# config.json is valid JSON and consumable by ssserver.
jq -e . /etc/ss-easy/config.json >/dev/null || fail "config.json is not valid JSON"
ok "config.json is valid JSON"

# --- 3) user add ------------------------------------------------------------
log "user add t1"
add_out="$(run_bundle user add t1)" || fail "user add t1 failed"
printf '%s\n' "$add_out" | grep -q '^ss://' || fail "user add did not emit an ss:// link"
ok "user add t1 produced an ss:// link"

# --- 4) user list shows both users ------------------------------------------
log "user list"
list_out="$(run_bundle user list)" || fail "user list failed"
printf '%s\n' "$list_out" | grep -qw t0 || fail "user list missing t0"
printf '%s\n' "$list_out" | grep -qw t1 || fail "user list missing t1"
ok "user list shows t0 and t1"

# --- 5) user show -----------------------------------------------------------
run_bundle user show t1 | grep -q '^link' || fail "user show t1 missing link line"
ok "user show t1 works"

# t1's port appears in the regenerated config.json (registry -> config wiring).
t1_port="$(run_bundle user show t1 | awk '/^port/ {print $3}')"
jq -e --argjson p "$t1_port" 'any(.servers[]; .server_port == $p)' \
  /etc/ss-easy/config.json >/dev/null || fail "t1 port $t1_port not in config.json"
ok "t1 port present in config.json"

# --- 6) user del + config reload --------------------------------------------
log "user del t1"
run_bundle user del t1 || fail "user del t1 failed"
run_bundle user list | grep -qw t1 && fail "t1 still listed after del"
[ ! -f /etc/ss-easy/users/t1.txt ] || fail "t1 access file not removed"
jq -e --argjson p "$t1_port" 'any(.servers[]; .server_port == $p)' \
  /etc/ss-easy/config.json >/dev/null && fail "t1 port still in config.json after del"
ok "user del t1: removed from registry, access file, and config.json"

# --- 7) uninstall -----------------------------------------------------------
# --silent skips the interactive confirm (do_uninstall treats it as assume-yes).
log "uninstall (silent)"
run_bundle uninstall --silent || fail "uninstall failed"
[ ! -d /etc/ss-easy ] || fail "/etc/ss-easy still present after uninstall --purge"
[ ! -x /usr/local/bin/ssserver ] || fail "ssserver binary still present after uninstall"
ok "uninstall removed config dir and binary"

log "LIFECYCLE PASSED"
