#!/usr/bin/env bats
#
# Unit tests for lib/config.sh — the users.json registry (source of truth) and
# deterministic generation of the ss-rust config.json from it.
#
# All tests run against a temp /etc/ss-easy: setup() overrides the path
# constants from common.sh to a mktemp dir, so nothing touches the real /etc.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  COMMON="$REPO_ROOT/lib/common.sh"
  CONFIG="$REPO_ROOT/lib/config.sh"
  TMPDIR_TEST="$(mktemp -d)"

  # Path overrides consumed by config.sh (which re-derives its working paths
  # from these at call time, so the test can redirect them away from /etc).
  export SS_EASY_ETC="$TMPDIR_TEST/etc"
  export SS_EASY_USERS="$SS_EASY_ETC/users.json"
  export SS_EASY_CONFIG="$SS_EASY_ETC/config.json"
}

teardown() {
  [ -n "${TMPDIR_TEST:-}" ] && rm -rf "$TMPDIR_TEST"
}

# Run a body inside a fresh bash that sources both modules with the overridden
# paths. Usage: in_env '<bash snippet>'
in_env() {
  bash -c "
    set -euo pipefail
    export SS_EASY_ETC='$SS_EASY_ETC'
    export SS_EASY_USERS='$SS_EASY_USERS'
    export SS_EASY_CONFIG='$SS_EASY_CONFIG'
    source '$COMMON'
    # common.sh hard-sets the paths to /etc; restore our overrides afterwards.
    SS_EASY_ETC='$SS_EASY_ETC'
    SS_EASY_USERS='$SS_EASY_USERS'
    SS_EASY_CONFIG='$SS_EASY_CONFIG'
    source '$CONFIG'
    $1
  "
}

# --- registry init ----------------------------------------------------------

@test "registry init creates skeleton with schema_version and empty users" {
  run in_env "config_init"
  [ "$status" -eq 0 ]
  [ -f "$SS_EASY_USERS" ]
  run jq -e '.schema_version == 1 and (.users | length) == 0 and has("server_address") and has("default_method")' "$SS_EASY_USERS"
  [ "$status" -eq 0 ]
}

@test "registry init is idempotent" {
  in_env "config_init; config_user_add 'alice' 18342 '2022-blake3-aes-256-gcm' 'sek' '2026-05-30T11:00:00Z'"
  # Re-init must not wipe the existing user.
  run in_env "config_init"
  [ "$status" -eq 0 ]
  run jq -r '.users[0].name' "$SS_EASY_USERS"
  [ "$output" = "alice" ]
}

# --- CRUD -------------------------------------------------------------------

@test "add user appends record with all fields" {
  run in_env "config_init; config_user_add 'alice' 18342 'mymethod' 'mysecret' '2026-05-30T11:00:00Z'"
  [ "$status" -eq 0 ]
  run jq -e '.users[0] | .name=="alice" and .port==18342 and .method=="mymethod" and .secret=="mysecret" and .created=="2026-05-30T11:00:00Z"' "$SS_EASY_USERS"
  [ "$status" -eq 0 ]
}

@test "add user stores port as a JSON number, not a string" {
  in_env "config_init; config_user_add 'alice' 18342 'm' 's' 'c'"
  run jq -r '.users[0].port | type' "$SS_EASY_USERS"
  [ "$output" = "number" ]
}

@test "add then list names returns the name" {
  run in_env "config_init; config_user_add 'alice' 1 'm' 's' 'c'; config_user_add 'bob' 2 'm' 's' 'c'; config_list_names"
  [ "$status" -eq 0 ]
  [[ "$output" == *"alice"* ]]
  [[ "$output" == *"bob"* ]]
}

@test "exists is true for present and false (non-zero) for absent name" {
  run in_env "config_init; config_user_add 'alice' 1 'm' 's' 'c'; config_user_exists 'alice'"
  [ "$status" -eq 0 ]
  run in_env "config_init; config_user_add 'alice' 1 'm' 's' 'c'; config_user_exists 'nobody'"
  [ "$status" -ne 0 ]
}

@test "used ports projection returns allocated ports" {
  run in_env "config_init; config_user_add 'a' 18342 'm' 's' 'c'; config_user_add 'b' 9000 'm' 's' 'c'; config_used_ports"
  [ "$status" -eq 0 ]
  [[ "$output" == *"18342"* ]]
  [[ "$output" == *"9000"* ]]
}

@test "show existing user returns its record as JSON" {
  run in_env "config_init; config_user_add 'alice' 18342 'm' 'sek' 'c'; config_user_show 'alice'"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.name == "alice" and .secret == "sek"'
}

@test "del existing user removes record" {
  in_env "config_init; config_user_add 'alice' 1 'm' 's' 'c'; config_user_add 'bob' 2 'm' 's' 'c'; config_user_del 'alice'"
  run jq -r '[.users[].name] | join(",")' "$SS_EASY_USERS"
  [ "$output" = "bob" ]
}

@test "del non-existent name exits non-zero with clear error" {
  run in_env "config_init; config_user_del 'ghost'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"ghost"* ]] || [[ "$output" == *"not found"* ]] || [[ "$output" == *"no such"* ]]
}

@test "show non-existent name exits non-zero" {
  run in_env "config_init; config_user_show 'ghost'"
  [ "$status" -ne 0 ]
}

# --- global fields ----------------------------------------------------------

@test "get/set server_address round-trips" {
  run in_env "config_init; config_set_server_address '203.0.113.10'; config_get_server_address"
  [ "$status" -eq 0 ]
  [ "$output" = "203.0.113.10" ]
}

@test "get/set default_method round-trips" {
  run in_env "config_init; config_set_default_method 'chacha20-ietf-poly1305'; config_get_default_method"
  [ "$status" -eq 0 ]
  [ "$output" = "chacha20-ietf-poly1305" ]
}

# --- config.json generation -------------------------------------------------

@test "config generation produces valid servers array" {
  in_env "config_init; config_user_add 'alice' 18342 'mymethod' 'mysecret' 'c'; config_generate"
  [ -f "$SS_EASY_CONFIG" ]
  run jq -e '
    (.servers | length) == 1 and
    (.servers[0].server == "0.0.0.0") and
    (.servers[0].server_port == 18342) and
    (.servers[0].password == "mysecret") and
    (.servers[0].method == "mymethod") and
    (.servers[0].mode == "tcp_and_udp")
  ' "$SS_EASY_CONFIG"
  [ "$status" -eq 0 ]
}

@test "config generation on empty registry yields valid empty servers array" {
  in_env "config_init; config_generate"
  run jq -e '.servers == []' "$SS_EASY_CONFIG"
  [ "$status" -eq 0 ]
}

@test "config generation server_port is a number" {
  in_env "config_init; config_user_add 'alice' 18342 'm' 's' 'c'; config_generate"
  run jq -r '.servers[0].server_port | type' "$SS_EASY_CONFIG"
  [ "$output" = "number" ]
}

@test "config generation is deterministic" {
  in_env "config_init; config_user_add 'alice' 1 'm' 's' 'c'; config_user_add 'bob' 2 'm' 's' 'c'; config_generate"
  first="$(cat "$SS_EASY_CONFIG")"
  in_env "config_generate"
  second="$(cat "$SS_EASY_CONFIG")"
  [ "$first" = "$second" ]
}

# --- injection safety -------------------------------------------------------

@test "jq input with special chars is not interpolated" {
  malicious='") | .x="pwned'
  in_env "config_init; config_user_add 'alice' 18342 'm' '$malicious' 'c'"
  # The malicious value is stored literally as the secret, no extra key injected.
  run jq -e '.users[0].secret == "\") | .x=\"pwned"' "$SS_EASY_USERS"
  [ "$status" -eq 0 ]
  run jq -e 'has("x") | not' "$SS_EASY_USERS"
  [ "$status" -eq 0 ]
  # And it survives into config.json as a literal password, valid JSON.
  in_env "config_generate"
  run jq -e '.servers[0].password == "\") | .x=\"pwned"' "$SS_EASY_CONFIG"
  [ "$status" -eq 0 ]
}

@test "name with quotes, dollar, semicolon and space is stored literally" {
  weird='a "b" $c; d'
  in_env "config_init; config_user_add '$weird' 1 'm' 's' 'c'"
  run jq -r '.users[0].name' "$SS_EASY_USERS"
  [ "$output" = "$weird" ]
}

# --- corrupt registry -------------------------------------------------------

@test "reading a corrupt users.json fails with a clear error" {
  mkdir -p "$SS_EASY_ETC"
  printf 'not json{' > "$SS_EASY_USERS"
  run in_env "config_list_names"
  [ "$status" -ne 0 ]
}

# --- permissions ------------------------------------------------------------

@test "perms: dir 0710, users.json 0600 (root-only), config.json 0640 (service-readable)" {
  in_env "config_init; config_user_add 'alice' 18342 'm' 's' 'c'; config_generate"
  # Dir 0710: service user may traverse to config.json (no service group in tests,
  # so it stays root-owned). users.json stays 0600 (secret registry, root-only).
  # config.json is 0640 so the unprivileged systemd service user can read it.
  [ "$(stat -c '%a' "$SS_EASY_ETC")" = "710" ]
  [ "$(stat -c '%a' "$SS_EASY_USERS")" = "600" ]
  [ "$(stat -c '%a' "$SS_EASY_CONFIG")" = "640" ]
}
