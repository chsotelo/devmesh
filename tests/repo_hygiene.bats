#!/usr/bin/env bats
# Repository hygiene: no personal data, no key or backup artifacts, legal files present.

REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

# Literal words are split so this file does not contain them itself.
FORBIDDEN=(
  'sot''rian'
  'cy''sor'
  '38\.250\.'
  'ela''stika'
  'cso''telo\.dev'  # the email; the GitHub owner name is public
  '@gm''ail'
  'age1[0-9a-z]{58}'
)

@test "no personal data in repository files" {
  local pattern
  pattern="$(printf '%s|' "${FORBIDDEN[@]}")"
  pattern="${pattern%|}"
  # Private, git-ignored files (deploy.local.mk, PLAN-OSS.md, backups/) are never published.
  run grep -rIlE --exclude-dir=.git --exclude-dir=backups --exclude=deploy.local.mk \
    --exclude=PLAN-OSS.md --exclude=repo_hygiene.bats -e "$pattern" "$REPO"
  [ "$status" -le 1 ]
  [ -z "$output" ] || { printf 'personal data found in:\n%s\n' "$output"; false; }
}

@test "no age or tar.gz artifacts outside backups/" {
  run find "$REPO" \( -name '*.age' -o -name '*.tar.gz' \) \
    -not -path "$REPO/.git/*" -not -path "$REPO/backups/*"
  [ -z "$output" ] || { printf 'artifacts found:\n%s\n' "$output"; false; }
}

@test "legal and community files exist and LICENSE is MIT" {
  [ -f "$REPO/LICENSE" ]
  [ -f "$REPO/SECURITY.md" ]
  [ -f "$REPO/CONTRIBUTING.md" ]
  [ -f "$REPO/CHANGELOG.md" ]
  [ "$(head -n 1 "$REPO/LICENSE")" = "MIT License" ]
}

@test "awk regexes avoid {m,n} intervals (mawk on Debian/Ubuntu ignores them)" {
  run grep -rnE '~ /[^/]*\{[0-9]+,?[0-9]*\}' "$REPO/client" "$REPO/server" "$REPO/scripts"
  [ -z "$output" ]
}

@test "private deployment files are ignored by git" {
  command -v git >/dev/null && git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || skip "not a git checkout"
  for f in deploy.local.mk PLAN-OSS.md backups/x.age dist/dist.tgz; do
    git -C "$REPO" check-ignore -q "$f"
  done
}

@test "no tracked symlink points outside the repository" {
  command -v git >/dev/null && git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || skip "not a git checkout"
  local f target
  while IFS= read -r f; do
    target=$(readlink "$REPO/$f")
    [[ $target != /* ]] || { printf 'absolute symlink: %s -> %s\n' "$f" "$target"; false; }
  done < <(git -C "$REPO" ls-files -s | awk '$1 == "120000" {print $4}')
}
