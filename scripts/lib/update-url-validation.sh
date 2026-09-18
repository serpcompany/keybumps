#!/bin/zsh

typeset -gr UPDATE_URL_VALIDATOR="${${(%):-%N}:A:h}/update_url_validation.py"

update_url_is_production_https() {
  /usr/bin/python3 "$UPDATE_URL_VALIDATOR" production "$1"
}

update_url_is_loopback_fixture() {
  /usr/bin/python3 "$UPDATE_URL_VALIDATOR" fixture "$1"
}

update_url_parent_prefix() {
  /usr/bin/python3 "$UPDATE_URL_VALIDATOR" parent "$1"
}

update_url_is_keybumps_feed() {
  [[ "$1" == "https://updates.keybumps.app/appcast.xml" || \
     "$1" == "https://updates.keybumps.app/staging/appcast.xml" ]]
}
