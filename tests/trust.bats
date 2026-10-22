#!/usr/bin/env bats
# OSS-20/21/22: approvers sign device keys, host keys and the client bundle with
# "ssh-keygen -Y sign"; every device verifies against its local allowed_signers. Real keys and
# signatures; the hub is the real hub code with the usual stubs.

load helpers

setup() {
  setup_hub
  setup_client
  # shellcheck source=/dev/null
  source "$REPO/client/lib/bootstrap_common.sh"
  K=$BATS_TEST_TMPDIR/keys
  mkdir -p "$K"
  export STUB_ADMIN_CMD="bash '$REPO/server/sbin/devmesh' _ssh tablet"
  export DM_TEST=1
}

pubof() { awk '{print $1 " " $2}' "$1.pub"; }

# enroll_dev NAME KIND [invite flags...] — keys under $K/NAME-{client,tunnel,host}.
enroll_dev() {
  local name=$1 kind=$2 code
  shift 2
  devmesh invite "$name" "$@" >/dev/null
  code=$(invite_code)
  {
    printf 'kind %s\nwg %s\n' "$kind" "$(new_wg_pub)"
    printf 'client %s\n' "$(new_ssh_pub "$K/$name-client")"
    if [[ $kind == machine ]]; then
      printf 'tunnel %s\nhost %s\nuser dev\n' "$(new_ssh_pub "$K/$name-tunnel")" "$(new_ssh_pub "$K/$name-host")"
    fi
  } | devmesh _enroll "$code" >/dev/null
}

# The owner device is this test's "tablet": its key is ~/.ssh/id_devmesh.
enroll_owner() {
  local code
  devmesh invite tablet --phone --owner >/dev/null
  code=$(invite_code)
  printf 'kind phone\nwg %s\nclient %s\n' "$(new_wg_pub)" "$(new_ssh_pub "$HOME/.ssh/id_devmesh")" |
    devmesh _enroll "$code" >/dev/null
  DM_NAME=tablet DM_OWNER=1 bs_trust_setup "$(dm_allowed_signers)" "$HOME/.ssh/id_devmesh.pub"
  printf 'DM_TRUST=signed\n' >>"$DM_CONF"
  DM_TRUST=signed
}

reg() { awk -F'\t' -v n="$1" -v c="$2" '$1 == n {print $c}' "$DEVMESH_ETC/registry.tsv"; }
sig_col() { reg "$1" 16; }
admin() { SSH_ORIGINAL_COMMAND=$1 devmesh _ssh "${2:-tablet}"; }

# sign KEYFILE KIND NAME PUBKEY
sign() { tr_sign "$1" "$(tr_msg "$2" "$3" "$4")"; }
owner_sign() { sign "$HOME/.ssh/id_devmesh" "$@"; }

# --- hub: registry and owner -------------------------------------------------------------
@test "registry: 15-column rows (0.7) gain a pending sig column" {
  printf 'old\tphone\t10.73.0.9\t-\t-\t-\t-\t-\t%s\t%s\t-\t-\t2026-01-01T00:00Z\t-\tandroid\n' "$(new_wg_pub)" "$(new_ssh_pub "$K/o")" >>"$DEVMESH_ETC/registry.tsv"
  run devmesh hosts
  [ "$status" -eq 0 ]
  [ "$(sig_col old)" = "-" ]
}

@test "invite --owner makes the first approver; a second owner invite is refused" {
  mkdir -p "$HOME/.ssh"
  enroll_owner
  [ "$(sig_col tablet)" = owner ]
  run cat "$DEVMESH_ETC/signers.tsv"
  [[ $output == "tablet"$'\t'"$(pubof "$HOME/.ssh/id_devmesh")"$'\t'owner ]]
  run devmesh invite pc9 --owner
  [ "$status" -ne 0 ]
  [[ $output == *"already has an approver"* ]]
}

@test "a device joining without --owner is pending, not in the synced key list" {
  enroll_owner
  enroll_dev lap machine
  [ "$(sig_col lap)" = "-" ]
  run devmesh ls
  [[ $output == *"lap"*"(pending approval)"* ]]
  ! grep -q 'devmesh:lap' "$DEVMESH_ETC/clients.pub"
  grep -q 'devmesh:tablet' "$DEVMESH_ETC/clients.pub" # the approver's own key still syncs
  ! grep -q '^client lap ' "$DEVMESH_ETC/clients.bundle"
}

@test "a hub without approvers behaves as before: everyone is in clients.pub" {
  enroll_dev lap machine
  grep -q 'devmesh:lap' "$DEVMESH_ETC/clients.pub"
  run devmesh ls
  [[ $output != *pending\ approval* ]]
}

# --- hub: approve ----------------------------------------------------------------------------
@test "approve: a valid client+host signature approves the machine and feeds the bundle" {
  enroll_owner
  enroll_dev lap machine
  run admin pending
  [[ $output == lap$'\t'machine$'\t'"$(pubof "$K/lap-client")"* ]]
  [[ $output == *client+host ]]
  c=$(owner_sign client lap "$(pubof "$K/lap-client")")
  h=$(owner_sign host lap "$(pubof "$K/lap-host")")
  run admin "approve lap" <<<"client $c"$'\n'"host $h"
  [ "$status" -eq 0 ]
  [ "$(sig_col lap)" = "$c:$h" ]
  grep -qx "client lap $(pubof "$K/lap-client") $c" "$DEVMESH_ETC/clients.bundle"
  grep -qx "host lap $(pubof "$K/lap-host") $h" "$DEVMESH_ETC/clients.bundle"
  grep -q 'devmesh:lap' "$DEVMESH_ETC/clients.pub"
  run admin pending
  [ -z "$output" ]
}

@test "approve: refuses signatures that are not an approver's, for another key or malformed" {
  enroll_owner
  enroll_dev lap machine
  enroll_dev pc2 machine
  mkdir -p "$K/evil"
  ssh-keygen -q -t ed25519 -N '' -f "$K/evil/k"
  bad=$(sign "$K/evil/k" client lap "$(pubof "$K/lap-client")")
  run admin "approve lap" <<<"client $bad"
  [ "$status" -ne 0 ]
  [[ $output == *"does not verify"* ]]
  # A real approver signature, but over pc2's key.
  other=$(owner_sign client lap "$(pubof "$K/pc2-client")")
  run admin "approve lap" <<<"client $other"
  [ "$status" -ne 0 ]
  run admin "approve lap" <<<"client not-a-signature"
  [ "$status" -ne 0 ]
  run admin "approve lap" <<<"bogus $bad"
  [ "$status" -ne 0 ]
  [ "$(sig_col lap)" = "-" ]
}

@test "approve: only approvers may call it, and the owner needs no client signature" {
  enroll_owner
  enroll_dev lap machine
  c=$(owner_sign client lap "$(pubof "$K/lap-client")")
  run admin "approve lap" <<<"client $c" lap
  [ "$status" -ne 0 ]
  [[ $output == *"only an approver"* ]]
  s=$(owner_sign client tablet "$(pubof "$HOME/.ssh/id_devmesh")")
  run admin "approve tablet" <<<"client $s"
  [ "$status" -ne 0 ]
  [[ $output == *"is the owner"* ]]
}

@test "approve: a host signature is only for machines" {
  enroll_owner
  enroll_dev tab2 phone
  h=$(owner_sign host tab2 "$(pubof "$K/tab2-client")")
  run admin "approve tab2" <<<"host $h"
  [ "$status" -ne 0 ]
  [[ $output == *"not a machine"* ]]
}

@test "approve --signer: a second approver is added and may approve" {
  enroll_owner
  enroll_dev lap machine
  enroll_dev tab2 phone
  p=$(pubof "$K/tab2-client")
  c=$(owner_sign client tab2 "$p")
  s=$(owner_sign signer tab2 "$p")
  run admin "approve tab2" <<<"client $c"$'\n'"signer $s"
  [ "$status" -eq 0 ]
  grep -qx "signer tab2 $p $s" "$DEVMESH_ETC/clients.bundle"
  lc=$(sign "$K/tab2-client" client lap "$(pubof "$K/lap-client")")
  run admin "approve lap" <<<"client $lc" tab2
  [ "$status" -eq 0 ]
}

@test "remove: the last approver cannot be removed; others can" {
  enroll_owner
  enroll_dev tab2 phone
  run devmesh remove tablet --confirm tablet
  [ "$status" -ne 0 ]
  [[ $output == *"last approver"* ]]
  run devmesh remove tab2 --confirm tab2
  [ "$status" -eq 0 ]
}

@test "owner <device> (migration): existing devices keep their access until signed" {
  enroll_dev lap machine
  enroll_dev tablet phone
  run devmesh owner tablet
  [ "$status" -eq 0 ]
  [ "$(sig_col tablet)" = owner ]
  [ "$(sig_col lap)" = legacy ]
  grep -q 'devmesh:lap' "$DEVMESH_ETC/clients.pub"
  ! grep -q '^client lap ' "$DEVMESH_ETC/clients.bundle"
  run devmesh pending
  [[ $output == lap$'\t'* ]]
  run devmesh owner lap
  [ "$status" -ne 0 ]
}

@test "keys-out: keys serves the bare list, keys2 the signed bundle" {
  enroll_owner
  enroll_dev lap machine
  home="$DEVMESH_STATE/home/tunnel"
  mkdir -p "$home"
  run env HOME="$home" DEVMESH_CLIENTS_PUB="$DEVMESH_ETC/clients.pub" DEVMESH_BUNDLE="$DEVMESH_ETC/clients.bundle" \
    SSH_ORIGINAL_COMMAND="keys 0.7.0" sh "$REPO/server/sbin/devmesh-keys-out" lap
  [ "$output" = "$(cat "$DEVMESH_ETC/clients.pub")" ]
  run env HOME="$home" DEVMESH_CLIENTS_PUB="$DEVMESH_ETC/clients.pub" DEVMESH_BUNDLE="$DEVMESH_ETC/clients.bundle" \
    SSH_ORIGINAL_COMMAND="keys2 0.8.0" sh "$REPO/server/sbin/devmesh-keys-out" lap
  [[ $output == "signer tablet "* ]]
  [ "$(cat "$home/versions/lap")" = 0.8.0 ]
}

@test "dist: serves the uploaded signed bundle and its signature, else builds an unsigned one" {
  enroll_owner
  run admin "dist sig"
  [ "$status" -ne 0 ]
  [[ $output == *"no signed bundle"* ]]
  mkdir -p "$DEVMESH_SHARE/dist"
  printf 'tgz' >"$DEVMESH_SHARE/dist/dist.tgz"
  printf 'SIG\n' >"$DEVMESH_SHARE/dist/dist.sig"
  run admin "dist"
  [ "$output" = tgz ]
  run admin "dist sig"
  [ "$output" = SIG ]
  rm -rf "$DEVMESH_SHARE/dist"
  run bash -c "bash '$REPO/server/sbin/devmesh' dist | tar -tzf - | grep -cx VERSION"
  [ "$output" = 1 ]
}

# --- crypto: tr_verify / tr_process_bundle ---------------------------------------------------
mk_approvers() {
  mkdir -p "$K/a" "$K/b"
  ssh-keygen -q -t ed25519 -N '' -f "$K/a/k"
  ssh-keygen -q -t ed25519 -N '' -f "$K/b/k"
  AL=$BATS_TEST_TMPDIR/allowed
  tr_allowed_line alice "$(pubof "$K/a/k")" >"$AL"
  tr_new_client="$(new_ssh_pub "$K/newc")"
}

@test "verify: valid signature passes; altered message, other namespace, unknown signer and tampered signature fail" {
  mk_approvers
  msg=$(tr_msg client lap "$tr_new_client")
  sig=$(tr_sign "$K/a/k" "$msg")
  run tr_verify "$AL" "$sig" "$msg"
  [ "$status" -eq 0 ]
  [ "$output" = alice ]
  run tr_verify "$AL" "$sig" "$(tr_msg client pc2 "$tr_new_client")"
  [ "$status" -ne 0 ]
  other=$(printf '%s\n' "$msg" | ssh-keygen -Y sign -f "$K/a/k" -n other 2>/dev/null | base64 | tr -d '\n')
  run tr_verify "$AL" "$other" "$msg"
  [ "$status" -ne 0 ]
  run tr_verify "$AL" "$(tr_sign "$K/b/k" "$msg")" "$msg"
  [ "$status" -ne 0 ]
  run tr_verify "$AL" "${sig:0:200}A${sig:201}" "$msg"
  [ "$status" -ne 0 ]
}

@test "bundle: only entries with a valid approver signature are accepted" {
  mk_approvers
  good=$(pubof "$K/newc")
  new_ssh_pub "$K/c2" >/dev/null
  new_ssh_pub "$K/c3" >/dev/null
  {
    printf 'client ok %s %s\n' "$good" "$(tr_sign "$K/a/k" "$(tr_msg client ok "$good")")"
    printf 'client unsigned %s %s\n' "$(pubof "$K/c2")" "$(printf 'A%.0s' {1..120})"
    printf 'client stranger %s %s\n' "$(pubof "$K/c3")" "$(tr_sign "$K/b/k" "$(tr_msg client stranger "$(pubof "$K/c3")")")"
    printf 'host ok %s %s\n' "$good" "$(tr_sign "$K/a/k" "$(tr_msg host ok "$good")")"
    printf 'host swapped %s %s\n' "$(pubof "$K/c2")" "$(tr_sign "$K/a/k" "$(tr_msg host swapped "$good")")"
  } >"$BATS_TEST_TMPDIR/bundle"
  out=$(tr_process_bundle "$AL" "$BATS_TEST_TMPDIR/bundle" 0 2>"$BATS_TEST_TMPDIR/err")
  [[ $out == *"client ok $good"* && $out == *"host ok $good"* ]]
  [[ $out != *unsigned* && $out != *stranger* && $out != *swapped* ]]
  [ "$(grep -c dropped "$BATS_TEST_TMPDIR/err")" -eq 3 ]
}

@test "bundle: a signer the hub adds without an approver's signature is rejected and the file stays intact" {
  mk_approvers
  before=$(cat "$AL")
  {
    printf 'signer mallory %s %s\n' "$(pubof "$K/b/k")" "$(tr_sign "$K/b/k" "$(tr_msg signer mallory "$(pubof "$K/b/k")")")"
    printf 'signer owner2 %s owner\n' "$(pubof "$K/b/k")"
    printf 'client mallory %s %s\n' "$(pubof "$K/b/k")" "$(tr_sign "$K/b/k" "$(tr_msg client mallory "$(pubof "$K/b/k")")")"
  } >"$BATS_TEST_TMPDIR/bundle"
  out=$(tr_process_bundle "$AL" "$BATS_TEST_TMPDIR/bundle" 1 2>"$BATS_TEST_TMPDIR/err")
  [ -z "$out" ]
  [ "$(grep -c dropped "$BATS_TEST_TMPDIR/err")" -eq 3 ]
  [ "$(cat "$AL")" = "$before" ]
}

@test "bundle: an approver signed by an existing approver is added to allowed_signers" {
  mk_approvers
  p=$(pubof "$K/b/k")
  printf 'signer bob %s %s\n' "$p" "$(tr_sign "$K/a/k" "$(tr_msg signer bob "$p")")" >"$BATS_TEST_TMPDIR/bundle"
  # bob's own client key signed by bob (chain: alice -> bob) in the same bundle
  printf 'client bob %s %s\n' "$p" "$(tr_sign "$K/b/k" "$(tr_msg client bob "$p")")" >>"$BATS_TEST_TMPDIR/bundle"
  out=$(tr_process_bundle "$AL" "$BATS_TEST_TMPDIR/bundle" 1)
  [[ $out == *"signer bob $p"* && $out == *"client bob $p"* ]]
  grep -qxF "$(tr_allowed_line bob "$p")" "$AL"
}

@test "bundle: unparseable bundle fails (status 2), no allowed_signers fails (status 3)" {
  mk_approvers
  printf 'client lap ssh-ed25519 AAAA nope\n' >"$BATS_TEST_TMPDIR/bundle"
  run tr_process_bundle "$AL" "$BATS_TEST_TMPDIR/bundle"
  [ "$status" -eq 2 ]
  printf 'what is this\n' >"$BATS_TEST_TMPDIR/bundle"
  run tr_process_bundle "$AL" "$BATS_TEST_TMPDIR/bundle"
  [ "$status" -eq 2 ]
  run tr_process_bundle "$BATS_TEST_TMPDIR/none" "$BATS_TEST_TMPDIR/bundle"
  [ "$status" -eq 3 ]
}

# --- machine: devmesh-node keys-sync ---------------------------------------------------------
node_env() {
  export NODE_ETC=$BATS_TEST_TMPDIR/node NODE_STATE=$BATS_TEST_TMPDIR/nstate NODE_SHARE=$BATS_TEST_TMPDIR/nshare
  export STUB_SSH_DIR=$BATS_TEST_TMPDIR/replies
  mkdir -p "$NODE_ETC" "$NODE_SHARE" "$STUB_SSH_DIR/tunnel@hub.example.test"
  cp "$REPO/VERSION" "$NODE_SHARE/VERSION"
  ln -sfn "$REPO/client/lib" "$NODE_SHARE/lib"
  printf 'DM_NAME=lap\nDM_PORT=2202\nDM_HUB_HOST=hub.example.test\nDM_TRUST=%s\n' "${1:-signed}" >"$NODE_ETC/node.conf"
  VER=$(cat "$REPO/VERSION")
}

@test "node signed: installs only approved keys, drops the key the hub injected" {
  enroll_owner
  enroll_dev lap machine
  enroll_dev pc2 machine
  c=$(owner_sign client lap "$(pubof "$K/lap-client")")
  h=$(owner_sign host lap "$(pubof "$K/lap-host")")
  admin "approve lap" <<<"client $c"$'\n'"host $h" >/dev/null
  node_env
  cp "$(dm_allowed_signers)" "$NODE_ETC/allowed_signers"
  # root on the hub: pc2 is in the registry and clients.pub, plus a key it just made up.
  ssh-keygen -q -t ed25519 -N '' -f "$K/injected"
  printf '%s devmesh:injected\n' "$(pubof "$K/injected")" >>"$DEVMESH_ETC/clients.pub"
  printf 'client injected %s %s\n' "$(pubof "$K/injected")" "$(printf 'A%.0s' {1..120})" >>"$DEVMESH_ETC/clients.bundle"
  cp "$DEVMESH_ETC/clients.bundle" "$STUB_SSH_DIR/tunnel@hub.example.test/keys2_$VER"
  run bash "$REPO/client/sbin/devmesh-node" keys-sync
  [ "$status" -eq 0 ]
  grep -q "$(pubof "$K/lap-client") devmesh:lap" "$NODE_ETC/clients.pub"
  grep -q "$(pubof "$HOME/.ssh/id_devmesh") devmesh:tablet" "$NODE_ETC/clients.pub"
  ! grep -q 'injected' "$NODE_ETC/clients.pub"
  ! grep -q 'devmesh:pc2' "$NODE_ETC/clients.pub"
  [[ $output == *"dropped client key of injected"* ]]
  grep -q 'keys2 ' "$STUB_LOG"
}

@test "node signed: an unparseable bundle or missing allowed_signers keeps the current keys" {
  node_env
  k=$(new_ssh_pub "$K/cur")
  printf '%s devmesh:cur\n' "$k" >"$NODE_ETC/clients.pub"
  printf 'garbage line\n' >"$STUB_SSH_DIR/tunnel@hub.example.test/keys2_$VER"
  run bash "$REPO/client/sbin/devmesh-node" keys-sync
  [ "$status" -ne 0 ]
  [[ $output == *"no $NODE_ETC/allowed_signers"* ]]
  printf 'x namespaces="devmesh" %s\n' "$k" >"$NODE_ETC/allowed_signers"
  run bash "$REPO/client/sbin/devmesh-node" keys-sync
  [ "$status" -ne 0 ]
  [[ $output == *"unparseable"* ]]
  [ "$(cat "$NODE_ETC/clients.pub")" = "$k devmesh:cur" ]
}

@test "node open: behaves as before (bare keys, unverified, no allowed_signers needed)" {
  node_env open
  k=$(new_ssh_pub "$K/any")
  printf '%s devmesh:any\n' "$k" >"$STUB_SSH_DIR/tunnel@hub.example.test/keys_$VER"
  run bash "$REPO/client/sbin/devmesh-node" keys-sync
  [ "$status" -eq 0 ]
  [ "$(cat "$NODE_ETC/clients.pub")" = "$k devmesh:any" ]
  ! grep -q 'keys2' "$STUB_LOG"
}

# --- bootstrap: local allowed_signers --------------------------------------------------------
@test "bootstrap: the owner trusts its own key; others take the delivered approvers; none stays open" {
  export DM_NAME=lap
  new_ssh_pub "$K/me" >/dev/null
  DM_OWNER=1 bs_trust_setup "$BATS_TEST_TMPDIR/al1" "$K/me.pub"
  [ "$DM_TRUST_MODE" = signed ]
  [ "$(cat "$BATS_TEST_TMPDIR/al1")" = "$(tr_allowed_line lap "$(pubof "$K/me")")" ]
  p=$(pubof "$K/me")
  printf 'tablet %s owner\nmallory %s %s\n' "$p" "$p" "$(printf 'A%.0s' {1..120})" >"$BATS_TEST_TMPDIR/sg"
  DM_OWNER=0 DM_SIGNERS_FILE="$BATS_TEST_TMPDIR/sg" bs_trust_setup "$BATS_TEST_TMPDIR/al2" "$K/me.pub"
  [ "$DM_TRUST_MODE" = signed ]
  [ "$(cat "$BATS_TEST_TMPDIR/al2")" = "$(tr_allowed_line tablet "$p")" ]
  : >"$BATS_TEST_TMPDIR/empty"
  DM_OWNER=0 DM_SIGNERS_FILE="$BATS_TEST_TMPDIR/empty" bs_trust_setup "$BATS_TEST_TMPDIR/al3" "$K/me.pub"
  [ "$DM_TRUST_MODE" = open ]
  [ ! -s "$BATS_TEST_TMPDIR/al3" ]
  run env DM_TRUST_MODE=signed DM_NAME=x DM_KIND=machine DM_IP=1 DM_HUB_HOST=h DM_HUB_IP=1 DM_HUB_WG_PUB=k \
    DM_WG_IFACE=d DM_WG_PORT=1 DM_VERSION=1 bash -c "source '$REPO/client/lib/bootstrap_common.sh'; bs_node_conf"
  [[ $output == *"DM_TRUST=signed"* ]]
}

@test "join script of a hub with approvers carries them; the owner invite carries OWNER=1" {
  enroll_owner
  devmesh invite lap >/dev/null
  script="$DEVMESH_WEBROOT/j/$(invite_code)"
  grep -q "^export DM_OWNER='0'" "$script"
  grep -q "^tablet $(pubof "$HOME/.ssh/id_devmesh") owner$" "$script"
  sh -n "$script"
}

# --- dm approve / trust ----------------------------------------------------------------------
@test "dm approve: lists what waits, then signs and uploads after confirmation" {
  enroll_owner
  enroll_dev lap machine
  run dm_approve
  [ "$status" -eq 0 ]
  [[ $output == *lap*"needs: client+host"* ]]
  [[ $output != *SHA256* ]]
  run dm_approve lap --yes
  [ "$status" -eq 0 ]
  [[ $(sig_col lap) == *:* ]]
  run devmesh bundle
  [[ $output == *"client lap "* && $output == *"host lap "* ]]
}

@test "dm approve: asks to type the name and refuses a wrong one" {
  enroll_owner
  enroll_dev lap machine
  run dm_approve lap <<<"nope"
  [ "$status" -ne 0 ]
  [ "$(sig_col lap)" = "-" ]
}

@test "dm approve: a device that is not an approver cannot" {
  enroll_dev lap machine
  : >"$(dm_allowed_signers)"
  run dm_approve lap --yes
  [ "$status" -ne 0 ]
  [[ $output == *"not an approver"* ]]
}

@test "dm trust init: the owner signs every existing device after the 0.7 migration" {
  enroll_dev lap machine
  enroll_dev tablet phone
  cp "$K/tablet-client" "$HOME/.ssh/id_devmesh"
  cp "$K/tablet-client.pub" "$HOME/.ssh/id_devmesh.pub"
  devmesh owner tablet >/dev/null
  run dm_trust_pin --yes
  [ "$status" -eq 0 ]
  grep -qx 'DM_TRUST=signed' "$DM_CONF"
  [ -s "$(dm_allowed_signers)" ]
  DM_TRUST=signed
  run dm_trust_init --yes
  [ "$status" -eq 0 ]
  [[ $(sig_col lap) == *:* ]]
  [ "$(sig_col tablet)" = owner ]
  run devmesh bundle
  [[ $output == *"client lap "* && $output == *"host lap "* ]]
}

@test "dm trust pin: needs the owner's fingerprint tail (never displayed), writes allowed_signers and signed mode" {
  enroll_owner
  owner_tail=$(dm_fp_tail "$(pubof "$HOME/.ssh/id_devmesh")")
  rm -f "$(dm_allowed_signers)"
  sed -i.bak '/^DM_TRUST=/d' "$DM_CONF"
  unset DM_TRUST
  run dm_trust_pin <<<"no"
  [ "$status" -ne 0 ]
  [ ! -e "$(dm_allowed_signers)" ]
  run dm_trust_pin <<<"$owner_tail"
  [ "$status" -eq 0 ]
  [[ $output != *"$owner_tail"*"$owner_tail"* && $output != *SHA256* ]]
  [ "$(cat "$(dm_allowed_signers)")" = "$(tr_allowed_line tablet "$(pubof "$HOME/.ssh/id_devmesh")")" ]
  grep -qx 'DM_TRUST=signed' "$DM_CONF"
}

@test "dm trust pin/approve/init: --yes only works with DM_TEST=1" {
  enroll_owner
  enroll_dev lap machine
  DM_TEST=0 run dm_approve lap --yes
  [ "$status" -ne 0 ]
  [[ $output == *"only works in tests"* ]]
  DM_TEST=0 run dm_trust_init --yes
  [ "$status" -ne 0 ]
  [ "$(sig_col lap)" = "-" ]
}

@test "dm trust status prints this device's own fingerprints (what the owner types)" {
  enroll_owner
  run dm_trust_status
  [[ $output == *"client key"*"$(tr_fingerprint "$(pubof "$HOME/.ssh/id_devmesh")")"* ]]
}

# --- OSS-22: host keys in dm refresh -----------------------------------------------------------
refresh_replies() {
  hub_line="hub.example.test,10.73.0.1 $(devmesh known-hosts | head -n1 | awk '{print $2 " " $3}')"
  ssh_reply hub-admin ssh-config "$(min_cfg)"
  ssh_reply hub-admin known-hosts "$hub_line"$'\n'"lap $(pubof "$K/swap")"$'\n'
  t=$'\t'
  ssh_reply hub-admin hosts "lap${t}machine${t}10.73.0.2${t}2202${t}22${t}dev${t}-${t}-"$'\n'"pc2${t}machine${t}10.73.0.3${t}2203${t}24${t}dev${t}-${t}-"$'\n'
  # the hub's reply for "bundle" is the real one
  unset STUB_ADMIN_CMD
  devmesh bundle >"$STUB_SSH_DIR/hub-admin/bundle"
}

@test "refresh (signed): only approver-signed host keys reach known_hosts; the hub's own entry stays pinned" {
  enroll_owner
  enroll_dev lap machine
  enroll_dev pc2 machine
  new_ssh_pub "$K/swap" >/dev/null
  c=$(owner_sign client lap "$(pubof "$K/lap-client")")
  h=$(owner_sign host lap "$(pubof "$K/lap-host")")
  admin "approve lap" <<<"client $c"$'\n'"host $h" >/dev/null
  printf 'hub.example.test,10.73.0.1 ssh-ed25519 PINNED\n' >"$HOME/.ssh/devmesh_known_hosts"
  refresh_replies
  run dm_refresh
  [ "$status" -eq 0 ]
  known=$(cat "$HOME/.ssh/devmesh_known_hosts")
  [[ $known == *"hub.example.test ssh-ed25519 PINNED"* ]]
  [[ $known == *"lap $(pubof "$K/lap-host")"* ]]
  [[ $known != *"$(pubof "$K/swap")"* ]]
  [[ $known != *"pc2 "* ]]
  [[ $output == *"host key of pc2 is not approved"* ]]
}

@test "refresh (signed): a host key the hub replaced is dropped, a forged signature does not help" {
  enroll_owner
  enroll_dev lap machine
  new_ssh_pub "$K/swap" >/dev/null
  c=$(owner_sign client lap "$(pubof "$K/lap-client")")
  h=$(owner_sign host lap "$(pubof "$K/lap-host")")
  admin "approve lap" <<<"client $c"$'\n'"host $h" >/dev/null
  refresh_replies
  # root on the hub swaps lap's host key in the bundle but keeps the old signature.
  sed -i.bak "s|^host lap $(pubof "$K/lap-host")|host lap $(pubof "$K/swap")|" "$STUB_SSH_DIR/hub-admin/bundle"
  run dm_refresh
  [ "$status" -eq 0 ]
  ! grep -q "$(pubof "$K/swap")" "$HOME/.ssh/devmesh_known_hosts"
  [[ $output == *"dropped host key of lap"* ]]
}

@test "refresh (signed): a bundle that does not parse leaves known_hosts as it was" {
  enroll_owner
  new_ssh_pub "$K/swap" >/dev/null
  printf 'hub.example.test,10.73.0.1 ssh-ed25519 PINNED\n' >"$HOME/.ssh/devmesh_known_hosts"
  refresh_replies
  printf 'junk\n' >"$STUB_SSH_DIR/hub-admin/bundle"
  run dm_refresh
  [ "$status" -ne 0 ]
  [ "$(cat "$HOME/.ssh/devmesh_known_hosts")" = "hub.example.test,10.73.0.1 ssh-ed25519 PINNED" ]
}

# --- OSS-21: signed client bundle --------------------------------------------------------------
make_dist() { # VERSION -> $D/dist.tgz + sig
  D=$BATS_TEST_TMPDIR/dist
  mkdir -p "$D/src/client/lib"
  printf 'echo hi\n' >"$D/src/client/lib/x.sh"
  printf '%s\n' "$1" >"$D/src/VERSION"
  tar -C "$D/src" -czf "$D/dist.tgz" client VERSION
  tr_sign "$HOME/.ssh/id_devmesh" "$(tr_msg bundle "$1" "$(tr_sha256 "$D/dist.tgz")")" >"$D/dist.sig"
  mkdir -p "$STUB_SSH_DIR/hub-admin"
  unset STUB_ADMIN_CMD
  cp "$D/dist.tgz" "$STUB_SSH_DIR/hub-admin/dist"
  cp "$D/dist.sig" "$STUB_SSH_DIR/hub-admin/dist_sig"
}

fetch() {
  local w=$BATS_TEST_TMPDIR/w
  rm -rf "$w"
  mkdir -p "$w"
  (dm_trust_fetch_dist "$w")
}

@test "update: a correctly signed bundle is accepted" {
  enroll_owner
  dm_version() { printf '0.7.0\n'; }
  make_dist 0.8.0
  run fetch
  [ "$status" -eq 0 ]
  [ -f "$BATS_TEST_TMPDIR/w/client/lib/x.sh" ]
}

@test "update: a bundle with one byte changed is rejected" {
  enroll_owner
  dm_version() { printf '0.7.0\n'; }
  make_dist 0.8.0
  printf 'X' >>"$STUB_SSH_DIR/hub-admin/dist"
  run fetch
  [ "$status" -ne 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/w/client" ]
}

@test "update: a bundle signed by somebody else, or without a signature, is rejected in signed mode" {
  enroll_owner
  dm_version() { printf '0.7.0\n'; }
  make_dist 0.8.0
  ssh-keygen -q -t ed25519 -N '' -f "$K/evil"
  tr_sign "$K/evil" "$(tr_msg bundle 0.8.0 "$(tr_sha256 "$D/dist.tgz")")" >"$STUB_SSH_DIR/hub-admin/dist_sig"
  run fetch
  [ "$status" -ne 0 ]
  rm "$STUB_SSH_DIR/hub-admin/dist_sig"
  run fetch
  [ "$status" -ne 0 ]
}

@test "update: signed mode refuses a signed but older bundle (downgrade)" {
  enroll_owner
  dm_version() { printf '0.9.0\n'; }
  make_dist 0.8.0
  run fetch
  [ "$status" -ne 0 ]
  [[ $output == *"older than"* ]]
}

@test "update: in open mode (no approvers on this device) an unsigned bundle still installs (as before)" {
  enroll_owner
  rm -f "$(dm_allowed_signers)"
  DM_TRUST=open
  make_dist 0.8.0
  rm "$STUB_SSH_DIR/hub-admin/dist_sig"
  run fetch
  [ "$status" -eq 0 ]
  [ -f "$BATS_TEST_TMPDIR/w/client/lib/x.sh" ]
}

@test "sign-dist: an approver machine produces a bundle that verifies" {
  enroll_owner
  out=$BATS_TEST_TMPDIR/dist-out
  run env DM_ALLOWED_SIGNERS="$(dm_allowed_signers)" bash "$REPO/scripts/sign-dist.sh" "$out"
  [ "$status" -eq 0 ]
  ver=$(tr -d '[:space:]' <"$REPO/VERSION")
  run tr_verify "$(dm_allowed_signers)" "$(cat "$out/dist.sig")" "$(tr_msg bundle "$ver" "$(tr_sha256 "$out/dist.tgz")")"
  [ "$status" -eq 0 ]
}

@test "sign-dist: a machine that is not an approver leaves the directory empty" {
  out=$BATS_TEST_TMPDIR/dist-out2
  run env HOME="$BATS_TEST_TMPDIR/nobody" bash "$REPO/scripts/sign-dist.sh" "$out"
  [ "$status" -eq 0 ]
  [ -z "$(ls "$out")" ]
}

# --- hub-supplied ssh_config and device list are validated (all modes) -------------------------
cfg_rejected() { # TEXT
  ssh_reply hub-admin ssh-config "$1"
  before=$(cat "$HOME/.ssh/config.d/devmesh")
  run dm_refresh
  [ "$status" -ne 0 ]
  [ "$(cat "$HOME/.ssh/config.d/devmesh")" = "$before" ]
}

cfg_replies() {
  hosts="lap	machine	10.73.0.2	2202	22	dev	-	-"$'\n'
  ssh_reply hub-admin known-hosts $'hub.example.test ssh-ed25519 AAAA\n'
  ssh_reply hub-admin hosts "$hosts"
  mkdir -p "$HOME/.ssh/config.d"
  printf 'Host hub-admin\n  HostName old\n' >"$HOME/.ssh/config.d/devmesh"
}

@test "refresh: the exact ssh_config the hub renders is accepted (open mode too)" {
  enroll_machine lap
  enroll_phone ph
  cfg_replies
  unset STUB_ADMIN_CMD
  ssh_reply hub-admin hosts "$(devmesh hosts)"$'\n'
  ssh_reply hub-admin ssh-config "$(devmesh ssh-config)"$'\n'
  ssh_reply hub-admin known-hosts "$(devmesh known-hosts)"$'\n'
  run dm_refresh
  [ "$status" -eq 0 ]
  grep -q '^Host lap-b$' "$HOME/.ssh/config.d/devmesh"
}

@test "refresh: ssh_config with code execution, trust redirection or foreign aliases is rejected" {
  cfg_replies
  base="$(min_cfg hub.example.test)"$'\n'
  cfg_rejected "${base}  ProxyCommand sh -c id"$'\n'
  cfg_rejected "${base}  LocalCommand id"$'\n'
  cfg_rejected "${base}Match exec id"$'\n'
  cfg_rejected "${base}Include /tmp/x"$'\n'
  cfg_rejected "${base}Host *"$'\n'"  User x"$'\n'
  cfg_rejected "${base}"$'\t'"StrictHostKeyChecking no"$'\n'
  cfg_rejected "${base}  StrictHostKeyChecking no"$'\n'
  cfg_rejected "${base}  ProxyJump evil.example"$'\n'
  cfg_rejected "${base}  User a b"$'\n'
  cfg_rejected "${base}Host evil"$'\n'"  HostName 1.2.3.4"$'\n'
  # the lap entry reuses the hub's key alias: MITM with the pinned hub key
  cfg_rejected "${base}Host lap"$'\n'"  HostName 10.73.0.2"$'\n'"  HostKeyAlias hub.example.test"$'\n'
}

@test "refresh: a device list with a hostile field is rejected before it is cached" {
  cfg_replies
  ssh_reply hub-admin ssh-config "$(min_cfg)"
  before=$(cat "$DM_CACHE/hosts.tsv")
  for bad in "l;id	machine	10.73.0.2	2202	22	dev	-	-" "lap	machine	10.73.0.2	22x	22	dev	-	-" \
    "lap	machine	10.73.0.2	2202	22	d\$(id)	-	-" "lap	machine	1.2.3.4;x	2202	22	dev	-	-" \
    "lap	robot	10.73.0.2	2202	22	dev	-	-" "lap	machine	10.73.0.2	2202	22	dev	-	zz"; do
    ssh_reply hub-admin hosts "$bad"$'\n'
    run dm_refresh
    [ "$status" -ne 0 ]
    [ "$(cat "$DM_CACHE/hosts.tsv")" = "$before" ]
  done
}

# --- bundle robustness ------------------------------------------------------------------------
@test "bundle: the hub never emits legacy/owner/pending markers as signature lines" {
  enroll_dev lap machine
  enroll_dev tablet phone
  devmesh owner tablet >/dev/null
  ! grep -Eq '^(client|host) .* (legacy|owner|-)$' "$DEVMESH_ETC/clients.bundle"
}

@test "bundle: one malformed line is skipped, the rest still verifies" {
  mk_approvers
  good=$(pubof "$K/newc")
  {
    printf 'client lap %s legacy\n' "$good"
    printf 'client ok %s %s\n' "$good" "$(tr_sign "$K/a/k" "$(tr_msg client ok "$good")")"
  } >"$BATS_TEST_TMPDIR/bundle"
  out=$(tr_process_bundle "$AL" "$BATS_TEST_TMPDIR/bundle" 0 2>/dev/null)
  [ "$out" = "client ok $good" ]
}

# --- revocation (signed, with a signed epoch over the revocation set) -------------------------
# revoke_payload NAME PUB [KEYFILE] — stdin of "revoke": the revocation and the next epoch.
revoke_payload() {
  local name=$1 pub=$2 key=${3:-$HOME/.ssh/id_devmesh} serial list
  serial=$(($(awk -F'\t' 'NR == 1 {print $1}' "$DEVMESH_ETC/epoch.tsv" 2>/dev/null || echo 0) + 1))
  list=$BATS_TEST_TMPDIR/revlist
  { awk -F'\t' -v k="$pub" '$2 != k {print $1 " " $2}' "$DEVMESH_ETC/revoked.tsv" 2>/dev/null || true; printf '%s %s\n' "$name" "$pub"; } >"$list"
  printf 'revoke %s\nepoch %s\n' "$(sign "$key" revoke "$name" "$pub")" \
    "$(tr_sign "$key" "$(tr_msg epoch "$serial" "$(tr_rev_hash "$list")")")"
}

@test "revoke: the hub stores a signed revocation and epoch, serves them, and refuses forged ones" {
  enroll_owner
  enroll_dev lap machine
  pub=$(pubof "$K/lap-client")
  run admin "revoke lap" <<<"$(revoke_payload lap "$pub" "$K/lap-client")"
  [ "$status" -ne 0 ]
  # a valid revocation with an epoch for the wrong serial
  bad=$(tr_sign "$HOME/.ssh/id_devmesh" "$(tr_msg epoch 7 "$TR_EMPTY_HASH")")
  run admin "revoke lap" <<<"revoke $(owner_sign revoke lap "$pub")"$'\n'"epoch $bad"
  [ "$status" -ne 0 ]
  [ ! -s "$DEVMESH_ETC/revoked.tsv" ]
  run admin "revoke lap" <<<"$(revoke_payload lap "$pub")"
  [ "$status" -eq 0 ]
  grep -q "^revoke lap $pub " "$DEVMESH_ETC/clients.bundle"
  grep -q "^epoch 1 [0-9a-f]\{64\} tablet " "$DEVMESH_ETC/clients.bundle"
  run admin "revoke tablet" <<<"$(revoke_payload tablet "$(pubof "$HOME/.ssh/id_devmesh")")"
  [ "$status" -ne 0 ]
}

node_with_two() {
  enroll_owner
  enroll_dev lap machine
  enroll_dev pc2 machine
  for d in lap pc2; do
    admin "approve $d" <<<"client $(owner_sign client $d "$(pubof "$K/$d-client")")" >/dev/null
  done
  node_env
  cp "$(dm_allowed_signers)" "$NODE_ETC/allowed_signers"
  R=$STUB_SSH_DIR/tunnel@hub.example.test/keys2_$VER
  cp "$DEVMESH_ETC/clients.bundle" "$BATS_TEST_TMPDIR/old-bundle"
  cp "$DEVMESH_ETC/clients.bundle" "$R"
  run bash "$REPO/client/sbin/devmesh-node" keys-sync
  grep -q 'devmesh:lap' "$NODE_ETC/clients.pub"
}

@test "revoke: a revoked key leaves the node, the epoch is stored, an old valid signature is never accepted again" {
  node_with_two
  admin "revoke lap" <<<"$(revoke_payload lap "$(pubof "$K/lap-client")")" >/dev/null
  devmesh remove lap --confirm lap >/dev/null
  cp "$DEVMESH_ETC/clients.bundle" "$R"
  run bash "$REPO/client/sbin/devmesh-node" keys-sync
  [ "$status" -eq 0 ]
  ! grep -q 'devmesh:lap' "$NODE_ETC/clients.pub"
  grep -q 'devmesh:pc2' "$NODE_ETC/clients.pub"
  grep -q "$(pubof "$K/lap-client")" "$NODE_ETC/allowed_signers.revoked"
  [[ $(cut -d' ' -f1 "$NODE_ETC/allowed_signers.epoch") == 1 ]]
  # The hub replays the old bundle (lap's valid approval): older epoch, rejected.
  cp "$BATS_TEST_TMPDIR/old-bundle" "$R"
  run bash "$REPO/client/sbin/devmesh-node" keys-sync
  [ "$status" -ne 0 ]
  [[ $output == *"bundle rejected"* || $output == *"revocation epoch"* ]]
  ! grep -q 'devmesh:lap' "$NODE_ETC/clients.pub"
  grep -q 'devmesh:pc2' "$NODE_ETC/clients.pub"
}

@test "revoke: a bundle that withholds the revoke line of a newer epoch is rejected" {
  node_with_two
  admin "revoke lap" <<<"$(revoke_payload lap "$(pubof "$K/lap-client")")" >/dev/null
  grep -v '^revoke ' "$DEVMESH_ETC/clients.bundle" >"$R"
  grep -q '^epoch 1' "$R"
  run bash "$REPO/client/sbin/devmesh-node" keys-sync
  [ "$status" -ne 0 ]
  grep -q 'devmesh:lap' "$NODE_ETC/clients.pub" # unchanged: the withholding bundle was refused
  [ ! -e "$NODE_ETC/allowed_signers.epoch" ]
}

@test "revoke: a rollback to a lower epoch after a higher one was seen is rejected" {
  node_with_two
  admin "revoke lap" <<<"$(revoke_payload lap "$(pubof "$K/lap-client")")" >/dev/null
  cp "$DEVMESH_ETC/clients.bundle" "$BATS_TEST_TMPDIR/epoch1"
  admin "revoke pc2" <<<"$(revoke_payload pc2 "$(pubof "$K/pc2-client")")" >/dev/null
  cp "$DEVMESH_ETC/clients.bundle" "$R"
  run bash "$REPO/client/sbin/devmesh-node" keys-sync
  [ "$status" -eq 0 ]
  [[ $(cut -d' ' -f1 "$NODE_ETC/allowed_signers.epoch") == 2 ]]
  cp "$BATS_TEST_TMPDIR/epoch1" "$R"
  run bash "$REPO/client/sbin/devmesh-node" keys-sync
  [ "$status" -ne 0 ]
  [[ $(cut -d' ' -f1 "$NODE_ETC/allowed_signers.epoch") == 2 ]]
}

epoch_bundle_line() { # KEYFILE SIGNER SERIAL LISTFILE
  printf 'epoch %s %s %s %s\n' "$3" "$(tr_rev_hash "$4")" "$2" "$(tr_sign "$1" "$(tr_msg epoch "$3" "$(tr_rev_hash "$4")")")"
}

@test "revoke: a revoked approver is removed and its later signatures are rejected" {
  mk_approvers
  b=$(pubof "$K/b/k")
  c=$(pubof "$K/newc")
  tr_allowed_line bob "$b" >>"$AL"
  printf 'bob %s\n' "$b" >"$BATS_TEST_TMPDIR/list"
  {
    printf 'revoke bob %s %s\n' "$b" "$(tr_sign "$K/a/k" "$(tr_msg revoke bob "$b")")"
    epoch_bundle_line "$K/a/k" alice 1 "$BATS_TEST_TMPDIR/list"
    printf 'client x %s %s\n' "$c" "$(tr_sign "$K/b/k" "$(tr_msg client x "$c")")"
  } >"$BATS_TEST_TMPDIR/bundle"
  out=$(tr_process_bundle "$AL" "$BATS_TEST_TMPDIR/bundle" 1 2>/dev/null)
  [ -z "$out" ]
  ! grep -q '^bob ' "$AL"
  [ "$(cut -d' ' -f1 "$AL.epoch")" = 1 ]
}

@test "revoke: a revocation signed by nobody trusted is ignored (and without it no epoch is needed)" {
  mk_approvers
  printf 'revoke alice %s %s\n' "$(pubof "$K/a/k")" "$(tr_sign "$K/b/k" "$(tr_msg revoke alice "$(pubof "$K/a/k")")")" >"$BATS_TEST_TMPDIR/bundle"
  run tr_process_bundle "$AL" "$BATS_TEST_TMPDIR/bundle" 1
  [ "$status" -eq 0 ]
  grep -q '^alice ' "$AL"
}

@test "revoking every approver is refused: bundle rejected, allowed_signers untouched" {
  mk_approvers
  a=$(pubof "$K/a/k")
  printf 'alice %s\n' "$a" >"$BATS_TEST_TMPDIR/list"
  {
    printf 'revoke alice %s %s\n' "$a" "$(tr_sign "$K/a/k" "$(tr_msg revoke alice "$a")")"
    epoch_bundle_line "$K/a/k" alice 1 "$BATS_TEST_TMPDIR/list"
  } >"$BATS_TEST_TMPDIR/bundle"
  before=$(cat "$AL")
  run tr_process_bundle "$AL" "$BATS_TEST_TMPDIR/bundle" 1
  [ "$status" -eq 4 ]
  [ "$(cat "$AL")" = "$before" ]
  [ ! -e "$AL.revoked" ]
}

@test "dm rm on an approver: signs the revocation and epoch with the LOCAL key record" {
  enroll_owner
  enroll_dev lap machine
  dm_approve lap --yes >/dev/null 2>&1
  run dm_trust_revoke lap
  [ "$status" -eq 0 ]
  grep -q "^revoke lap " "$DEVMESH_ETC/clients.bundle"
  grep -q "^epoch 1 " "$DEVMESH_ETC/clients.bundle"
}

@test "dm rm: refuses to revoke this device's key, the last approver, or a key the hub swapped" {
  enroll_owner
  enroll_dev lap machine
  dm_approve lap --yes >/dev/null 2>&1
  run dm_trust_revoke tablet
  [ "$status" -ne 0 ]
  [[ $output == *"own key"* || $output == *"last approver"* ]]
  # the hub's bundle shows another key under lap's name
  new_ssh_pub "$K/swap" >/dev/null
  bundle=$(devmesh bundle | sed "s|^client lap [^ ]* [^ ]*|client lap $(pubof "$K/swap")|")
  unset STUB_ADMIN_CMD
  ssh_reply hub-admin bundle "$bundle"$'\n'
  run dm_trust_revoke lap
  [ "$status" -ne 0 ]
  [[ $output == *differs* ]]
  ! grep -q '^revoke ' "$DEVMESH_ETC/clients.bundle"
}

@test "dm rm: without a local record the user must type the device's fingerprint; no hub entry aborts" {
  enroll_owner
  enroll_dev lap machine
  admin "approve lap" <<<"client $(owner_sign client lap "$(pubof "$K/lap-client")")" >/dev/null
  run dm_trust_revoke lap <<<"wrongwrongwrong1"
  [ "$status" -ne 0 ]
  ! grep -q '^revoke ' "$DEVMESH_ETC/clients.bundle"
  run dm_trust_revoke lap <<<"$(dm_fp_tail "$(pubof "$K/lap-client")")"
  [ "$status" -eq 0 ]
  run dm_trust_revoke ghost
  [ "$status" -ne 0 ]
  [[ $output == *"no approved key"* ]]
}

# --- pin / fail closed / fingerprints ----------------------------------------------------------
@test "dm trust pin: a second run is refused; --reset needs the exact owner fingerprint" {
  enroll_owner
  run dm_trust_pin --yes
  [ "$status" -ne 0 ]
  [[ $output == *"already trusts"* ]]
  before=$(cat "$(dm_allowed_signers)")
  run dm_trust_pin --reset <<<"wrong"
  [ "$status" -ne 0 ]
  [ "$(cat "$(dm_allowed_signers)")" = "$before" ]
  run dm_trust_pin --reset <<<"$(dm_fp_tail "$(pubof "$HOME/.ssh/id_devmesh")")"
  [ "$status" -eq 0 ]
}

@test "signed mode without allowed_signers fails closed: refresh, update and node sync" {
  enroll_owner
  : >"$(dm_allowed_signers)"
  DM_TRUST=signed
  cfg_replies
  ssh_reply hub-admin ssh-config "$(min_cfg)"
  run dm_refresh
  [ "$status" -ne 0 ]
  [[ $output == *"missing or empty"* ]]
  dm_version() { printf '0.7.0\n'; }
  make_dist 0.8.0
  run fetch
  [ "$status" -ne 0 ]
  [[ $output == *"missing or empty"* ]]
  node_env
  printf '%s devmesh:cur\n' "$(new_ssh_pub "$K/cur")" >"$NODE_ETC/clients.pub"
  printf 'x\n' >"$STUB_SSH_DIR/tunnel@hub.example.test/keys2_$VER"
  : >"$NODE_ETC/allowed_signers"
  run bash "$REPO/client/sbin/devmesh-node" keys-sync
  [ "$status" -ne 0 ]
  grep -q 'devmesh:cur' "$NODE_ETC/clients.pub"
  # an existing allowed_signers means signed even if the config says open
  node_env open
  printf 'a namespaces="devmesh" %s\n' "$(pubof "$K/cur")" >"$NODE_ETC/allowed_signers"
  run bash "$REPO/client/sbin/devmesh-node" keys-sync
  grep -q 'keys2 ' "$STUB_LOG"
}

@test "dm approve: asks for the last 16 characters of the host (machine) or client (phone) fingerprint, never shows them" {
  enroll_owner
  enroll_dev lap machine
  enroll_dev tab2 phone
  hfp=$(tr_fingerprint "$(pubof "$K/lap-host")")
  cfp_lap=$(tr_fingerprint "$(pubof "$K/lap-client")")
  # the HOST tail alone is not enough: the client key is signed too
  run dm_approve lap <<<"${hfp: -16}"$'\n'"${hfp: -16}"
  [ "$status" -ne 0 ]
  [ "$(sig_col lap)" = "-" ]
  run dm_approve lap <<<"${cfp_lap: -16}"$'\n'"${hfp: -16}"
  [ "$status" -eq 0 ]
  [[ $output != *"${hfp: -16}"* ]]
  [[ $(sig_col lap) == *:* ]]
  run dm_approve tab2 <<<"tab2"
  [ "$status" -ne 0 ]
  [ "$(sig_col tab2)" = "-" ]
  cfp=$(tr_fingerprint "$(pubof "$K/tab2-client")")
  run dm_approve tab2 <<<"${cfp: -16}"
  [ "$status" -eq 0 ]
}

@test "dm trust init: per-device fingerprint tails (or --i-checked-all) are required" {
  enroll_dev lap machine
  enroll_dev tablet phone
  cp "$K/tablet-client" "$HOME/.ssh/id_devmesh"
  cp "$K/tablet-client.pub" "$HOME/.ssh/id_devmesh.pub"
  devmesh owner tablet >/dev/null
  dm_trust_pin --yes >/dev/null 2>&1
  run dm_trust_init <<<"approve"
  [ "$status" -ne 0 ]
  [ "$(sig_col lap)" = legacy ]
  run dm_trust_init <<<"$(dm_fp_tail "$(pubof "$K/lap-client")")"$'\n'"$(dm_fp_tail "$(pubof "$K/lap-host")")"
  [ "$status" -eq 0 ]
  [[ $(sig_col lap) == *:* ]]
}

@test "dm trust init --i-checked-all signs without typing (and warns)" {
  enroll_dev lap machine
  enroll_dev tablet phone
  cp "$K/tablet-client" "$HOME/.ssh/id_devmesh"
  cp "$K/tablet-client.pub" "$HOME/.ssh/id_devmesh.pub"
  devmesh owner tablet >/dev/null
  dm_trust_pin --yes >/dev/null 2>&1
  run dm_trust_init --i-checked-all
  [ "$status" -eq 0 ]
  [[ $output == *WARNING* ]]
  [[ $(sig_col lap) == *:* ]]
}

@test "join: the current epoch is delivered, verified and stored; a forged one is ignored" {
  enroll_owner
  enroll_dev lap machine
  admin "revoke lap" <<<"$(revoke_payload lap "$(pubof "$K/lap-client")")" >/dev/null
  devmesh invite pc3 >/dev/null
  script="$DEVMESH_WEBROOT/j/$(invite_code)"
  line=$(grep '^epoch 1 ' "$script")
  [[ -n $line ]]
  al=$BATS_TEST_TMPDIR/joined
  cp "$(dm_allowed_signers)" "$al"
  printf '%s\n' "$line" >"$BATS_TEST_TMPDIR/ep"
  bs_store_epoch "$al" "$BATS_TEST_TMPDIR/ep"
  [ "$(cut -d' ' -f1 "$al.epoch")" = 1 ]
  rm "$al.epoch"
  printf 'epoch 5 %s tablet %s\n' "$TR_EMPTY_HASH" "$(printf 'A%.0s' {1..120})" >"$BATS_TEST_TMPDIR/ep"
  bs_store_epoch "$al" "$BATS_TEST_TMPDIR/ep"
  [ ! -e "$al.epoch" ]
}

@test "bootstrap prints the fingerprints to check when an approver asks" {
  new_ssh_pub "$K/cl" >/dev/null
  new_ssh_pub "$K/ho" >/dev/null
  export DM_NAME=lap
  DM_TRUST_MODE=signed DM_OWNER=0 run bs_approve_hint "$K/cl.pub" "$K/ho.pub"
  [[ $output == *"dm approve lap"*"client SHA256:"*"host SHA256:"* ]]
  DM_TRUST_MODE=open run bs_approve_hint "$K/cl.pub"
  [ -z "$output" ]
}

@test "refresh: every alias must get the trust options; ports and duplicate blocks are checked" {
  cfg_replies
  ok="$(min_cfg hub.example.test)"
  # per-host block without the shared trailer: ssh would fall back to ~/.ssh/known_hosts and "ask"
  cfg_rejected "${ok}"$'\nHost lap\n  HostName 10.73.0.2\n  HostKeyAlias lap\n'
  cfg_rejected $'Host hub-admin\n  HostName h\n  IdentityFile ~/.ssh/id_devmesh\n  IdentitiesOnly yes\n  UserKnownHostsFile ~/.ssh/devmesh_known_hosts\n'
  cfg_rejected "${ok}"$'\nHost hub-admin\n  HostName h2\n'
  cfg_rejected "${ok}"$'\n  Port 70000\n'
  cfg_rejected "${ok}"$'\n  Port 0\n'
}

@test "dm approve --signer also asks for the client tail of a phone that is already approved" {
  enroll_owner
  enroll_dev tab2 phone
  run dm_approve tab2 --signer <<<"$(dm_fp_tail "$(pubof "$K/tab2-client")")"
  [ "$status" -eq 0 ]
  grep -q '^signer tab2 ' "$DEVMESH_ETC/clients.bundle"
}

# --- roots of trust ------------------------------------------------------------------------------
@test "import: the root is the single confirmed owner key; a second owner row is never trusted" {
  mk_approvers
  a=$(pubof "$K/a/k")
  b=$(pubof "$K/b/k")
  c=$(pubof "$K/newc")
  printf 'alice %s owner\nmallory %s owner\ncarol %s %s\n' "$a" "$b" "$c" "$(tr_sign "$K/a/k" "$(tr_msg signer carol "$c")")" >"$BATS_TEST_TMPDIR/sg"
  out=$BATS_TEST_TMPDIR/imp
  rm -f "$out"
  run tr_import_signers "$BATS_TEST_TMPDIR/sg" "$out" "$a"
  [ "$status" -eq 0 ]
  grep -q '^alice ' "$out"
  grep -q '^carol ' "$out"
  ! grep -q '^mallory ' "$out"
  # without a confirmed root (enrollment), two owners are refused outright
  rm -f "$out"
  run tr_import_signers "$BATS_TEST_TMPDIR/sg" "$out"
  [ "$status" -ne 0 ]
  [ ! -s "$out" ]
}

@test "dm trust pin refuses a hub that lists two owners, and keeps revocations and the epoch" {
  enroll_owner
  enroll_dev lap machine
  admin "approve lap" <<<"client $(owner_sign client lap "$(pubof "$K/lap-client")")" >/dev/null
  admin "revoke lap" <<<"$(revoke_payload lap "$(pubof "$K/lap-client")")" >/dev/null
  rm -f "$(dm_allowed_signers)"*
  run dm_trust_pin --yes
  [ "$status" -eq 0 ]
  [ -s "$(dm_allowed_signers).revoked" ]
  [ "$(cut -d' ' -f1 "$(dm_allowed_signers).epoch")" = 1 ]
  rm -f "$(dm_allowed_signers)"*
  printf 'tablet %s owner\nevil %s owner\n' "$(pubof "$HOME/.ssh/id_devmesh")" "$(pubof "$K/lap-client")" >"$STUB_SSH_DIR/x"
  unset STUB_ADMIN_CMD
  ssh_reply hub-admin signers "tablet	$(pubof "$HOME/.ssh/id_devmesh")	owner"$'\n'"evil	$(pubof "$K/lap-client")	owner"$'\n'
  run dm_trust_pin --yes
  [ "$status" -ne 0 ]
  [[ $output == *"more than one owner"* ]]
  [ ! -e "$(dm_allowed_signers)" ]
}

@test "bootstrap: two delivered owner rows leave the device in open mode" {
  mk_approvers
  printf 'alice %s owner\nmallory %s owner\n' "$(pubof "$K/a/k")" "$(pubof "$K/b/k")" >"$BATS_TEST_TMPDIR/sg"
  export DM_NAME=lap
  DM_OWNER=0 DM_SIGNERS_FILE="$BATS_TEST_TMPDIR/sg" bs_trust_setup "$BATS_TEST_TMPDIR/al-new" "$K/a/k.pub"
  [ "$DM_TRUST_MODE" = open ]
  [ ! -s "$BATS_TEST_TMPDIR/al-new" ]
}

@test "offline device converges: a new approver and its revocation in the same bundle" {
  mk_approvers
  b=$(pubof "$K/b/k")
  x=$(pubof "$K/newc")
  printf 'x %s\n' "$x" >"$BATS_TEST_TMPDIR/list"
  {
    printf 'signer bob %s %s\n' "$b" "$(tr_sign "$K/a/k" "$(tr_msg signer bob "$b")")"
    printf 'revoke x %s %s\n' "$x" "$(tr_sign "$K/b/k" "$(tr_msg revoke x "$x")")"
    epoch_bundle_line "$K/b/k" bob 1 "$BATS_TEST_TMPDIR/list"
    printf 'client x %s %s\n' "$x" "$(tr_sign "$K/a/k" "$(tr_msg client x "$x")")"
  } >"$BATS_TEST_TMPDIR/bundle"
  out=$(tr_process_bundle "$AL" "$BATS_TEST_TMPDIR/bundle" 1 2>/dev/null)
  [[ $out == *"signer bob"* && $out != *"client x"* ]]
  [ "$(cut -d' ' -f1 "$AL.epoch")" = 1 ]
  grep -q '^bob ' "$AL"
}

@test "epoch: a serial more than 1000 ahead of the stored one is ignored" {
  mk_approvers
  : >"$BATS_TEST_TMPDIR/list"
  epoch_bundle_line "$K/a/k" alice 5000 "$BATS_TEST_TMPDIR/list" >"$BATS_TEST_TMPDIR/bundle"
  printf 'signer alice %s owner\n' "$(pubof "$K/a/k")" >>"$BATS_TEST_TMPDIR/bundle"
  tr_process_bundle "$AL" "$BATS_TEST_TMPDIR/bundle" 1 >/dev/null 2>&1
  [ ! -e "$AL.epoch" ] || [ "$(cut -d' ' -f1 "$AL.epoch")" = 0 ]
}

@test "revoke: the hub refuses to revoke the same key twice" {
  enroll_owner
  enroll_dev lap machine
  pub=$(pubof "$K/lap-client")
  admin "revoke lap" <<<"$(revoke_payload lap "$pub")" >/dev/null
  run admin "revoke lap" <<<"$(revoke_payload lap "$pub")"
  [ "$status" -ne 0 ]
  [[ $output == *"already revoked"* ]]
}

@test "ssh-config: control sockets are per alias (ControlPath uses %n)" {
  enroll_machine lap
  run devmesh ssh-config
  [[ $output == *"ControlPath ~/.ssh/dm-%n"* ]]
  cfg_replies
  cfg_rejected "$(min_cfg hub.example.test)"$'\n  ControlPath ~/.ssh/devmesh-%C\n'
  cfg_rejected "$(min_cfg hub.example.test)"$'\n  ControlPath ~/.ssh/dm-%C\n'
}

@test "refresh: HostName with a leading dash, tabs, ProxyJump outside machine blocks, several known-hosts files" {
  cfg_replies
  ok="$(min_cfg hub.example.test)"
  cfg_rejected "${ok}"$'\n  HostName -oProxyCommand=x\n'
  cfg_rejected "${ok}"$'\n  User\tdev\n'
  cfg_rejected "${ok}"$'\n  ProxyJump hub-jump\n'
  cfg_rejected "${ok}"$'\nHost hub-admin hub-jump\n  ProxyJump hub-jump\n'
  cfg_rejected "$(min_cfg hub.example.test | sed 's|^  UserKnownHostsFile .*|  UserKnownHostsFile ~/.ssh/devmesh_known_hosts /tmp/x|')"
}

@test "refresh: an alias without HostKeyAlias is rejected (no lookup by the hub-chosen HostName)" {
  cfg_replies
  # lap aimed at the hub's address with no HostKeyAlias: ssh would accept the hub's own key.
  cfg_rejected "$(min_cfg hub.example.test | sed '/HostKeyAlias/d')"
  cfg_rejected "Host lap
  HostName 10.73.0.1
  IdentityFile ~/.ssh/id_devmesh
  IdentitiesOnly yes
  UserKnownHostsFile ~/.ssh/devmesh_known_hosts
  StrictHostKeyChecking yes
$(min_cfg hub.example.test)"
}

@test "known_hosts: the hub entry is rebuilt from its key, a widened host list is not copied" {
  enroll_owner
  printf 'hub.example.test,* ssh-ed25519 PINNED\n' >"$HOME/.ssh/devmesh_known_hosts"
  refresh_replies
  run dm_refresh
  [ "$status" -eq 0 ]
  grep -qx 'hub.example.test ssh-ed25519 PINNED' "$HOME/.ssh/devmesh_known_hosts"
  ! grep -q '\*' "$HOME/.ssh/devmesh_known_hosts"
}

@test "ssh-config: the control socket path fits the Unix limit on Termux" {
  enroll_machine lap
  run devmesh ssh-config
  local path
  path=$(sed -n 's/^  ControlPath ~//p' <<<"$output" | head -n1)
  # Termux home (32) + path with the longest alias (16 chars, -b suffix) + ssh's 17-byte
  # temporary suffix must stay under sun_path (104 on macOS/BSD, 108 on Linux).
  local longest=${path//%n/abcdefghijklmnop-b}
  (( 32 + ${#longest} + 17 < 104 ))
}

@test "refresh: the 0.8.0 ControlPath is still accepted (no device gets stuck)" {
  enroll_machine lap
  cfg_replies
  unset STUB_ADMIN_CMD
  ssh_reply hub-admin hosts "$(devmesh hosts)"$'\n'
  ssh_reply hub-admin ssh-config "$(devmesh ssh-config | sed 's#ControlPath ~/.ssh/dm-%n#ControlPath ~/.ssh/devmesh-%n-%C#')"$'\n'
  ssh_reply hub-admin known-hosts "$(devmesh known-hosts)"$'\n'
  run dm_refresh
  [ "$status" -eq 0 ]
  grep -q 'devmesh-%n-%C' "$HOME/.ssh/config.d/devmesh"
}
