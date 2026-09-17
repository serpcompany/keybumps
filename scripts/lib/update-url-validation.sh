#!/bin/zsh

update_url_has_safe_authority() {
  local candidate=$1
  [[ "$candidate" != *'#'* ]] || return 1
  local remainder=${candidate#*://}
  [[ "$remainder" != "$candidate" ]] || return 1
  local authority=${remainder%%/*}
  [[ -n "$authority" && "$authority" != *@* ]] || return 1
  if [[ "$authority" == \[* ]]; then
    [[ "$authority" =~ '^\[[^]]+\](:[0-9]+)?$' ]]
  else
    local host=${authority%%:*}
    [[ -n "$host" ]]
  fi
}

update_url_is_production_https() {
  local candidate=$1
  [[ "$candidate" == https://* ]] && update_url_has_safe_authority "$candidate"
}

update_url_is_loopback_fixture() {
  local candidate=$1
  [[ "$candidate" == http://* || "$candidate" == https://* ]] || return 1
  update_url_has_safe_authority "$candidate" || return 1
  local remainder=${candidate#*://}
  local authority=${remainder%%/*}
  [[ "$authority" =~ '^(localhost|127\.0\.0\.1)(:[0-9]+)?$' || "$authority" =~ '^\[::1\](:[0-9]+)?$' ]]
}
