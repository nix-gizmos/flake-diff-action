#!/usr/bin/env bash
# The action's one step: check the runner, make the baseline commit
# available, run flake-diff, and hand the report to flake-diff-comment.
# Inputs arrive as IN_* environment variables (see action.yml), never
# interpolated into the script, so no input can inject shell.
set -euo pipefail

command -v nix >/dev/null || {
  echo "::error::flake-diff-action needs nix on PATH: run in a Nix image, or install Nix in an earlier step"
  exit 1
}
# Whatever installed Nix, the two commands used here must be available.
export NIX_CONFIG="extra-experimental-features = nix-command flakes${NIX_CONFIG:+
$NIX_CONFIG}"

base="${IN_BASE:-HEAD^}"
# A shallow checkout (the default almost everywhere) lacks the baseline.
# Fetch just that commit; for HEAD^ deepen by one instead.
if ! git rev-parse -q --verify "$base^{commit}" >/dev/null; then
  if [ "$base" = 'HEAD^' ]; then
    git fetch -q --no-tags --deepen=1 origin
  else
    git fetch -q --no-tags --depth=1 origin "$base"
  fi
fi

args=(--base "$base")
[ -z "$IN_KEY" ] || args+=(--key "$IN_KEY")
[ "$IN_IMPURE" != true ] || args+=(--impure)
[ "$IN_BUILD" != true ] || args+=(--build)
read -ra attrs <<<"$IN_ATTRIBUTES"

report="${RUNNER_TEMP:-/tmp}/flake-diff.txt"
# The action's own flake pins the tools both scripts need, so the runner
# image only has to provide nix and git.
nix run "path:$ACTION_PATH#flake-diff" -- "${args[@]}" ${attrs[@]+"${attrs[@]}"} | tee "$report"

{
  echo "report=$report"
  if grep -q ' changes: ' "$report"; then echo changed=true; else echo changed=false; fi
} >> "$GITHUB_OUTPUT"

if [ "$IN_COMMENT" = true ] && [ -n "$PR" ]; then
  # Forgejo runners from v7 set FORGEJO_API_URL (…/api/v1) and alias it as
  # GITHUB_API_URL; older ones may not, hence the api-url input.
  api="${IN_API_URL:-${FORGEJO_API_URL:-${GITHUB_API_URL:-https://api.github.com}}}"
  # A pull request from a fork gets a read-only token on both forges. The
  # report is in the log either way, so a refused comment is not a failure.
  API_URL="$api" nix run "path:$ACTION_PATH#flake-diff-comment" -- "$report" \
    || echo "::warning::could not comment on the pull request (read-only token, e.g. from a fork?); the report is in this log"
fi
