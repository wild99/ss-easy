# shellcheck shell=bash
#
# lib/config.sh — the user registry (source of truth) and deterministic
# generation of the shadowsocks-rust runtime config from it (Decision 2).
#
# /etc/ss-easy/users.json is authoritative: it carries user names and metadata
# that ss-rust server blocks cannot. /etc/ss-easy/config.json is a pure
# projection of the registry, regenerated on every mutation.
#
# PUBLIC CONTRACT (consumed by users.sh, link.sh, service.sh, install/uninstall):
#
#   config_init                                 idempotently create dir + skeleton
#   config_user_add  <name> <port> <method> <secret> <created>   append a record
#   config_user_del  <name>                     remove a record (non-zero if absent)
#   config_user_show <name>                     print the record JSON (non-zero if absent)
#   config_user_exists <name>                   exit 0 if present, non-zero otherwise
#   config_list_names                           print user names, one per line
#   config_used_ports                           print allocated ports, one per line
#   config_get_server_address / config_set_server_address <ip>
#   config_get_default_method  / config_set_default_method  <method>
#   config_generate                             (re)write config.json from registry
#
# SAFETY (Decisions 7, 8, 10):
#   - Every jq invocation passes data only via --arg/--argjson; the jq program
#     is always a static string literal — never interpolate values into it.
#   - All writes are atomic (atomic_write: 0600 temp -> mv) and re-assert perms.
#   - Directory 0700, files 0600. The module runs in a root context.
#
# Paths are read from the SS_EASY_* variables at call time (not captured at
# source), so the test suite can redirect them to a temp dir.

# Guard against double-sourcing in the assembled bundle / nested sources.
if [ -n "${_SS_EASY_CONFIG_LOADED:-}" ]; then
  # shellcheck disable=SC2317  # reached only on re-source of this module.
  return 0 2>/dev/null || true
fi
_SS_EASY_CONFIG_LOADED=1

# --- internal helpers -------------------------------------------------------

# _config_require_registry — die unless users.json exists and is valid JSON.
# Prevents a corrupt/missing registry from silently yielding empty results.
_config_require_registry() {
  [ -f "$SS_EASY_USERS" ] \
    || die "registry not found: $SS_EASY_USERS (run install first)"
  jq -e . "$SS_EASY_USERS" >/dev/null 2>&1 \
    || die "registry is not valid JSON: $SS_EASY_USERS"
}

# _config_grant_service <mode> <path> — apply <mode>, and when the dedicated
# service group exists, group-own <path> by it so the unprivileged systemd service
# user can reach/read the generated config WITHOUT exposing it to other local
# users. Guarded: in non-install contexts (tests) the group is absent, so <path>
# stays root-owned with <mode> applied.
_config_grant_service() {
  local mode="$1" path="$2"
  chmod "$mode" "$path" || die "cannot chmod ${mode}: $path"
  if command -v getent >/dev/null 2>&1 && getent group "$SS_SERVICE_USER" >/dev/null 2>&1; then
    chgrp "$SS_SERVICE_USER" "$path" 2>/dev/null || true
  fi
}

# _config_ensure_dir — create the base dir if missing; assert perms. 0710 + the
# service group lets the unprivileged service user TRAVERSE to the generated
# config (not list the dir); users.json / users/ inside keep 0600/0700 so the
# secret registry stays root-only.
_config_ensure_dir() {
  if [ ! -d "$SS_EASY_ETC" ]; then
    mkdir -p "$SS_EASY_ETC" || die "cannot create directory: $SS_EASY_ETC"
  fi
  _config_grant_service 710 "$SS_EASY_ETC"
}

# _config_write_users <stdin> — atomically replace users.json (0600) from stdin.
_config_write_users() {
  _config_ensure_dir
  atomic_write "$SS_EASY_USERS" || die "failed to write registry: $SS_EASY_USERS"
  chmod 600 "$SS_EASY_USERS" || die "cannot chmod 0600: $SS_EASY_USERS"
}

# _config_jq_users <jq-program> [jq-args...] — run jq over users.json with the
# given (static) program and pass-through args; die on jq failure.
_config_jq_users() {
  local program="$1"; shift
  local out
  out="$(jq "$@" "$program" "$SS_EASY_USERS")" \
    || die "jq failed while reading $SS_EASY_USERS"
  printf '%s' "$out"
}

# --- registry init ----------------------------------------------------------

# config_init — create the dir and a registry skeleton if absent. Idempotent:
# an existing valid registry is left untouched (users/secrets preserved).
config_init() {
  _config_ensure_dir
  if [ -f "$SS_EASY_USERS" ]; then
    return 0
  fi
  jq -n \
    --argjson schema_version 1 \
    --arg server_address "" \
    --arg default_method "${DEFAULT_METHOD:-2022-blake3-aes-256-gcm}" \
    '{schema_version: $schema_version,
      server_address: $server_address,
      default_method: $default_method,
      users: []}' \
    | _config_write_users
}

# --- CRUD -------------------------------------------------------------------

# config_user_add <name> <port> <method> <secret> <created>
config_user_add() {
  local name="$1" port="$2" method="$3" secret="$4" created="$5"
  _config_require_registry
  jq \
    --arg name "$name" \
    --argjson port "$port" \
    --arg method "$method" \
    --arg secret "$secret" \
    --arg created "$created" \
    '.users += [{name: $name, port: $port, method: $method,
                 secret: $secret, created: $created}]' \
    "$SS_EASY_USERS" \
    | _config_write_users \
    || die "failed to add user: $name"
}

# config_user_del <name> — remove the record; non-zero if the name is absent.
config_user_del() {
  local name="$1"
  _config_require_registry
  config_user_exists "$name" \
    || die "user not found: $name"
  jq --arg name "$name" \
    '.users |= map(select(.name != $name))' \
    "$SS_EASY_USERS" \
    | _config_write_users \
    || die "failed to delete user: $name"
}

# config_user_show <name> — print the record JSON; non-zero if absent.
config_user_show() {
  local name="$1"
  _config_require_registry
  local rec
  rec="$(jq -c --arg name "$name" \
    '.users[] | select(.name == $name)' \
    "$SS_EASY_USERS")" \
    || die "jq failed while reading $SS_EASY_USERS"
  [ -n "$rec" ] || die "user not found: $name"
  printf '%s\n' "$rec"
}

# config_user_exists <name> — exit 0 if present, non-zero otherwise (no output).
config_user_exists() {
  local name="$1"
  _config_require_registry
  jq -e --arg name "$name" \
    'any(.users[]; .name == $name)' \
    "$SS_EASY_USERS" >/dev/null 2>&1
}

# config_list_names — print user names, one per line.
config_list_names() {
  _config_require_registry
  _config_jq_users '.users[].name' -r
}

# config_used_ports — print allocated ports, one per line.
config_used_ports() {
  _config_require_registry
  _config_jq_users '.users[].port' -r
}

# --- global fields ----------------------------------------------------------

config_get_server_address() {
  _config_require_registry
  _config_jq_users '.server_address' -r
}

config_set_server_address() {
  local ip="$1"
  _config_require_registry
  jq --arg ip "$ip" '.server_address = $ip' "$SS_EASY_USERS" \
    | _config_write_users \
    || die "failed to set server_address"
}

config_get_default_method() {
  _config_require_registry
  _config_jq_users '.default_method' -r
}

config_set_default_method() {
  local method="$1"
  _config_require_registry
  jq --arg method "$method" '.default_method = $method' "$SS_EASY_USERS" \
    | _config_write_users \
    || die "failed to set default_method"
}

# --- config.json generation -------------------------------------------------

# config_generate — (re)write config.json as a pure projection of the registry.
# Order follows the registry order, so an unchanged registry yields a
# byte-identical file. Each user maps to one ss-rust server block.
config_generate() {
  _config_require_registry
  local out
  out="$(jq \
    '{servers: [.users[] | {
        server: "0.0.0.0",
        server_port: .port,
        password: .secret,
        method: .method,
        mode: "tcp_and_udp"
      }]}' \
    "$SS_EASY_USERS")" \
    || die "failed to generate config from $SS_EASY_USERS"
  _config_ensure_dir
  printf '%s\n' "$out" | atomic_write "$SS_EASY_CONFIG" \
    || die "failed to write config: $SS_EASY_CONFIG"
  # 0640 + service group: the systemd service runs as the unprivileged service
  # user and must READ this generated config (it carries the proxy keys). It is
  # not world-readable, and the 0600 users.json registry is never read by it.
  _config_grant_service 640 "$SS_EASY_CONFIG"
}
