# shellcheck shell=bash
#
# lib/network.sh — public-IP auto-detection (Decision 12).
#
# PUBLIC CONTRACT (consumed by users.sh / install flow):
#   net_is_valid_ip <candidate>
#       exit 0 iff <candidate> is a syntactically valid IPv4 OR IPv6 address
#       and nothing else (no surrounding whitespace, no trailing text). A loose
#       match would let a third-party HTML/error body poison the ss:// link.
#   net_detect_public_ip [override]
#       if [override] is non-empty it must itself validate (explicit IP wins);
#       otherwise query each HTTPS source in order, validate the response, and
#       print the first valid address. Non-zero if no source yields a valid IP.
#
# curl is hardened to match Task 3's download policy: --fail, HTTPS only,
# TLS >= 1.2, no -k. A failing or non-IP response advances to the next source.

# Guard against double-sourcing in the assembled bundle / nested sources.
if [ -n "${_SS_EASY_NETWORK_LOADED:-}" ]; then
  # shellcheck disable=SC2317  # reached only on re-source of this module.
  return 0 2>/dev/null || true
fi
_SS_EASY_NETWORK_LOADED=1

# Independent public-IP echo endpoints, queried in order (Decision 12). Plain
# bodies (a bare IP) only — kept here as the single source of truth.
SS_IP_SOURCES="https://api.ipify.org https://ifconfig.co https://icanhazip.com"

# --- validation -------------------------------------------------------------

# _net_is_ipv4 <s> — strict dotted-quad with each octet 0-255, no extras.
_net_is_ipv4() {
  local s="$1" o1 o2 o3 o4
  # Anchored, single token; reject anything with stray characters/whitespace.
  [[ "$s" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  o1="${BASH_REMATCH[1]}"; o2="${BASH_REMATCH[2]}"
  o3="${BASH_REMATCH[3]}"; o4="${BASH_REMATCH[4]}"
  local oct
  for oct in "$o1" "$o2" "$o3" "$o4"; do
    # No leading zeros (e.g. "01") and within range.
    if [ "${#oct}" -gt 1 ] && [ "${oct:0:1}" = "0" ]; then return 1; fi
    if [ "$oct" -gt 255 ]; then return 1; fi
  done
  return 0
}

# _net_is_ipv6 <s> — accept canonical/compressed IPv6, including a single "::"
# compression and an optional embedded IPv4 tail. Conservative but anchored.
_net_is_ipv6() {
  local s="$1"

  # Must contain a colon and only hex digits, colons, and dots (for v4 tail).
  [[ "$s" =~ ^[0-9A-Fa-f:.]+$ ]] || return 1
  [[ "$s" == *:* ]] || return 1

  # At most one "::" compression group.
  local dcolons="${s//[^:]/}"
  case "$s" in
    *::*::*) return 1 ;;
  esac

  # Split on ':' and validate each hextet (last one may be an embedded IPv4).
  local IFS=':'
  read -ra parts <<< "$s"
  local i n="${#parts[@]}" part
  for ((i = 0; i < n; i++)); do
    part="${parts[i]}"
    [ -z "$part" ] && continue          # empty piece from "::" compression
    if [[ "$part" == *.* ]]; then
      # Only valid as the final group, and must be a valid IPv4.
      [ "$i" -eq $((n - 1)) ] || return 1
      _net_is_ipv4 "$part" || return 1
      continue
    fi
    # A hextet is 1-4 hex digits.
    [[ "$part" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
  done

  # Accept either a "::" compressed form, or the full uncompressed 8-group form
  # (exactly 7 colons). Anything else (too few groups, no compression) is invalid.
  if [[ "$s" == *::* ]]; then
    return 0
  fi
  [ "${#dcolons}" -eq 7 ]
}

# net_is_valid_ip <candidate> — IPv4 or IPv6, strict.
net_is_valid_ip() {
  local cand="$1"
  [ -n "$cand" ] || return 1
  _net_is_ipv4 "$cand" && return 0
  _net_is_ipv6 "$cand" && return 0
  return 1
}

# --- detection --------------------------------------------------------------

# _net_fetch <url> — hardened curl of a public-IP endpoint; trims trailing
# whitespace/newline. Prints the (untrusted) body; caller MUST validate it.
_net_fetch() {
  local url="$1" body
  body="$(curl --fail --silent --show-error \
               --proto '=https' --tlsv1.2 \
               --max-time 8 "$url" 2>/dev/null)" || return 1
  # Trim surrounding whitespace/newlines (some endpoints append "\n").
  body="${body#"${body%%[![:space:]]*}"}"
  body="${body%"${body##*[![:space:]]}"}"
  printf '%s' "$body"
}

# net_detect_public_ip [override] — see contract above.
net_detect_public_ip() {
  local override="${1:-}"

  if [ -n "$override" ]; then
    if net_is_valid_ip "$override"; then
      printf '%s\n' "$override"
      return 0
    fi
    die "provided IP is not a valid IPv4/IPv6 address: $override"
  fi

  local url body
  for url in $SS_IP_SOURCES; do
    body="$(_net_fetch "$url")" || { log_warn "public-IP source unreachable: $url"; continue; }
    if net_is_valid_ip "$body"; then
      printf '%s\n' "$body"
      return 0
    fi
    log_warn "public-IP source returned a non-IP response: $url"
  done

  log_error "could not auto-detect a public IP from any source; use manual override"
  return 1
}
