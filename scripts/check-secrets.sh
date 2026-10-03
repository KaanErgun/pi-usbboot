#!/usr/bin/env bash
# Fail closed before a commit/push; never print credential values.
set -euo pipefail

cd "$(dirname "$0")/.."
repo_root=$(git rev-parse --show-toplevel)
cd "$repo_root"

mode=${1:-staged}
case "$mode" in
  staged|history|pre-push) ;;
  *) printf 'Usage: %s [staged|history|pre-push]\n' "$0" >&2; exit 2 ;;
esac

history_revisions=(--all)
if [[ "$mode" == pre-push ]]; then
  # A SHA refspec can push an object unreachable from local refs. Include the
  # exact objects supplied by Git's hook protocol; never interpret ref names.
  while IFS=' ' read -r local_ref local_oid remote_ref remote_oid extra; do
    if [[ ! "$local_oid" =~ ^[0-9a-fA-F]{40}$ && ! "$local_oid" =~ ^[0-9a-fA-F]{64}$ ]]; then
      printf 'Secret check blocked: invalid pre-push object ID.\n' >&2
      exit 1
    fi
    if [[ ! "$local_oid" =~ ^0+$ ]]; then
      history_revisions+=("$local_oid")
    fi
  done
fi

if ! command -v gitleaks >/dev/null 2>&1; then
  printf 'Secret check blocked: install gitleaks first (macOS: brew install gitleaks).\n' >&2
  exit 1
fi
if [[ ! -f .gitignore || ! -f .gitleaks.toml ]]; then
  printf 'Secret check blocked: .gitignore and .gitleaks.toml are required.\n' >&2
  exit 1
fi

scan_tmp=$(mktemp -d "${TMPDIR:-/tmp}/pi-secrets.XXXXXX")
trap 'rm -rf "$scan_tmp"' EXIT

# Use only repository .gitignore files; a contributor's global excludes must not
# change policy. Check the entire index, including files added with git add -f.
git ls-files --cached --ignored --exclude-per-directory=.gitignore -z >"$scan_tmp/ignored"
reject_ignored_paths() {
  if [[ -s "$scan_tmp/ignored" ]]; then
    printf 'Secret check blocked: these %s paths match repository .gitignore rules:\n' "$1" >&2
    while IFS= read -r -d '' ignored_path; do
      printf '  %q\n' "$ignored_path" >&2
    done <"$scan_tmp/ignored"
    printf 'Keep private files outside the Git index and commit history.\n' >&2
    exit 1
  fi
}
reject_ignored_paths indexed

if [[ "$mode" != staged ]]; then
  # A binary key store or transcript remains publishable after deletion if an
  # earlier commit contains it. Inspect every tree using an isolated index and
  # today's ignore policy; never change the user's actual index or worktree.
  git rev-list "${history_revisions[@]}" >"$scan_tmp/commits"
  while IFS= read -r history_commit; do
    GIT_INDEX_FILE="$scan_tmp/history-index" git -c core.splitIndex=false -c core.sparseCheckout=false read-tree --reset "$history_commit"
    GIT_INDEX_FILE="$scan_tmp/history-index" git ls-files --cached --ignored --exclude-per-directory=.gitignore -z >"$scan_tmp/ignored"
    reject_ignored_paths "historical ($history_commit)"
  done <"$scan_tmp/commits"
fi

# An untracked .gitleaksignore must not silently suppress findings.
: >"$scan_tmp/.gitleaksignore"
scan_args=(git --config "$repo_root/.gitleaks.toml" --redact=100 --no-banner --no-color --ignore-gitleaks-allow --gitleaks-ignore-path "$scan_tmp/.gitleaksignore" --max-decode-depth=5)
if [[ "$mode" == staged ]]; then
  scan_args+=(--pre-commit --staged)
else
  # Only --all and validated hexadecimal object IDs enter this option string.
  scan_args+=("--log-opts=${history_revisions[*]}")
fi
gitleaks "${scan_args[@]}" "$repo_root"
