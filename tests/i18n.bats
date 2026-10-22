#!/usr/bin/env bats
# i18n: the English and Spanish catalogs stay in step and the UI follows the language.

load helpers

setup() {
  CAT="$REPO/client/lib/i18n"
}

# Catalog keys: the M_* names assigned in a catalog file.
catalog_keys() { sed -n 's/^\(M_[A-Z0-9_]*\)=.*/\1/p' "$1" | sort; }

# run_lang LANG CODE — evaluate CODE in a fresh shell that sources the libs after setting DM_LANG.
run_lang() {
  local lang=$1
  shift
  DM_LANG=$lang DM_SHARE="$REPO/client" DM_CONF="$BATS_TEST_TMPDIR/node.conf" DM_CACHE="$BATS_TEST_TMPDIR/cache" \
    HOME="$BATS_TEST_TMPDIR" run bash -c '
      for l in dm_core dm_remote dm_terms dm_files dm_admin dm_ui dm_app dm_workspace; do
        source "$1/client/lib/$l.sh"
      done
      shift
      eval "$@"' _ "$REPO" "$@"
}

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

@test "the action rows follow DM_LANG" {
  run_lang es 'dm_ui_action_rows'
  [ "$status" -eq 0 ]
  [[ $output == *"Nueva terminal"* ]]
  run_lang en 'dm_ui_action_rows'
  [ "$status" -eq 0 ]
  [[ $output == *"New terminal"* ]]
}

@test "the language falls back to LANG and then to English" {
  run env -u DM_LANG -u LC_ALL -u LC_MESSAGES LANG=es_PE.UTF-8 bash -c 'source "$1/client/lib/dm_core.sh"; dm_lang' _ "$REPO"
  [ "$output" = es ]
  run env -u DM_LANG -u LC_ALL -u LC_MESSAGES LANG=fr_FR.UTF-8 bash -c 'source "$1/client/lib/dm_core.sh"; dm_lang' _ "$REPO"
  [ "$output" = en ]
}

@test "clicking [new] (en) and [nueva] (es) reaches the same action" {
  mkdir -p "$BATS_TEST_TMPDIR/app"
  export DM_APP_STATE="$BATS_TEST_TMPDIR/app" DM_SELF="$REPO/client/bin/dm"
  setup_client_conf
  # The click prints fzf actions (with localized text); the screen it lands on is the action.
  run_lang en 'dm_load_conf; dm_app_home; dm_app_click "[new]" >/dev/null; dm_app_top'
  en_out=$output
  run_lang es 'dm_load_conf; dm_app_home; dm_app_click "[nueva]" >/dev/null; dm_app_top'
  [ "$en_out" = new ]
  [ "$output" = "$en_out" ]
}

setup_client_conf() {
  mkdir -p "$BATS_TEST_TMPDIR/cache"
  printf 'DM_NAME=tablet\nDM_KIND=phone\nDM_HUB_HOST=hub.example.test\n' >"$BATS_TEST_TMPDIR/node.conf"
  printf 'lap\tmachine\t10.73.0.2\t2202\t22\tdev\thome\taa:bb:cc:dd:ee:01\n' >"$BATS_TEST_TMPDIR/cache/hosts.tsv"
  printf 'pc2\tmachine\t10.73.0.3\t2203\t24\tdev\thome\t-\n' >>"$BATS_TEST_TMPDIR/cache/hosts.tsv"
}
