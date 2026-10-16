#!/usr/bin/env bash
# Posts a flake-diff report on a pull request, or updates the one posted
# before, so each push edits a single comment instead of adding another.
#
#   flake-diff-comment [--dry-run] REPORT
#
# Environment: API_URL (https://api.github.com, or https://<forgejo>/api/v1),
# REPO (owner/name), PR (number), TOKEN, and optionally SHA for the footer.
# GitHub and Forgejo share the endpoints used here, so one code path serves
# both. --dry-run prints the request instead of sending it.
set -euo pipefail

dry=0
[ "${1:-}" != --dry-run ] || { dry=1; shift; }
report="${1:?usage: flake-diff-comment [--dry-run] REPORT}"
: "${API_URL:?}" "${REPO:?}" "${PR:?}"
[ "$dry" = 1 ] || : "${TOKEN:?}"

marker='<!-- flake-diff-action -->'

# One line up front, so the conversation view answers "does this matter?"
# without opening the report.
summary="$(awk '
  /^attributes$/ { on = 1; next }
  on && /^$/ { on = 0 }
  on && /identical$/ { n++ }
  on && /changes:/ { n++; c++ }
  /nothing to compare/ { same = 1 }
  END {
    if (same) print "flake.lock is unchanged."
    else if (c == 0) print "**No built attribute changes.**"
    else printf "**%d of %d attributes change.**\n", c, n
  }' "$report")"

# GitHub rejects comment bodies over 65536 characters; --all on a large
# nixpkgs bump can get there. Cut the report, never the markup around it.
text="$(head -c 60000 "$report")"
[ "$(wc -c < "$report")" -le 60000 ] || text="$text
… (truncated; the job log has the full report)"

body="$marker
### flake.lock impact

$summary

\`\`\`text
$text
\`\`\`
${SHA:+<sub>at ${SHA:0:12}</sub>}"

api() {
  local method="$1" url="$2"; shift 2
  curl -fsS -X "$method" -H "Authorization: token $TOKEN" \
    -H 'Accept: application/json' -H 'Content-Type: application/json' "$@" "$url"
}

# The comment that carries the marker, if any. GitHub pages with per_page,
# Forgejo with limit; each ignores the other's parameter.
existing=''
if [ "$dry" = 0 ]; then
  for page in $(seq 1 20); do
    batch="$(api GET "$API_URL/repos/$REPO/issues/$PR/comments?per_page=50&limit=50&page=$page")"
    existing="$(jq -r --arg m "$marker" 'map(select(.body | contains($m))) | first | .id // empty' <<<"$batch")"
    [ -z "$existing" ] && [ "$(jq length <<<"$batch")" -gt 0 ] || break
  done
fi

payload="$(jq -n --arg b "$body" '{body: $b}')"
if [ -n "$existing" ]; then
  method=PATCH url="$API_URL/repos/$REPO/issues/comments/$existing"
else
  method=POST url="$API_URL/repos/$REPO/issues/$PR/comments"
fi

if [ "$dry" = 1 ]; then
  printf '%s %s\n\n%s\n' "$method" "$url" "$body"
  exit 0
fi
api "$method" "$url" --data "$payload" > /dev/null
echo "flake-diff: $([ "$method" = PATCH ] && echo updated || echo posted) the comment on $REPO#$PR"
