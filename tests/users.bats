#!/usr/bin/env bats
#
# Unit tests for lib/users.sh — the user CRUD layer: name validation, free-port
# allocation, cryptographic credential generation, and registry delegation to
# lib/config.sh. All tests run against a temp /etc/ss-easy.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  COMMON="$REPO_ROOT/lib/common.sh"
  CONFIG="$REPO_ROOT/lib/config.sh"
  LINK="$REPO_ROOT/lib/link.sh"
  USERS="$REPO_ROOT/lib/users.sh"
  NETWORK="$REPO_ROOT/lib/network.sh"
  TMPDIR_TEST="$(mktemp -d)"

  export SS_EASY_ETC="$TMPDIR_TEST/etc"
  export SS_EASY_USERS="$SS_EASY_ETC/users.json"
  export SS_EASY_CONFIG="$SS_EASY_ETC/config.json"
  export SS_EASY_USERS_DIR="$SS_EASY_ETC/users"
}

teardown() {
  [ -n "${TMPDIR_TEST:-}" ] && rm -rf "$TMPDIR_TEST"
}

# Source all four modules in a fresh shell with overridden paths.
in_env() {
  bash -c "
    set -euo pipefail
    source '$COMMON'
    SS_EASY_ETC='$SS_EASY_ETC'
    SS_EASY_USERS='$SS_EASY_USERS'
    SS_EASY_CONFIG='$SS_EASY_CONFIG'
    SS_EASY_USERS_DIR='$SS_EASY_USERS_DIR'
    source '$CONFIG'
    source '$LINK'
    source '$USERS'
    $1
  "
}

# --- name validation --------------------------------------------------------

@test "valid name accepted" {
  run in_env "users_validate_name 'my_user-1'"
  [ "$status" -eq 0 ]
}

@test "name of exactly 32 chars accepted, 33 rejected" {
  n32="$(printf 'a%.0s' $(seq 1 32))"
  n33="$(printf 'a%.0s' $(seq 1 33))"
  run in_env "users_validate_name '$n32'"
  [ "$status" -eq 0 ]
  run in_env "users_validate_name '$n33'"
  [ "$status" -ne 0 ]
}

@test "invalid names rejected non-zero (space, semicolon, traversal, empty, unicode)" {
  run in_env "users_validate_name 'a b'";        [ "$status" -ne 0 ]
  run in_env "users_validate_name 'a;b'";        [ "$status" -ne 0 ]
  run in_env "users_validate_name '../etc'";     [ "$status" -ne 0 ]
  run in_env "users_validate_name ''";           [ "$status" -ne 0 ]
  run in_env "users_validate_name 'a/b'";        [ "$status" -ne 0 ]
  run in_env 'users_validate_name "\$(id)"';     [ "$status" -ne 0 ]
  run in_env "users_validate_name 'имя'";        [ "$status" -ne 0 ]
}

# --- CRUD -------------------------------------------------------------------

@test "add creates user, list shows it without secrets" {
  in_env "config_init; users_add 'alice' '2022-blake3-aes-256-gcm'"
  run in_env "users_list"
  [ "$status" -eq 0 ]
  [[ "$output" == *"alice"* ]]
  # The base64 key / password must not leak into the list output.
  secret="$(jq -r '.users[0].secret' "$SS_EASY_USERS")"
  [[ "$output" != *"$secret"* ]]
}

@test "duplicate name rejected with clear non-zero error" {
  in_env "config_init; users_add 'alice' '2022-blake3-aes-256-gcm'"
  run in_env "users_add 'alice' '2022-blake3-aes-256-gcm'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"alice"* ]] || [[ "$output" == *"exists"* ]]
}

@test "add with invalid name fails before touching the registry" {
  run in_env "config_init; users_add 'a;b' '2022-blake3-aes-256-gcm'"
  [ "$status" -ne 0 ]
  run jq -r '.users | length' "$SS_EASY_USERS"
  [ "$output" = "0" ]
}

@test "del nonexistent fails with not-found message" {
  run in_env "config_init; users_del 'ghost'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"ghost"* ]] || [[ "$output" == *"not found"* ]]
}

@test "del existing removes user and its access file" {
  in_env "config_init; users_add 'alice' '2022-blake3-aes-256-gcm'"
  [ -f "$SS_EASY_USERS_DIR/alice.txt" ]
  in_env "users_del 'alice'"
  run jq -r '.users | length' "$SS_EASY_USERS"
  [ "$output" = "0" ]
  [ ! -f "$SS_EASY_USERS_DIR/alice.txt" ]
}

@test "show nonexistent fails with not-found message" {
  run in_env "config_init; users_show 'ghost'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"ghost"* ]] || [[ "$output" == *"not found"* ]]
}

@test "show existing prints its ss:// link" {
  in_env "config_init; users_add 'alice' '2022-blake3-aes-256-gcm'"
  run in_env "users_show 'alice'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ss://2022-blake3-aes-256-gcm:"* ]]
}

# --- port allocation --------------------------------------------------------

@test "free port avoids ports already in registry" {
  # Pre-seed two users on fixed ports, then assert a fresh allocation differs.
  in_env "config_init; config_user_add 'a' 20000 'm' 's' 'c'; config_user_add 'b' 20001 'm' 's' 'c'"
  port="$(in_env "users_alloc_port")"
  [ "$port" -gt 1024 ]
  [ "$port" != "20000" ]
  [ "$port" != "20001" ]
}

@test "free port allocation works on an empty registry" {
  port="$(in_env "config_init; users_alloc_port")"
  [ "$port" -gt 1024 ]
}

# --- credential entropy -----------------------------------------------------

@test "credentials are not sourced from \$RANDOM" {
  # Static guarantee: no $RANDOM anywhere in the module.
  run grep -F '$RANDOM' "$REPO_ROOT/lib/users.sh"
  [ "$status" -ne 0 ]
}

@test "sip022 key is standard base64 (with padding) decoding to exactly 32 bytes" {
  key="$(in_env "users_gen_secret '2022-blake3-aes-256-gcm'")"
  # Must NOT be url-safe: no '-' or '_' allowed (standard alphabet only).
  [[ "$key" != *"-"* ]]
  [[ "$key" != *"_"* ]]
  # 32 bytes → standard base64 is 44 chars ending in '=' (padding present).
  [[ "$key" == *"=" ]]
  n="$(printf '%s' "$key" | base64 -d | wc -c)"
  [ "$n" -eq 32 ]
}

@test "classic secret is a non-empty random password (not base64-32B key)" {
  pw="$(in_env "users_gen_secret 'chacha20-ietf-poly1305'")"
  [ -n "$pw" ]
}

@test "two generated secrets differ (entropy sanity)" {
  a="$(in_env "users_gen_secret '2022-blake3-aes-256-gcm'")"
  b="$(in_env "users_gen_secret '2022-blake3-aes-256-gcm'")"
  [ "$a" != "$b" ]
}

# --- network: IP validation -------------------------------------------------

net_env() {
  bash -c "
    set -euo pipefail
    source '$COMMON'
    source '$NETWORK'
    $1
  "
}

@test "ip validation accepts a valid IPv4" {
  run net_env "net_is_valid_ip '203.0.113.10'"
  [ "$status" -eq 0 ]
}

@test "ip validation accepts a valid IPv6" {
  run net_env "net_is_valid_ip '2001:db8::1'"
  [ "$status" -eq 0 ]
}

@test "ip validation rejects garbage / out-of-range / HTML body" {
  run net_env "net_is_valid_ip '999.1.1.1'";           [ "$status" -ne 0 ]
  run net_env "net_is_valid_ip 'not-an-ip'";           [ "$status" -ne 0 ]
  run net_env "net_is_valid_ip '<html>error</html>'";  [ "$status" -ne 0 ]
  run net_env "net_is_valid_ip '203.0.113.10 extra'";  [ "$status" -ne 0 ]
  run net_env "net_is_valid_ip ''";                    [ "$status" -ne 0 ]
}

@test "manual override wins over autodetect" {
  run net_env "net_detect_public_ip '198.51.100.7'"
  [ "$status" -eq 0 ]
  [ "$output" = "198.51.100.7" ]
}

@test "manual override is itself validated" {
  run net_env "net_detect_public_ip 'garbage;rm'"
  [ "$status" -ne 0 ]
}

@test "autodetect falls back across sources and rejects garbage (mocked curl)" {
  # Mock curl: first source returns HTML (rejected), second returns a valid IP.
  bash -c "
    set -euo pipefail
    source '$COMMON'
    source '$NETWORK'
    curl() {
      case \"\$*\" in
        *api.ipify.org*) printf '<html>down</html>'; return 0 ;;
        *ifconfig.co*)   printf '198.51.100.42'; return 0 ;;
        *)               return 1 ;;
      esac
    }
    export -f curl
    out=\"\$(net_detect_public_ip)\"
    [ \"\$out\" = '198.51.100.42' ]
  "
}

@test "autodetect fails non-zero when every source is unreachable (mocked curl)" {
  run bash -c "
    set -euo pipefail
    source '$COMMON'
    source '$NETWORK'
    curl() { return 7; }   # all sources fail (connection refused)
    export -f curl
    net_detect_public_ip
  "
  [ "$status" -ne 0 ]
}
