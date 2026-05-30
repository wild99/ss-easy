# shellcheck shell=bash
#
# lib/tui.sh — whiptail presentation layer (Task 10).
#
# A guided, menu-driven front end so a non-technical operator can run EVERY
# ss-easy operation without typing a command or a flag. This module is
# presentation-only: it collects input via whiptail dialogs and then calls the
# EXISTING lib/*.sh functions (service.sh, users.sh, config.sh, link.sh,
# uninstall.sh). It owns no business logic and never parses users.json itself —
# the registry is read through config_list_names / config_get_server_address.
#
# PUBLIC CONTRACT (consumed by the ss-easy dispatcher: `ss-easy tui` / no-arg):
#   tui_main                            render the main menu loop; exit 0 on
#                                       cancel/ESC at the top level.
#
# whiptail facts this module is built around (see tech-spec reality-check):
#   * whiptail writes the SELECTED VALUE to STDERR, not stdout. Every capture
#     therefore uses the FD-swap `3>&1 1>&2 2>&3` so the value lands on stdout
#     of the command substitution. Without it every read comes back empty.
#   * Under `set -euo pipefail`, a non-zero return from a dialog (user cancels)
#     or from a called lib function fires errexit before the next dialog can
#     render. So every whiptail/lib call is guarded with `if`/`||`; a failure is
#     captured, surfaced in a --msgbox, and control returns to the menu.
#
# Untrusted input (the inputbox name) is passed STRAIGHT to users_add, which
# validates it against ^[A-Za-z0-9_-]{1,32}$ before it reaches jq or a path.
# This module never evals it and never interpolates it into a jq program.

# Guard against double-sourcing in the assembled bundle / nested sources.
if [ -n "${_SS_EASY_TUI_LOADED:-}" ]; then
  # shellcheck disable=SC2317  # reached only on re-source of this module.
  return 0 2>/dev/null || true
fi
_SS_EASY_TUI_LOADED=1

# Depend on common.sh (logging, die). In the assembled bundle the modules are
# inlined and the guard is already set, so this is a no-op there; in dev/test the
# module sources its sibling so it is usable standalone.
# build:strip-start
if [ -z "${_SS_EASY_COMMON_LOADED:-}" ]; then
  _ss_tui_self="${BASH_SOURCE[0]}"
  _ss_tui_dir="${_ss_tui_self%/*}"
  [ "$_ss_tui_dir" = "$_ss_tui_self" ] && _ss_tui_dir="."
  # shellcheck source=lib/common.sh disable=SC1091
  . "${_ss_tui_dir}/common.sh"
  unset _ss_tui_self _ss_tui_dir
fi
# build:strip-end

# Dialog geometry. Constants so every dialog is consistent and easy to tune.
_TUI_H=20
_TUI_W=72
_TUI_MENU_ROWS=10
_TUI_TITLE="ss-easy"

# --- thin whiptail wrappers -------------------------------------------------
#
# Each wrapper is the single seam the tests stub: they call the `whiptail` binary
# directly with the mandatory FD-swap. Keeping them tiny means the routing logic
# below reads as plain control flow, not dialog plumbing.

# _tui_menu <title> <prompt> <tag1> <item1> [<tag2> <item2> ...]
# Render a --menu and print the chosen TAG on stdout. Returns whiptail's rc
# (non-zero when the user cancels / hits ESC), so callers can guard on it.
_tui_menu() {
  local title="$1" prompt="$2"; shift 2
  whiptail --title "$title" --menu "$prompt" \
    "$_TUI_H" "$_TUI_W" "$_TUI_MENU_ROWS" "$@" \
    3>&1 1>&2 2>&3
}

# _tui_input <title> <prompt> [default] — render an --inputbox, print the entered
# value on stdout. Returns non-zero when the user cancels.
_tui_input() {
  local title="$1" prompt="$2" def="${3:-}"
  whiptail --title "$title" --inputbox "$prompt" \
    "$_TUI_H" "$_TUI_W" "$def" \
    3>&1 1>&2 2>&3
}

# _tui_msg <title> <text> — show a --msgbox (acknowledged with OK). The FD-swap
# is harmless here (no value to capture) but kept for a uniform call shape.
_tui_msg() {
  local title="$1" text="$2"
  whiptail --title "$title" --msgbox "$text" "$_TUI_H" "$_TUI_W" 3>&1 1>&2 2>&3
}

# _tui_yesno <title> <text> — confirmation dialog. Returns 0 for Yes, non-zero
# for No / ESC. Used as the guard itself (no value capture needed).
_tui_yesno() {
  local title="$1" text="$2"
  whiptail --title "$title" --yesno "$text" "$_TUI_H" "$_TUI_W" 3>&1 1>&2 2>&3
}

# _tui_scroll <title> <text> — long output (link + QR) in a scrollable box. The
# --scrolltext flag lets the operator scroll past the QR block.
_tui_scroll() {
  local title="$1" text="$2"
  whiptail --title "$title" --scrolltext --msgbox "$text" \
    "$_TUI_H" "$_TUI_W" 3>&1 1>&2 2>&3
}

# --- error capture helper ---------------------------------------------------

# _tui_run <var> <fn> [args...] — call a lib function with stdout captured into
# the named variable and stderr captured into a temp file. On non-zero rc, show
# the stderr (the lib function's own die/log_error message) in a --msgbox and
# return that rc so the caller can `continue`. On success, the captured stdout is
# available in <var>. This is the single place errexit-safety + error surfacing
# is implemented, so handlers stay declarative.
_tui_run() {
  local __outvar="$1"; shift
  local __errf __out __rc
  __errf="$(mktemp "${TMPDIR:-/tmp}/.ss-easy-tui.XXXXXX")"

  __rc=0
  # Disable errexit only for this single guarded call so a non-zero rc is
  # observed here instead of aborting the whole TUI.
  __out="$("$@" 2>"$__errf")" || __rc=$?

  if [ "$__rc" -ne 0 ]; then
    local __msg
    __msg="$(cat "$__errf" 2>/dev/null)"
    [ -n "$__msg" ] || __msg="operation failed (exit ${__rc})."
    rm -f "$__errf"
    _tui_msg "Error" "$__msg" || true
    return "$__rc"
  fi

  rm -f "$__errf"
  printf -v "$__outvar" '%s' "$__out"
  return 0
}

# --- server address helper --------------------------------------------------

# _tui_server_addr — print the configured server address, or a placeholder when
# the registry has none yet. Read-only; never mutates. Guarded so a missing
# registry is a placeholder, not a crash.
_tui_server_addr() {
  local host
  host="$(config_get_server_address 2>/dev/null || true)"
  if [ -z "$host" ] || [ "$host" = "null" ]; then
    host="SERVER_ADDRESS"
  fi
  printf '%s' "$host"
}

# --- service submenu --------------------------------------------------------

# _tui_service_menu — loop the service-control submenu. Shows the live status
# line at the top, then offers the six lifecycle verbs. Each verb calls the
# matching service.sh function via _tui_run so errors are surfaced, not fatal.
_tui_service_menu() {
  local choice status_line
  while :; do
    # Current state for the prompt (service_status returns non-zero when
    # inactive; we want the text either way, so guard it).
    status_line="$(service_status 2>&1 || true)"

    if ! choice="$(_tui_menu "$_TUI_TITLE — Service" \
        "Current status:\n${status_line}\n\nChoose an action:" \
        start    "Start the service" \
        stop     "Stop the service" \
        restart  "Restart the service" \
        status   "Show service status" \
        enable   "Enable at boot" \
        disable  "Disable at boot")"; then
      return 0   # cancel/ESC -> back to main menu.
    fi

    local _out
    case "$choice" in
      start)   if _tui_run _out service_start;   then _tui_msg "Service" "Service started." || true; fi ;;
      stop)    if _tui_run _out service_stop;    then _tui_msg "Service" "Service stopped." || true; fi ;;
      restart) if _tui_run _out service_restart; then _tui_msg "Service" "Service restarted." || true; fi ;;
      enable)  if _tui_run _out service_enable;  then _tui_msg "Service" "Service enabled at boot." || true; fi ;;
      disable) if _tui_run _out service_disable; then _tui_msg "Service" "Service disabled at boot." || true; fi ;;
      status)
        status_line="$(service_status 2>&1 || true)"
        _tui_msg "Service status" "$status_line" || true
        ;;
      *) : ;;
    esac
  done
}

# --- users submenu ----------------------------------------------------------

# _tui_pick_user <title> <prompt> — build a --menu from the live registry and
# print the chosen user name. Returns 1 (no output) when the registry is empty
# so callers can show a friendly "no users" message; returns whiptail's rc on
# cancel. Built ONLY from config_list_names — never re-reads users.json.
_tui_pick_user() {
  local title="$1" prompt="$2"
  local -a items=()
  local name
  while IFS= read -r name || [ -n "$name" ]; do
    [ -n "$name" ] || continue
    items+=("$name" "")
  done < <(config_list_names 2>/dev/null || true)

  if [ "${#items[@]}" -eq 0 ]; then
    return 1   # empty registry sentinel.
  fi

  whiptail --title "$title" --menu "$prompt" \
    "$_TUI_H" "$_TUI_W" "$_TUI_MENU_ROWS" "${items[@]}" \
    3>&1 1>&2 2>&3
}

# _tui_user_add — prompt for a name and add the user, then show the generated
# ss:// link plus its QR. Empty/cancelled input never reaches users_add.
_tui_user_add() {
  local name uri qr
  if ! name="$(_tui_input "$_TUI_TITLE — Add user" \
      "Enter a user name (letters, digits, _ or -, up to 32 chars):")"; then
    return 0   # cancelled -> back to users menu.
  fi
  if [ -z "$name" ]; then
    _tui_msg "Add user" "No name entered; nothing was added." || true
    return 0
  fi

  # users_add validates the name itself; pass it straight through. On failure its
  # message is surfaced by _tui_run and we return to the menu.
  if ! _tui_run uri users_add "$name"; then
    return 0
  fi

  qr="$(link_render_qr "$uri" 2>/dev/null || true)"
  _tui_scroll "User added: $name" \
    "User '${name}' was added.

Connection link:
${uri}

QR code:
${qr}" || true
}

# _tui_user_del — pick an existing user, confirm, then delete.
_tui_user_del() {
  local name _out
  if ! name="$(_tui_pick_user "$_TUI_TITLE — Delete user" "Select a user to delete:")"; then
    _tui_msg "Delete user" "There are no users yet." || true
    return 0
  fi
  [ -n "$name" ] || return 0   # cancelled the picker.

  if ! _tui_yesno "Delete user" \
      "Delete user '${name}'? This removes the user, their port rule and access file."; then
    return 0   # declined.
  fi

  if ! _tui_run _out users_del "$name"; then
    return 0
  fi
  _tui_msg "Delete user" "User '${name}' was deleted." || true
}

# _tui_user_list — show the registry contents in a msgbox.
_tui_user_list() {
  local listing
  listing="$(users_list 2>&1 || true)"
  [ -n "$listing" ] || listing="No users configured yet."
  _tui_msg "Users" "$listing" || true
}

# _tui_user_show — pick a user, then show their link, QR and access-file path.
_tui_user_show() {
  local name details uri qr
  if ! name="$(_tui_pick_user "$_TUI_TITLE — Show user" "Select a user to show:")"; then
    _tui_msg "Show user" "There are no users yet." || true
    return 0
  fi
  [ -n "$name" ] || return 0

  if ! _tui_run details users_show "$name"; then
    return 0
  fi

  # users_show prints "link   : ss://..."; pull the URI for the QR render.
  uri="$(printf '%s\n' "$details" | sed -n 's/^link[[:space:]]*:[[:space:]]*//p' | head -n1)"
  qr=""
  [ -n "$uri" ] && qr="$(link_render_qr "$uri" 2>/dev/null || true)"

  _tui_scroll "User: $name" \
    "${details}

Access file: ${SS_EASY_USERS_DIR}/${name}.txt

QR code:
${qr}" || true
}

# _tui_users_menu — loop the users submenu.
_tui_users_menu() {
  local choice
  while :; do
    if ! choice="$(_tui_menu "$_TUI_TITLE — Users" "Choose a user operation:" \
        add  "Add a new user" \
        del  "Delete a user" \
        list "List all users" \
        show "Show a user's link + QR")"; then
      return 0   # cancel/ESC -> back to main menu.
    fi

    case "$choice" in
      add)  _tui_user_add ;;
      del)  _tui_user_del ;;
      list) _tui_user_list ;;
      show) _tui_user_show ;;
      *) : ;;
    esac
  done
}

# --- server info ------------------------------------------------------------

# _tui_server_info — read-only summary: public IP/address, service state +
# listening ports, and user count. Reuses service_status and config_list_names;
# no detection logic is duplicated here.
_tui_server_info() {
  local host status_line count
  host="$(_tui_server_addr)"
  status_line="$(service_status 2>&1 || true)"

  count=0
  local name
  while IFS= read -r name || [ -n "$name" ]; do
    [ -n "$name" ] && count=$((count + 1))
  done < <(config_list_names 2>/dev/null || true)

  _tui_msg "Server info" \
    "Server address : ${host}

Service status :
${status_line}

Configured users: ${count}" || true
}

# --- uninstall --------------------------------------------------------------

# _tui_uninstall — gate the full purge behind an explicit yes/no warning, then
# call the uninstall module. do_uninstall lives in lib/uninstall.sh; if it is
# not present in this build, say so instead of failing obscurely.
_tui_uninstall() {
  if ! _tui_yesno "Uninstall ss-easy" \
      "This will REMOVE the service, configuration, binary and ALL users.

This cannot be undone. Continue?"; then
    return 0   # declined -> nothing happens.
  fi

  if ! declare -F do_uninstall >/dev/null 2>&1; then
    _tui_msg "Uninstall" "Uninstall is not available in this build." || true
    return 0
  fi

  local _out
  if ! _tui_run _out do_uninstall --yes; then
    return 0
  fi
  _tui_msg "Uninstall" "ss-easy was removed." || true
}

# --- main menu --------------------------------------------------------------

# tui_main — public entrypoint. Guards whiptail's presence with an actionable
# message, then loops the top-level menu. Cancel/ESC at this level exits 0.
tui_main() {
  if ! command -v whiptail >/dev/null 2>&1; then
    log_error "whiptail not found: the interactive menu needs the 'whiptail' (newt) package."
    log_error "install it (Debian: 'apt-get install whiptail', RHEL: 'dnf install newt'),"
    log_error "or use the command-line interface, e.g. 'ss-easy user add <name>'."
    return 1
  fi

  local choice
  while :; do
    if ! choice="$(_tui_menu "$_TUI_TITLE" "Select an operation:" \
        service   "Service control (start/stop/restart/status...)" \
        users     "Manage users (add/del/list/show)" \
        info      "Server info" \
        uninstall "Uninstall ss-easy")"; then
      return 0   # cancel/ESC at the top level -> clean exit.
    fi

    case "$choice" in
      service)   _tui_service_menu ;;
      users)     _tui_users_menu ;;
      info)      _tui_server_info ;;
      uninstall) _tui_uninstall ;;
      *) : ;;
    esac
  done
}
