SCRIPTS := flake-diff.sh comment.sh action.sh .githooks/pre-commit tests/comment.sh

.PHONY: all lint test hooks release release-notes release-tag release-tag-preview clean

all: lint test

# Points git at the version-controlled hooks in .githooks (pre-commit runs the
# linter). Per-clone, so each contributor runs it once.
hooks:
	git config core.hooksPath .githooks
	@echo "installed git hooks from .githooks"

# shellcheck on every script, the version pinned by the flake when run in the
# dev shell. The packages' builds run it again (writeShellApplication).
lint:
	shellcheck -x $(SCRIPTS)

# Every flake check: both packages (their builds shellcheck the scripts),
# action.sh, and the comment script against fixture reports. The action
# itself runs end to end in CI's `self` job, on this repository's own lock.
test:
	nix flake check -L

# Publishes the GitHub release for the current tag. Invoked by CI on tag push;
# needs GITHUB_TOKEN and a clean tagged tree. Re-runs the gates first so a
# local `make release` matches what CI enforces.
# There are no release archives: the action and the flake are used straight
# from the tag, so the release is the tag plus its notes. The notes come from
# git-cliff (see cliff.toml), which owns the whole body -- header, changelog,
# footer.
release: lint test
	@tag="$$(git describe --tags --exact-match HEAD)" || { \
		echo "HEAD is not tagged — run \`make release-tag\` first." >&2; exit 1; }; \
	notes="$$(mktemp)"; \
	git-cliff --latest > "$$notes" || { rm -f "$$notes"; exit 1; }; \
	gh release create "$$tag" --verify-tag --title "$$tag" --notes-file "$$notes"; \
	rc=$$?; rm -f "$$notes"; exit $$rc

# Preview the release notes for the current tag without releasing anything.
release-notes:
	@git-cliff --latest

# Preview the version `release-tag` would cut, without touching anything.
# gsemver derives it from the conventional-commit history since the last tag,
# and it fetches, so this needs network access to the remote.
release-tag-preview:
	@v="$$(gsemver bump)"; \
	test -n "$$v" || { echo "gsemver produced no version — is the remote reachable?" >&2; exit 1; }; \
	printf "next tag: v%s\n" "$$v"

# Computes the next version from conventional-commit history, writes it into
# ./VERSION (the source of truth the flake reads), commits that as the release
# commit, tags it, and pushes branch + tag -- which triggers the release job.
# Because the version is committed *before* the tag, the tagged tree's Nix
# build and the tag report the same version. The chore commit is a non-bumping
# type, so it does not skew the next gsemver bump.
# Override the version with `make release-tag VERSION=1.2.3`.
#
# The tag is signed with -s. tag.forcesignannotated does NOT achieve this: git
# gives an explicit --annotate/-a precedence over that config, so `git tag -a`
# produces an unsigned tag however the config is set.
release-tag:
	$(eval VERSION ?= $(shell gsemver bump))
	@test -n "$(VERSION)" || { \
		echo "gsemver produced no version — refusing to tag." >&2; \
		echo "make hides a failing command inside its shell function, and an empty" >&2; \
		echo "version would tag and push a ref literally named v. Check the remote" >&2; \
		echo "is reachable and gsemver is on PATH." >&2; \
		exit 1; \
	}
	@git config --get user.signingkey >/dev/null || { \
		echo "user.signingkey is unset — the signed tag would fail after the" >&2; \
		echo "release commit was already made, leaving a half-cut release." >&2; \
		exit 1; \
	}
	@printf '%s\n' "$(VERSION)" > VERSION
	git add VERSION
	git commit -m "chore: release v$(VERSION)" VERSION
	git tag -s "v$(VERSION)" -m "Release v$(VERSION)"
	git push origin HEAD "v$(VERSION)"

clean:
	rm -rf result result-*
