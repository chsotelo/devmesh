#!/usr/bin/env bats
# dm app: the live single-screen panel (screen stack, enter/click/keys, background tick).

load helpers

setup() {
  export DM_LANG=es # these tests assert the Spanish catalog
  setup_client
  export DM_SELF="$REPO/client/bin/dm" COLUMNS=120
  DM_APP_STATE="$BATS_TEST_TMPDIR/app"
  mkdir -p "$DM_APP_STATE"
  export DM_APP_STATE
  dm_app_home
  t=$'\t'
}

@test "entering a machine pushes its screen and redraws everything, reload last" {
  run dm_app_enter machine lap - - ""
  [ "$status" -eq 0 ]
  [ "$(dm_app_top)" = "machine lap" ]
  [[ $output == clear-query+enable-search+* ]]
  [[ $output == *"transform-footer("*"_app header)"* && $output == *"transform-list-label("* ]]
  # fzf drops actions chained after reload-sync: it must be the last one.
  [[ $output == *"reload-sync("*"_app rows)" ]]
}

@test "back pops one screen; at home it only clears the query" {
  dm_app_push machine lap
  run dm_app_back
  [ "$(dm_app_top)" = home ]
  [[ $output == *reload-sync* ]]
  run dm_app_back
  [ "$output" = clear-query ]
  [ "$(dm_app_depth)" = 1 ]
}

@test "new terminal asks for the machine only when there is more than one" {
  run dm_app_action new
  [ "$(dm_app_top)" = new ]
  dm_app_home
  printf 'lap\tmachine\t10.73.0.2\t2202\t22\tdev\thome\t-\n' >"$DM_CACHE/hosts.tsv"
  run dm_app_action new
  [ "$(dm_app_top)" = "new2 lap" ]
}

@test "project screen: a project, the free row or unmatched text opens the terminal" {
  dm_app_push new2 lap
  run dm_app_enter proj redi - - ""
  [[ $output == "execute("*"_app open lap redi - proj:redi)+"* ]]
  [ "$(dm_app_top)" = home ]
  dm_app_push new2 lap
  run dm_app_enter "" "" "" "" "My API"
  [[ $output == *"_app open lap my-api - -)"* ]]
  dm_app_push new2 lap
  run dm_app_enter free - - - ""
  [[ $output == change-input-label*"escribe el nombre"* ]]
  [ "$(dm_app_top)" = "new2 lap" ]
}

@test "inside the workspace a terminal opens as a tab without leaving the panel" {
  TMUX=/tmp/fake,1,0 run dm_app_enter term lap redi 1 ""
  [[ $output == "execute-silent("*"_app open lap redi 1 -)" ]]
  run dm_app_enter term lap redi 1 ""
  [[ $output == "execute("*"_app open lap redi 1 -)" ]]
}

@test "add device validates the typed name before running dm add" {
  dm_app_push add
  run dm_app_enter create - - - "Bad Name"
  [[ $output == change-input-label* ]]
  run dm_app_enter create - - - "lap2"
  [[ $output == "execute("*"_app run add lap2)+"* ]]
  [ "$(dm_app_top)" = home ]
}

@test "top-bar buttons and hint words are clickable" {
  dm_app_push machine lap
  run dm_app_click volver
  [ "$(dm_app_top)" = home ]
  run dm_app_click "[enviar]"
  [[ $output == "execute("*"_app run send)+"* ]]
  run dm_app_click "[↻]"
  [[ $output == "execute-silent("*"_app run refresh)+"*"_app rows fresh)" ]]
  run dm_app_click salir
  [ "$output" = abort ]
  run dm_app_click nothing
  [ -z "$output" ]
}

@test "ctrl+n on a machine screen creates the terminal on that machine" {
  dm_app_push machine pc2
  run dm_app_key ctrl-n
  [ "$(dm_app_top)" = "new2 pc2" ]
}

@test "header shows back only below home and fits the list card" {
  run dm_app_header
  [[ $output != *volver* && $output == *"[nueva]"* ]]
  dm_app_push machine lap
  run dm_app_header
  [[ $output == *"‹ volver"* ]] || {
    printf 'header was: %q (depth %s)\n' "$output" "$(dm_app_depth)"
    false
  }
  COLUMNS=46 run dm_app_header
  [[ $output != *"[traer]"* ]]
}

@test "tick redraws home only when it changed, and never another screen" {
  ssh_reply lap "dm _who" "redi${t}1${t}redi:claude${t}1${t}claude${t}idle${t}-${t}1700000000${t}1700000000${t}-"$'\n'
  STUB_SSH_DOWN="pc2 pc2-b" dm_app_rows fresh >/dev/null
  STUB_SSH_DOWN="pc2 pc2-b" run dm_app_tick
  [ "$output" = refresh-preview ]
  ssh_reply lap "dm _who" "redi${t}1${t}redi:claude${t}1${t}claude${t}waiting${t}-${t}1700000000${t}1700000000${t}-"$'\n'
  STUB_SSH_DOWN="pc2 pc2-b" run dm_app_tick
  [[ $output == *"reload-sync("*"_app rows)+refresh-preview" ]]
  grep -q esperando "$DM_APP_STATE/home"
  dm_app_push machine lap
  cp "$DM_APP_STATE/rows" "$BATS_TEST_TMPDIR/before"
  run dm_app_tick
  [ "$output" = refresh-preview ]
  cmp -s "$DM_APP_STATE/rows" "$BATS_TEST_TMPDIR/before"
}

@test "going back home reuses the last rows instead of asking every machine again" {
  printf 'cached\n' >"$DM_APP_STATE/home"
  run dm_app_rows
  [ "$output" = cached ]
  ! grep -q "_who" "$STUB_LOG"
}

@test "project folders with unsafe names never reach fzf actions or the shell" {
  ssh_reply lap "dm _projects" $'redi\nmy app\nx);touch /tmp/pwn\n$(id)\napi.v2\n'
  dm_app_push new2 lap
  run dm_app_rows
  [[ $output == *"proj${t}redi${t}"* && $output == *"proj${t}api.v2${t}"* ]]
  [[ $output != *"my app"* && $output != *"pwn"* && $output != *'$(id)'* ]]
}

@test "project list is not cached when the machine did not answer" {
  dm_app_push new2 pc2
  STUB_SSH_DOWN="pc2 pc2-b" run dm_app_rows
  [[ $output == *"No se pudo leer pc2"* ]]
  [ ! -e "$DM_APP_STATE/new2.pc2" ]
}

@test "machine choice uses the last home rows instead of probing each machine" {
  printf 'machine\tlap\t-\t-\tx\noffline\tpc2\t-\t-\tx\n' >"$DM_APP_STATE/home"
  run dm_app_rows_new
  [[ ${lines[0]} == "ok${t}lap${t}"* && ${lines[1]} == "off${t}pc2${t}"* ]]
  ! grep -q "true" "$STUB_LOG"
}

@test "a tick is skipped while the previous one still runs" {
  mkdir "$DM_APP_STATE/tick.lock"
  run dm_app_tick
  [ "$output" = refresh-preview ]
  ! grep -q "_who" "$STUB_LOG"
}
