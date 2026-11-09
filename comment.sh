#!/usr/bin/env bash
# Posts a flake-diff report on a pull request, or updates the one posted
# before, so each push edits the same comment instead of adding another.
#
#   flake-diff-comment [--dry-run] REPORT
#
# The whole report is posted, never a cut-down one. GitHub refuses a comment
# over 65536 characters, so a longer report is split at line boundaries over
# as many comments as it needs ("part 2 of 3", …). Each part carries a hidden
# marker with its number, so a later push edits every part in place, and
# deletes the parts a shorter report no longer needs.
#
# Environment: API_URL (https://api.github.com, or https://<forgejo>/api/v1),
# REPO (owner/name), PR (number), TOKEN, and optionally SHA for the footer.
# FLAKE_DIFF_PART_CHARS sets the report characters per comment (default
# 60000, leaving room for the markup). GitHub and Forgejo share the endpoints
# used here, so one code path serves both. --dry-run prints the requests
# instead of sending them.
set -euo pipefail

dry=0
[ "${1:-}" != --dry-run ] || { dry=1; shift; }
report="${1:?usage: flake-diff-comment [--dry-run] REPORT}"
: "${API_URL:?}" "${REPO:?}" "${PR:?}"
[ "$dry" = 1 ] || : "${TOKEN:?}"
limit="${FLAKE_DIFF_PART_CHARS:-60000}"

# Part 1's marker is the one earlier versions used, so their comment is
# found and edited too.
marker() { if [ "$1" = 1 ]; then echo '<!-- flake-diff-action -->'; else echo "<!-- flake-diff-action part $1 -->"; fi; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Split at line boundaries into parts of at most $limit characters. Only a
# single line longer than that is cut, and then into consecutive parts, so
# nothing is lost either way.
awk -v limit="$limit" -v dir="$tmp" '
  function next_part() { close(dir "/part." n); n++; size = 0 }
  BEGIN { n = 1; size = 0; printf "" > (dir "/part.1") }
  {
    line = $0 "\n"
    while (length(line) > limit) {
      if (size > 0) next_part()
      printf "%s", substr(line, 1, limit) > (dir "/part." n)
      line = substr(line, limit + 1)
      next_part()
    }
    if (size > 0 && size + length(line) > limit) next_part()
    printf "%s", line > (dir "/part." n)
    size += length(line)
  }
  END { if (size == 0 && n > 1) n--; print n > (dir "/count") }
' "$report"
parts="$(cat "$tmp/count")"

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

body() {
  local k="$1" title='### flake.lock impact' lead="$summary"
  if [ "$parts" -gt 1 ]; then
    title="$title, part $k of $parts"
    lead=''
    [ "$k" != 1 ] || lead="$summary The report continues in the next $((parts - 1)) comment(s)."
  fi
  printf '%s\n%s\n\n' "$(marker "$k")" "$title"
  [ -z "$lead" ] || printf '%s\n\n' "$lead"
  printf '```text\n'
  cat "$tmp/part.$k"
  # A part cut inside an over-long line has no final newline.
  [ -z "$(tail -c1 "$tmp/part.$k")" ] || echo
  printf '```\n'
  [ -z "${SHA:-}" ] || printf '<sub>at %s</sub>\n' "${SHA:0:12}"
}

api() {
  local method="$1" url="$2"; shift 2
  curl -fsS -X "$method" -H "Authorization: token $TOKEN" \
    -H 'Accept: application/json' -H 'Content-Type: application/json' "$@" "$url"
}

# Every comment this action posted, by part: "<part> <id>" per line. GitHub
# pages with per_page, Forgejo with limit; each ignores the other's
# parameter.
if [ "$dry" = 0 ]; then
  for page in $(seq 1 40); do
    batch="$(api GET "$API_URL/repos/$REPO/issues/$PR/comments?per_page=50&limit=50&page=$page")"
    [ "$(jq length <<<"$batch")" -gt 0 ] || break
    jq -r '.[] | select(.body | startswith("<!-- flake-diff-action")) | [(.body | split("\n") | first), (.id | tostring)] | join("\t")' <<<"$batch"
  done | awk -F '\t' '
    $1 == "<!-- flake-diff-action -->" { print 1, $2; next }
    match($1, /part [0-9]+/) { print substr($1, RSTART + 5, RLENGTH - 5), $2 }
  ' > "$tmp/existing"
else
  : > "$tmp/existing"
fi

send() {
  local method="$1" url="$2" k="${3:-}"
  if [ "$dry" = 1 ]; then
    printf '%s %s\n\n' "$method" "$url"
    [ -z "$k" ] || { body "$k"; echo; }
    return
  fi
  if [ -n "$k" ]; then
    api "$method" "$url" --data "$(body "$k" | jq -Rs '{body: .}')" > /dev/null
  else
    api "$method" "$url" > /dev/null
  fi
}

declare -A done_part=()
for k in $(seq 1 "$parts"); do
  id="$(awk -v k="$k" '$1 == k { print $2; exit }' "$tmp/existing")"
  if [ -n "$id" ]; then
    send PATCH "$API_URL/repos/$REPO/issues/comments/$id" "$k"
    done_part[$id]=1
  else
    send POST "$API_URL/repos/$REPO/issues/$PR/comments" "$k"
  fi
done
# Parts a longer report needed earlier, and any duplicates, are stale.
stale=0
while read -r _ id; do
  [ -z "${done_part[$id]:-}" ] || continue
  send DELETE "$API_URL/repos/$REPO/issues/comments/$id"
  stale=$((stale + 1))
done < "$tmp/existing"

[ "$dry" = 1 ] || echo "flake-diff: commented on $REPO#$PR in $parts part(s), removed $stale stale"
