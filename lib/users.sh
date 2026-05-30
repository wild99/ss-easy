# shellcheck shell=bash
#
# lib/users.sh — user CRUD layer over the registry (Decisions 4, 8).
#
# This module owns: strict name validation, free-port allocation, cryptographic
# credential generation, and orchestration of add/del/list/show. It DELEGATES
# all registry mutation/projection to lib/config.sh (no duplicate JSON logic)
# and all ss:// / access-file output to lib/link.sh.
#
# PUBLIC CONTRACT (consumed by the entrypoint dispatcher):
#   users_validate_name <name>     exit 0 iff name matches ^[A-Za-z0-9_-]{1,32}$
#   users_gen_secret <method>      print a fresh credential for the method:
#                                    - 2022-blake3-*: 32 random bytes as STANDARD
#                                      base64 WITH padding (openssl rand -base64 32)
#                                    - classic: a random password (crypto source)
#   users_alloc_port               print a high free port (>1024) not in registry
#   users_add <name> [method]      validate -> dup-check -> alloc -> gen -> persist
#                                    -> regenerate config -> write link/access file
#   users_del <name>               remove from registry + delete access file
#   users_list                     print users (name/port/method), no secrets
#   users_show <name>              print a user's connection details + ss:// link
#
# Decision 8: the name is validated BEFORE it reaches any shell word, jq filter,
# or filesystem path. config.sh passes every value via jq --arg, and the access
# file path is built only from a validated name.

# Guard against double-sourcing in the assembled bundle / nested sources.
if [ -n "${_SS_EASY_USERS_LOADED:-}" ]; then
  # shellcheck disable=SC2317  # reached only on re-source of this module.
  return 0 2>/dev/null || true
fi
_SS_EASY_USERS_LOADED=1

# Strict whitelist for user names (Decision 8). Single source of truth.
SS_NAME_RE='^[A-Za-z0-9_-]{1,32}$'

# --- validation -------------------------------------------------------------

# users_validate_name <name> — exit 0 if valid, else non-zero (no output here;
# callers compose their own error message so the value is logged at most once).
#
# The match runs under LC_ALL=C so the A-Za-z ranges stay strictly ASCII: under
# a UTF-8 locale (the default on most VPS) those ranges otherwise admit accented
# unicode letters (e.g. "café"), defeating the documented ASCII whitelist
# (security: SS-M1). LC_ALL is set in a subshell so the caller's locale is intact.
users_validate_name() {
  local name="${1-}"
  ( LC_ALL=C; [[ "$name" =~ $SS_NAME_RE ]] )
}

# _users_require_valid_name <name> — validate or die with a clear message.
_users_require_valid_name() {
  local name="${1-}"
  users_validate_name "$name" \
    || die "invalid user name: must match ${SS_NAME_RE} (got: '${name}')"
}

# --- mutation side-effects (Decisions: registry -> regen -> reload -> firewall)
#
# After a registry change is persisted and config.json is regenerated, the live
# system still serves the OLD config and the firewall is unchanged. These helpers
# complete the documented chain: reload ssserver so it re-reads config.json, and
# open/close the affected port. They are GUARDED so a slim/test host without
# systemd or a firewall does not abort the (already-committed) registry mutation:
# a missing service unit -> warn+skip the reload; the firewall_* functions are
# themselves SSH-safe and warn+skip when no firewall is installed/active.

# _users_service_installed — rc 0 only if systemctl exists AND the unit file is
# present, i.e. a reload can be attempted without service_reload's hard die on a
# host that has no systemd at all. Overridable in tests.
_users_service_installed() {
  command -v systemctl >/dev/null 2>&1 || return 1
  local unit="${SS_UNIT_FILE:-/etc/systemd/system/${SS_SERVICE_NAME}}"
  [ -f "$unit" ]
}

# _users_reload_service — reload ssserver to pick up the regenerated config, but
# only when the unit is actually installed; otherwise warn and continue (the
# registry/config change has already succeeded). Never aborts the caller.
_users_reload_service() {
  if ! _users_service_installed; then
    log_warn "service ${SS_SERVICE_NAME} not installed; skipping reload (run 'ss-easy install' to activate)."
    return 0
  fi
  service_reload || log_warn "service reload failed; config updated but the running service may be stale."
}

# _users_open_firewall <port> — open tcp+udp for a user port. firewall_open_port
# is self-guarding (warns+skips when no firewall is installed/active) and never
# touches SSH, so failures here are non-fatal to the mutation.
_users_open_firewall() {
  local port="$1"
  firewall_open_port "$port" tcp || log_warn "could not open ${port}/tcp in the firewall."
  firewall_open_port "$port" udp || log_warn "could not open ${port}/udp in the firewall."
}

# _users_close_firewall <port> — remove the tcp+udp rules for a removed user port.
_users_close_firewall() {
  local port="$1"
  firewall_close_port "$port" tcp || log_warn "could not close ${port}/tcp in the firewall."
  firewall_close_port "$port" udp || log_warn "could not close ${port}/udp in the firewall."
}

# --- credential generation (Decision 4) -------------------------------------

# users_gen_secret <method> — print a cryptographically random credential.
# NEVER uses the shell PRNG. SIP022 keys are STANDARD base64 (with padding); url-safe
# base64 silently breaks the ss:// link in SS clients.
users_gen_secret() {
  local method="$1"
  case "$method" in
    2022-blake3-*)
      # 32 random bytes, standard base64 with padding → 44-char key.
      openssl rand -base64 32 \
        || die "failed to generate key (openssl rand)"
      ;;
    *)
      # Classic password: 24 random bytes, standard base64 (a strong opaque pw).
      openssl rand -base64 24 \
        || die "failed to generate password (openssl rand)"
      ;;
  esac
}

# --- port allocation --------------------------------------------------------

# users_alloc_port — print a free high port not present in the registry.
# Chooses randomly from the IANA dynamic range (49152-65535) using a crypto
# source, then linearly probes upward to skip ports already taken.
users_alloc_port() {
  local -a used=()
  local p
  # config_used_ports prints one port per line but may omit the final newline,
  # so keep the last partial read via `|| [ -n "$p" ]` — otherwise the last
  # allocated port could be treated as free and double-assigned.
  while IFS= read -r p || [ -n "$p" ]; do
    [ -n "$p" ] && used+=("$p")
  done < <(config_used_ports 2>/dev/null || true)

  # Random starting point in the dynamic/private port range (>1024 guaranteed).
  local lo=49152 hi=65535 span start rnd
  span=$((hi - lo + 1))
  # 2 random bytes → 0..65535, reduced into the range (crypto source from urandom).
  rnd="$(od -An -N2 -tu2 /dev/urandom | tr -d ' ')"
  start=$((lo + (rnd % span)))

  local i candidate taken
  for ((i = 0; i < span; i++)); do
    candidate=$((lo + ((start - lo + i) % span)))
    taken=0
    for p in ${used[@]+"${used[@]}"}; do
      if [ "$p" = "$candidate" ]; then taken=1; break; fi
    done
    if [ "$taken" -eq 0 ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  die "no free port available in range ${lo}-${hi}"
}

# --- CRUD -------------------------------------------------------------------

# users_add <name> [method] — full add flow. Method defaults to DEFAULT_METHOD.
users_add() {
  local name="${1-}"
  local method="${2:-${DEFAULT_METHOD}}"

  # Validate FIRST, before the name touches jq, a path, or any subshell word.
  _users_require_valid_name "$name"

  # Reject duplicates with a clear, non-zero error.
  if config_user_exists "$name"; then
    die "user already exists: $name"
  fi

  local port secret created host
  port="$(users_alloc_port)"
  secret="$(users_gen_secret "$method")"
  created="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # Persist via config.sh (single owner of the JSON), then regenerate config.json.
  config_user_add "$name" "$port" "$method" "$secret" "$created"
  config_generate

  # Complete the mutation chain: reload the service so it serves the new user,
  # then open the user's port (tcp+udp) — matching the install first-user path.
  # Both are guarded so a host without systemd/firewall still completes the add.
  _users_reload_service
  _users_open_firewall "$port"

  # Server address for the link: registry value if set, else a placeholder the
  # caller is expected to have resolved via lib/network.sh during install.
  host="$(config_get_server_address 2>/dev/null || true)"
  [ -n "$host" ] && [ "$host" != "null" ] || host="SERVER_ADDRESS"

  local uri
  uri="$(link_build "$method" "$secret" "$host" "$port" "$name")"
  link_write_access_file "$name" "$host" "$port" "$method" "$secret" "$uri"

  log_info "user added: $name (port $port, $method)"
  printf '%s\n' "$uri"
}

# users_del <name> — remove from registry and delete the per-user access file.
users_del() {
  local name="${1-}"
  _users_require_valid_name "$name"

  # Capture the port BEFORE removal so we can close it afterwards: once the
  # record is gone the registry no longer knows which port to free in the
  # firewall. config_user_show dies if the user is absent, so this also doubles
  # as the existence check before any mutation.
  local rec port
  rec="$(config_user_show "$name")"
  port="$(printf '%s' "$rec" | jq -r '.port')"

  # config_user_del already dies non-zero if the name is absent (not silent).
  config_user_del "$name"
  config_generate

  # Complete the mutation chain: reload the service so it stops serving the
  # removed user, then close that user's port (tcp+udp). Both guarded/non-fatal.
  _users_reload_service
  if [ -n "$port" ] && [ "$port" != "null" ]; then
    _users_close_firewall "$port"
  fi

  # Remove the access file using basename semantics (path-traversal safe).
  local base
  base="$(basename -- "$name")"
  rm -f "${SS_EASY_USERS_DIR}/${base}.txt"

  log_info "user deleted: $name"
}

# users_list — enumerate users without printing any secret.
users_list() {
  local name rec port method
  local any=0
  # config_list_names may omit a trailing newline on its last record, so the
  # final `read` returns non-zero while still having set $name — keep it with
  # the `|| [ -n "$name" ]` guard.
  while IFS= read -r name || [ -n "$name" ]; do
    [ -n "$name" ] || continue
    any=1
    rec="$(config_user_show "$name")"
    port="$(printf '%s' "$rec" | jq -r '.port')"
    method="$(printf '%s' "$rec" | jq -r '.method')"
    printf '%-32s  %-6s  %s\n' "$name" "$port" "$method"
  done < <(config_list_names)
  [ "$any" -eq 1 ] || log_info "no users configured"
}

# users_show <name> — print connection details + ss:// link for one user.
users_show() {
  local name="${1-}"
  _users_require_valid_name "$name"

  # config_user_show dies non-zero with a clear message if absent.
  local rec
  rec="$(config_user_show "$name")"

  local port method secret host
  port="$(printf '%s' "$rec" | jq -r '.port')"
  method="$(printf '%s' "$rec" | jq -r '.method')"
  secret="$(printf '%s' "$rec" | jq -r '.secret')"
  host="$(config_get_server_address 2>/dev/null || true)"
  [ -n "$host" ] && [ "$host" != "null" ] || host="SERVER_ADDRESS"

  local uri
  uri="$(link_build "$method" "$secret" "$host" "$port" "$name")"

  printf 'name   : %s\n' "$name"
  printf 'server : %s\n' "$host"
  printf 'port   : %s\n' "$port"
  printf 'method : %s\n' "$method"
  printf 'link   : %s\n' "$uri"
}
