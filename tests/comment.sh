#!/usr/bin/env bash
# shellcheck disable=SC2015 # ok() never fails, so `cond && ok || bad` is if-then-else here
# tests/comment.sh COMMENT_BIN — flake-diff-comment against fixture reports,
# in --dry-run, which prints the request instead of sending it. Covers the
# summary line, the marker that finds the comment again on the next push,
# the split that posts a large report whole over several comments, and the
# edits and deletions a later push makes (against a fake curl).
set -euo pipefail

bin="${1:?usage: tests/comment.sh COMMENT_BIN}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export API_URL=https://forge.invalid/api REPO=o/r PR=7 SHA=0123456789abcdef0123
fails=0
ok() { echo "ok: $1"; }
bad() { echo "FAIL: $1" >&2; fails=$((fails + 1)); }

report() {
  cat > "$tmp/$1"
}

report changed <<'R'
base     origin/main (cadbf85)

inputs
   nixpkgs                    e7a3ca8092b6 2026-07-11 -> e7439b6b14ad 2026-10-08

attributes
  packages.x86_64-linux.a changes: 3 of 40 derivations differ
  packages.x86_64-linux.b identical

package versions (evaluation only)
  openssl                  3.5.1 -> 3.5.2
R
report unreached <<'R'
base     origin/main (cadbf85)

inputs
   nixpkgs                    e7a3ca8092b6 2026-07-11 -> e7439b6b14ad 2026-10-08

attributes
  packages.x86_64-linux.a identical

The lock change does not reach any attribute.
R
report same <<'R'
base     origin/main (cadbf85)
flake.lock is identical to origin/main's; nothing to compare.
R

out="$("$bin" --dry-run "$tmp/changed")"
grep -qx 'POST https://forge.invalid/api/repos/o/r/issues/7/comments' <<<"$out" \
  && ok "a first report is posted to the pull request" || bad "request line: $(head -1 <<<"$out")"
grep -qxF '<!-- flake-diff-action -->' <<<"$out" \
  && ok "the body carries the marker that finds it on the next push" || bad "no marker"
grep -qxF '**1 of 2 attributes change.**' <<<"$out" \
  && ok "the summary counts the attributes that change" || bad "summary: $(grep -F '**' <<<"$out")"
grep -qF 'openssl                  3.5.1 -> 3.5.2' <<<"$out" \
  && ok "the report is in the body" || bad "report missing"
grep -qxF '<sub>at 0123456789ab</sub>' <<<"$out" \
  && ok "the footer names the commit" || bad "footer"

out="$("$bin" --dry-run "$tmp/unreached")"
grep -qxF '**No built attribute changes.**' <<<"$out" \
  && ok "a lock change that reaches nothing says so" || bad "unreached summary: $(grep -F '**' <<<"$out" || true)"

out="$("$bin" --dry-run "$tmp/same")"
grep -qxF 'flake.lock is unchanged.' <<<"$out" \
  && ok "an unchanged lock says so" || bad "unchanged summary"


# --- the whole report, split over comments --------------------------------------
# reassemble FILE: the report text inside every part's code fence, in order.
reassemble() { awk '/^```text$/ { on = 1; next } /^```$/ { on = 0; next } on' "$1"; }

{ cat "$tmp/changed"; for i in $(seq 1 400); do echo "  package-$i                1.0 -> 1.1"; done; } > "$tmp/large"
FLAKE_DIFF_PART_CHARS=2000 "$bin" --dry-run "$tmp/large" > "$tmp/large.out"
posts=$(grep -c '^POST ' "$tmp/large.out")
if [ "$posts" -gt 2 ] && reassemble "$tmp/large.out" | cmp -s - "$tmp/large"; then
  ok "a large report is split over $posts comments, and their parts add up to the whole report"
else
  bad "large report: $posts comment(s); reassembled differs: $(reassemble "$tmp/large.out" | diff - "$tmp/large" | head -5)"
fi
grep -qxF "### flake.lock impact, part $posts of $posts" "$tmp/large.out" \
  && grep -qxF "<!-- flake-diff-action part $posts -->" "$tmp/large.out" \
  && grep -qF "The report continues in the next $((posts - 1)) comment(s)." "$tmp/large.out" \
  && ok "each part is numbered and marked, and the first says more follow" || bad "part headings"
too_big=$(awk '/^(POST|PATCH) / { if (n > 2600) print n; n = 0; next } { n += length($0) + 1 } END { if (n > 2600) print n }' "$tmp/large.out")
[ -z "$too_big" ] && ok "no comment outgrows its part size plus the markup" || bad "oversized comment: $too_big"

# One line longer than a part is split across parts, never dropped.
{ echo attributes; printf '  %s\n' "$(head -c 5000 /dev/zero | tr '\0' x)"; } > "$tmp/longline"
FLAKE_DIFF_PART_CHARS=2000 "$bin" --dry-run "$tmp/longline" > "$tmp/longline.out"
# The cut inside the line gains a newline at each part's end; join them back.
if [ "$(reassemble "$tmp/longline.out" | tr -d '\n')" = "$(tr -d '\n' < "$tmp/longline")" ]; then
  ok "a line longer than a part is carried whole across parts"
else bad "a long line lost characters"; fi

# --- a later push edits the parts in place and removes stale ones --------------
# A fake curl: GET returns the PR's comments (page 1 only), everything else is
# logged as "METHOD URL".
mkdir -p "$tmp/bin"
# Its shebang is this bash: a build sandbox has no /usr/bin/env.
{ printf '#!%s\n' "$BASH"; cat <<'C'
method=GET url=
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    -H|--data) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
if [ "$method" = GET ]; then
  case "$url" in *'&page=1') cat "$COMMENTS" ;; *) echo '[]' ;; esac
else
  echo "$method $url" >> "$CALLS"
  echo '{}'
fi
C
} > "$tmp/bin/curl"
chmod +x "$tmp/bin/curl"
# Earlier: three parts (ids 11, 12, 13), plus someone else's comment quoting
# the marker mid-text, which must be left alone.
cat > "$tmp/comments.json" <<'J'
[
  {"id": 11, "body": "<!-- flake-diff-action -->\n### flake.lock impact, part 1 of 3"},
  {"id": 20, "body": "see the comment with <!-- flake-diff-action --> above"},
  {"id": 12, "body": "<!-- flake-diff-action part 2 -->\n### flake.lock impact, part 2 of 3"},
  {"id": 13, "body": "<!-- flake-diff-action part 3 -->\n### flake.lock impact, part 3 of 3"}
]
J
: > "$tmp/calls"
PATH="$tmp/bin:$PATH" COMMENTS="$tmp/comments.json" CALLS="$tmp/calls" TOKEN=t \
  FLAKE_DIFF_PART_CHARS=2000 "$bin" "$tmp/changed" > /dev/null
if [ "$(cat "$tmp/calls")" = "PATCH https://forge.invalid/api/repos/o/r/issues/comments/11
DELETE https://forge.invalid/api/repos/o/r/issues/comments/12
DELETE https://forge.invalid/api/repos/o/r/issues/comments/13" ]; then
  ok "a shorter report edits part 1 and deletes the parts it no longer needs"
else bad "calls for a shorter report:
$(cat "$tmp/calls")"; fi

: > "$tmp/calls"
PATH="$tmp/bin:$PATH" COMMENTS="$tmp/comments.json" CALLS="$tmp/calls" TOKEN=t \
  FLAKE_DIFF_PART_CHARS=2000 "$bin" "$tmp/large" > /dev/null
if [ "$(sed -n 1,3p "$tmp/calls")" = "PATCH https://forge.invalid/api/repos/o/r/issues/comments/11
PATCH https://forge.invalid/api/repos/o/r/issues/comments/12
PATCH https://forge.invalid/api/repos/o/r/issues/comments/13" ] \
   && [ "$(sed -n '4,$p' "$tmp/calls" | grep -vc '^POST https://forge.invalid/api/repos/o/r/issues/7/comments$')" = 0 ] \
   && [ "$(wc -l < "$tmp/calls")" = "$posts" ]; then
  ok "a longer report edits the existing parts and posts the rest"
else bad "calls for a longer report:
$(cat "$tmp/calls")"; fi

[ "$fails" -eq 0 ] || { echo "$fails comment case(s) failed" >&2; exit 1; }
echo "comment: all cases pass"
