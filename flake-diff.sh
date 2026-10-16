#!/usr/bin/env bash
# What does a flake.lock change do to what this flake builds?
#
#   flake-diff [--base REF] [--key REGEX] [--all] [--impure] [--build] ATTR...
#
#   --base REF    compare against flake.lock as committed at REF (default HEAD)
#   --key REGEX   list only packages whose name matches REGEX (an awk ERE,
#                 e.g. '^(openssl|linux|qemu.*)$'); the rest are counted
#   --all         list every changed package, ignoring --key
#   --impure      evaluate with --impure, e.g. for NIXPKGS_ALLOW_UNFREE
#   --build       also build both sides of every attribute that changed and
#                 print `nix store diff-closures` (runtime closure, sizes)
#   ATTR          flake attributes, without '.#' (default:
#                 packages.<current system>.default)
#
# Run it from the flake's directory. The lock diff says which inputs moved,
# not whether a move reaches anything you build. Each ATTR is evaluated twice
# from the same working tree: once with its own flake.lock and once with REF's,
# passed as --reference-lock-file. Only the pinned revisions differ between
# the sides, and a lock-maintenance change that moves several inputs is judged
# as one change.
#
# Nothing is built by default. Equal .drv paths prove an attribute identical.
# When they differ, the two derivation closures are compared by package name,
# which surfaces version bumps from evaluation alone. The exit status says
# whether the comparison ran, not whether anything changed.
set -euo pipefail

base=HEAD key='' all=0 build=0 attrs=() impure=()
while [ $# -gt 0 ]; do
  case "$1" in
    --base) base="${2:?--base needs a git ref}"; shift 2 ;;
    --key) key="${2:?--key needs a regex}"; shift 2 ;;
    --all) all=1; shift ;;
    --impure) impure=(--impure); shift ;;
    --build) build=1; shift ;;
    -h|--help) sed -n '/^# What does a flake.lock/,/^set -euo/s/^# \{0,1\}//p' "${BASH_SOURCE[0]}"; exit 0 ;;
    -*) echo "flake-diff: unknown option $1 (try --help)" >&2; exit 2 ;;
    *) attrs+=("$1"); shift ;;
  esac
done

[ -f flake.lock ] || { echo "flake-diff: no flake.lock in $PWD" >&2; exit 1; }
if [ ${#attrs[@]} -eq 0 ]; then
  attrs=("packages.$(nix eval --raw --impure --expr builtins.currentSystem).default")
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

git show "$base:./flake.lock" > "$tmp/base.lock" 2>/dev/null \
  || { echo "flake-diff: no flake.lock at $base" >&2; exit 1; }

printf 'base     %s (%s)\n' "$base" "$(git rev-parse --short "$base")"
if cmp -s "$tmp/base.lock" flake.lock; then
  echo "flake.lock is identical to $base's; nothing to compare."
  exit 0
fi

# Both sides read the same working tree, so a dirty tree is copied into the
# store once, not once per side. Neither side may rewrite flake.lock.
nixe() {
  local side="$1"; shift
  local lock=()
  [ "$side" = new ] || lock=(--reference-lock-file "$tmp/base.lock")
  if ! nix "$@" "${impure[@]}" --no-write-lock-file "${lock[@]}" 2>"$tmp/err"; then
    cat "$tmp/err" >&2
    return 1
  fi
}

# What Nix actually locks on the old side. A reference lock is only honoured
# where it still satisfies flake.nix: if flake.nix now asks for a different
# source (github:…/v1 became …/v2), Nix silently re-locks that input and the
# "old" side gets the new revision. Reading the lock back is the only way to
# notice.
nixe old flake metadata --json > "$tmp/old-meta.json"

# Inputs whose locked content changed, read straight from the lock files.
# narHash catches every input type; rev and lastModified are only for display.
echo
echo "inputs"
# shellcheck disable=SC2016 # ${…} below is Nix interpolation, not shell
BASE_LOCK="$tmp/base.lock" NEW_LOCK="$PWD/flake.lock" OLD_META="$tmp/old-meta.json" \
nix eval --impure --raw --expr '
  let
    json = v: builtins.fromJSON (builtins.readFile (builtins.getEnv v));
    old = (json "BASE_LOCK").nodes;
    new = (json "NEW_LOCK").nodes;
    used = (json "OLD_META").locks.nodes;
    locked = ns: n: (ns.${n} or { }).locked or null;
    same = a: b: a == b || (a != null && b != null && a.narHash == b.narHash);
    show = l: if l == null then "- 0"
      else "${builtins.substring 0 12 (l.rev or l.narHash)} ${toString (l.lastModified or 0)}";
    names = builtins.filter (n: !same (locked old n) (locked new n))
      (builtins.attrNames (old // new));
    kept = n: if same (locked old n) (locked used n) then "kept" else "relocked";
  in
    builtins.concatStringsSep "" (map (n:
      "${n} ${show (locked old n)} ${show (locked new n)} ${kept n}\n") names)
' > "$tmp/inputs"

day() { if [ "$1" = 0 ]; then echo '-'; else date -u -d "@$1" +%F; fi; }
relocked=0
while read -r name orev ots nrev nts kept; do
  mark=' '
  [ "$kept" = kept ] || { mark='*'; relocked=$((relocked + 1)); }
  printf ' %s %-26s %-12s %-10s -> %-12s %s\n' "$mark" "$name" "$orev" "$(day "$ots")" "$nrev" "$(day "$nts")"
done < "$tmp/inputs"
if [ "$relocked" -gt 0 ]; then
  echo "  * not rolled back: new since $base, or flake.nix now asks for a different"
  echo "    source. Both sides use the new lock for these; the change came with a"
  echo "    flake.nix edit, which a lock-only comparison leaves out."
fi

echo
echo "attributes"
changed=()
for a in "${attrs[@]}"; do
  old_drv="$(nixe old eval --raw ".#$a.drvPath")"
  new_drv="$(nixe new eval --raw ".#$a.drvPath")"
  if [ "$old_drv" = "$new_drv" ]; then
    printf '  %-20s identical\n' "$a"
    continue
  fi
  # Closures are stored by index: attribute names contain dots and slashes.
  i=${#changed[@]}
  nix-store -qR "$old_drv" | sort > "$tmp/$i.old"
  nix-store -qR "$new_drv" | sort > "$tmp/$i.new"
  printf '  %-20s changes: %d of %d derivations differ\n' "$a" \
    "$(comm -13 "$tmp/$i.old" "$tmp/$i.new" | grep -c '\.drv$' || true)" \
    "$(grep -c '\.drv$' "$tmp/$i.new" || true)"
  changed+=("$a")
done

if [ ${#changed[@]} -eq 0 ]; then
  echo
  if [ "$relocked" -gt 0 ]; then
    echo "The inputs that could be rolled back do not reach any attribute."
  else
    echo "The lock change does not reach any attribute."
  fi
  exit 0
fi

# Version changes across every changed attribute at once: attributes of one
# flake share most of their closure, so per-attribute lists would repeat
# themselves. A name splits into pname and version at the first dash followed
# by a non-letter, the rule builtins.parseDrvName uses. Source archives,
# patches and the vendor/deps helpers that ride along with a package are not
# packages and are skipped.
#
# The derivation closure is the build closure, compilers included, so a
# nixpkgs bump lists hundreds of names; --key narrows the list to the ones
# that matter to you and counts the rest.
echo
echo "package versions (evaluation only)"
for ((i = 0; i < ${#changed[@]}; i++)); do
  sed "s/^/old /" "$tmp/$i.old"
  sed "s/^/new /" "$tmp/$i.new"
done \
  | awk '
    $2 ~ /\.drv$/ {
      n = $2; sub(/^\/nix\/store\/[0-9a-z]+-/, "", n); sub(/\.drv$/, "", n)
      if (n ~ /\.(tar(\.[a-z0-9]+)?|tgz|zip|patch|diff|cabal|gem|crate|whl|zst)$/) next
      if (n ~ /-(source|vendor|vendor-staging|npm-deps|go-modules|modules|modules-shrunk)$/) next
      if (match(n, /-[^a-zA-Z-]/)) print substr(n, 1, RSTART - 1) "\t" $1 "\t" substr(n, RSTART + 1)
    }' \
  | LC_ALL=C sort -u \
  | awk -F '\t' -v key="$key" -v all="$all" '
    # Input is sorted by package, side, version, so the joined lists compare
    # equal exactly when both sides hold the same set of versions.
    function flush() {
      if (p != "" && v["old"] != v["new"]) {
        if (all || key == "" || p ~ key)
          printf "  %-24s %s -> %s\n", p, (v["old"] == "" ? "-" : v["old"]), (v["new"] == "" ? "-" : v["new"])
        else
          rest++
      }
      v["old"] = v["new"] = ""
    }
    $1 != p { flush(); p = $1 }
    { v[$2] = v[$2] (v[$2] == "" ? "" : ", ") $3 }
    END {
      flush()
      if (rest) printf "  … and %d more packages outside --key (--all lists them)\n", rest
    }'

if [ "$build" != 1 ]; then
  echo
  echo "Run with --build for runtime closures and sizes."
  exit 0
fi

for a in "${changed[@]}"; do
  echo
  echo "building .#$a, both sides ..."
  old_out="$(nixe old build --no-link --print-out-paths ".#$a")"
  new_out="$(nixe new build --no-link --print-out-paths ".#$a")"
  echo "nix store diff-closures $old_out $new_out"
  nix store diff-closures "$old_out" "$new_out"
done
