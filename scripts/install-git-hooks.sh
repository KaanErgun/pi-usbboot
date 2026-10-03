#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
repo_root=$(git rev-parse --show-toplevel)
cd "$repo_root"

for hook in .githooks/pre-commit .githooks/pre-push scripts/check-secrets.sh; do
  if [[ ! -x "$hook" ]]; then
    printf 'Cannot install hooks: %s must exist and be executable.\n' "$hook" >&2
    exit 1
  fi
done

hooks_path=''
if hooks_path=$(git config --get core.hooksPath); then
  case "$hooks_path" in
    .githooks|"$repo_root/.githooks")
      printf 'Repository secret-check hooks are already configured.\n'
      exit 0
      ;;
    *)
      printf 'Cannot install hooks: core.hooksPath already points elsewhere.\n' >&2
      printf 'Integrate the repository hooks with your existing hooks explicitly.\n' >&2
      exit 1
      ;;
  esac
else
  config_status=$?
  if [[ "$config_status" -ne 1 ]]; then
    printf 'Cannot read the existing Git hooks configuration.\n' >&2
    exit "$config_status"
  fi
fi

existing_hooks=$(git rev-parse --git-path hooks)
if [[ -d "$existing_hooks" ]]; then
  shopt -s nullglob dotglob
  for hook in "$existing_hooks"/*; do
    case "$hook" in *.sample) continue ;; esac
    printf 'Cannot install hooks: an existing hook would be bypassed: %q\n' "$hook" >&2
    printf 'Integrate the repository hooks with your existing hooks explicitly.\n' >&2
    exit 1
  done
fi

git config --local core.hooksPath .githooks
printf 'Installed repository pre-commit and pre-push secret checks.\n'
