#!/usr/bin/env bats
# i18n: the English and Spanish catalogs stay in step and the UI follows the language.

load helpers

setup() {
  CAT="$REPO/client/lib/i18n"
}

# Catalog keys: the M_* names assigned in a catalog file.
catalog_keys() { sed -n 's/^\(M_[A-Z0-9_]*\)=.*/\1/p' "$1" | sort; }

@test "every key in es.sh exists in en.sh" {
  run comm -13 <(catalog_keys "$CAT/en.sh") <(catalog_keys "$CAT/es.sh")
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "no Spanish accents outside the catalogs" {
  # Byte patterns (C locale): a/e/i/o/u acute, n tilde, inverted ? and !.
  local pat
  pat=$(printf '\xc3[\xa1\xa9\xad\xb3\xba\xb1]|\xc2[\xbf\xa1]')
  LC_ALL=C run grep -rnIE "$pat" "$REPO/client" --exclude-dir=i18n
  [ -z "$output" ]
}

@test "the language falls back to LANG and then to English" {
  run env -u DM_LANG -u LC_ALL -u LC_MESSAGES LANG=es_PE.UTF-8 bash -c 'source "$1/client/lib/dm_core.sh"; dm_lang' _ "$REPO"
  [ "$output" = es ]
  run env -u DM_LANG -u LC_ALL -u LC_MESSAGES LANG=fr_FR.UTF-8 bash -c 'source "$1/client/lib/dm_core.sh"; dm_lang' _ "$REPO"
  [ "$output" = en ]
}
