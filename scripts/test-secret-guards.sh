#!/usr/bin/env bash
# All fixtures and Git configuration changes stay in temporary repositories.
set -euo pipefail
source_root=$(cd "$(dirname "$0")/.." && pwd)
for required in git gitleaks openssl; do
  command -v "$required" >/dev/null 2>&1 || { printf 'Missing test dependency: %s\n' "$required" >&2; exit 1; }
done
test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/cm5-secret-tests.XXXXXX")
trap 'rm -rf "$test_tmp"' EXIT
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR

new_repo() {
  repo="$test_tmp/$1"
  git init -q "$repo"
  cd "$repo"
  git config user.name 'Secret guard test'
  git config user.email 'secret-guard@example.invalid'
  mkdir -p scripts .githooks
  cp "$source_root/.gitignore" "$source_root/.gitleaks.toml" .
  cp "$source_root/scripts/check-secrets.sh" "$source_root/scripts/install-git-hooks.sh" scripts/
  cp "$source_root/.githooks/pre-commit" "$source_root/.githooks/pre-push" .githooks/
  git add .
  git -c commit.gpgsign=false commit -qm 'Clean fixture'
}

expect_blocked() {
  local label=$1
  shift
  if "$@" >"$test_tmp/output" 2>&1; then
    printf 'FAIL: %s was allowed.\n' "$label" >&2
    exit 1
  fi
  printf 'PASS: %s blocked.\n' "$label"
}

new_repo clean
scripts/install-git-hooks.sh >"$test_tmp/output"
printf 'A harmless change.\n' > harmless.txt
git add harmless.txt
git -c commit.gpgsign=false commit -qm 'Clean commit' >"$test_tmp/output" 2>&1
scripts/check-secrets.sh history >"$test_tmp/output" 2>&1
printf 'PASS: clean commit and history allowed.\n'

# Assemble synthetic data so the tests themselves contain no secret-shaped value.
synthetic_password=$(printf '%s%s%s%s' 'abcd-' 'efgh-' 'ijkl-' 'mnop')
printf 'Password: %s\n' "$synthetic_password" > credentials.txt
git add credentials.txt
expect_blocked 'staged Apple app-specific password' git -c commit.gpgsign=false commit -qm 'Blocked credential'
if grep -Fq "$synthetic_password" "$test_tmp/output"; then
  printf 'FAIL: the secret value appeared in scanner output.\n' >&2
  exit 1
fi
git reset -q -- credentials.txt
rm credentials.txt

openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out credentials.txt >"$test_tmp/keygen-output" 2>&1
git add credentials.txt
expect_blocked 'staged private key in a .txt file' scripts/check-secrets.sh staged
git reset -q -- credentials.txt
rm credentials.txt

for ignored in .env claude-log.md; do
  printf 'Harmless text in a prohibited path.\n' >"$ignored"
  git add -f -- "$ignored"
  expect_blocked "force-added $ignored" scripts/check-secrets.sh staged
  if ! grep -Fq 'indexed paths match repository .gitignore' "$test_tmp/output"; then
    printf 'FAIL: %s was not rejected by the indexed-path guard.\n' "$ignored" >&2
    exit 1
  fi
  git reset -q -- "$ignored"
  rm -- "$ignored"
done

# Restrict PATH to core shell/Git utilities to exercise the fail-closed branch.
mkdir "$test_tmp/no-gitleaks"
ln -s "$(command -v git)" "$test_tmp/no-gitleaks/git"
ln -s "$(command -v dirname)" "$test_tmp/no-gitleaks/dirname"
expect_blocked 'missing gitleaks' env PATH="$test_tmp/no-gitleaks" /bin/bash scripts/check-secrets.sh staged
if ! grep -Fq 'install gitleaks first' "$test_tmp/output"; then
  printf 'FAIL: missing-tool check failed for an unrelated reason.\n' >&2
  exit 1
fi

new_repo history
printf 'Password: %s\n' "$synthetic_password" > old-credential.txt
git add old-credential.txt
git -c commit.gpgsign=false commit -qm 'Historical synthetic credential'
git rm -q old-credential.txt
git -c commit.gpgsign=false commit -qm 'Remove synthetic credential'
scripts/install-git-hooks.sh >"$test_tmp/output"
git init --bare -q "$test_tmp/remote.git"
expect_blocked 'push containing a deleted historical secret' git push "$test_tmp/remote.git" HEAD:refs/heads/main
if ! grep -Fq 'leaks found' "$test_tmp/output"; then
  printf 'FAIL: historical push failed for an unrelated reason.\n' >&2
  exit 1
fi
if grep -Fq "$synthetic_password" "$test_tmp/output"; then
  printf 'FAIL: the historical secret appeared in scanner output.\n' >&2
  exit 1
fi

new_repo history_binary
printf '\000\001\002Synthetic signing-key fixture\000' > retired-signing.p12
git add -f retired-signing.p12
git -c commit.gpgsign=false commit -qm 'Historical synthetic binary signing key'
git rm -q retired-signing.p12
git -c commit.gpgsign=false commit -qm 'Remove synthetic signing key'
scripts/install-git-hooks.sh >"$test_tmp/output"
git init --bare -q "$test_tmp/binary-remote.git"
index_before=$(git hash-object .git/index)
expect_blocked 'push containing a deleted binary signing-key path' git push "$test_tmp/binary-remote.git" HEAD:refs/heads/main
if ! grep -Fq 'historical (' "$test_tmp/output" || ! grep -Fq 'retired-signing.p12' "$test_tmp/output"; then
  printf 'FAIL: historical binary push failed for an unrelated reason.\n' >&2
  exit 1
fi
[[ $(git hash-object .git/index) == "$index_before" ]]

new_repo dangling_history
printf 'Password: %s\n' "$synthetic_password" > detached-credential.txt
git add detached-credential.txt
git -c commit.gpgsign=false commit -qm 'Unreferenced synthetic credential'
secret_commit=$(git rev-parse HEAD)
git reset --hard -q HEAD~1
scripts/install-git-hooks.sh >"$test_tmp/output"
# --all is clean; only the hook's exact to-be-pushed object ID exposes this leak.
scripts/check-secrets.sh history >"$test_tmp/output" 2>&1
git init --bare -q "$test_tmp/dangling-remote.git"
expect_blocked 'push of an unreferenced secret commit via SHA' git push "$test_tmp/dangling-remote.git" "$secret_commit:refs/heads/main"
if ! grep -Fq 'leaks found' "$test_tmp/output"; then
  printf 'FAIL: unreferenced commit push failed for an unrelated reason.\n' >&2
  exit 1
fi

new_repo existing_hooks
git config core.hooksPath custom-hooks
expect_blocked 'installation over another hooksPath' scripts/install-git-hooks.sh
[[ $(git config --get core.hooksPath) == custom-hooks ]]
git config --unset core.hooksPath
printf '#!/bin/sh\nexit 0\n' > .git/hooks/pre-commit
expect_blocked 'installation over a custom default hook' scripts/install-git-hooks.sh
[[ -f .git/hooks/pre-commit ]]
if git config --get core.hooksPath >/dev/null; then
  printf 'FAIL: installer modified hooksPath after refusing installation.\n' >&2
  exit 1
fi
printf 'All secret-guard regression checks passed.\n'
