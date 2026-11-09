# flake-diff-action

What does a `flake.lock` change do to what your flake builds?

`nix flake update` and Renovate's lock-file maintenance tell you which inputs
moved. They don't tell you whether a move reaches anything you ship, or what
it changes there. A two-week nixpkgs bump is thousands of commits, but often
only a handful of packages that matter to you change. `flake-diff` answers that
from **evaluation alone**, usually in under a minute, and can post the answer on
the pull request.

```text
base     cadbf851a30f (cadbf85)

inputs
   nixpkgs                    e7a3ca8092b6 2026-07-11 -> e7439b6b14ad 2026-10-08

attributes
  claude               changes: 5179 of 5360 derivations differ
  codex                changes: 5183 of 5364 derivations differ

package versions (evaluation only)
  claude-code              2.1.206 -> 2.1.292
  codex                    0.144.1 -> 0.161.0
  libslirp                 4.9.3 -> 4.9.5
  linux                    6.18.38 -> 6.18.55
  openssl                  3.6.3 -> 3.5.8
  qemu-host-cpu-only       11.0.1 -> 11.1.1
  virtiofsd                1.13.3 -> 1.14.0
  … and 659 more packages outside --key (--all lists them)
```

## How it works

Each attribute is evaluated twice from the same working tree: once with its
own `flake.lock`, once with the baseline's passed as `--reference-lock-file`.
`flake.nix` and every other file are identical on both sides, so only the
pinned revisions differ.

- **Equal `.drv` paths prove the attribute is unchanged**, and nothing is
  built.
- **When they differ**, the two derivation closures are compared by package
  name. That surfaces version moves, downgrades included, without building.
  The derivation closure includes build tools, so `--key` narrows the list to
  the packages you care about and counts the rest.
- **`--build`** also builds both sides and appends `nix store diff-closures`,
  which gives the runtime closure and size changes.
- **Inputs that can't be rolled back** are marked `*`. Nix honours a reference
  lock only where it still satisfies `flake.nix`. If the same change also
  edited an input's URL (`…/v1` → `…/v2`), or the input is new, both sides
  get the new lock for it. The tool reads back what Nix actually locked
  instead of silently comparing new against new.

## Command line

```sh
nix run github:nix-gizmos/flake-diff-action -- --help
nix run github:nix-gizmos/flake-diff-action                 # working tree vs HEAD
nix run github:nix-gizmos/flake-diff-action -- --base origin/main \
  --key '^(openssl|linux|qemu.*)$' packages.x86_64-linux.default
```

Run it from the flake's directory. It never writes `flake.lock`.

## As a CI action

A composite action: no Node, no container. It needs `nix` (with
`nix-command` and `flakes`, which it enables itself) and `git` on the runner.
It doesn't care how Nix got there: a NixOS or `nixos/nix` image, a
self-hosted runner, or an installer step earlier in the job. Its own tools
(GNU awk, jq, curl) come pinned from this repository's flake.

| Input | Default | |
|---|---|---|
| `attributes` | `packages.<system>.default` | flake attributes, whitespace separated |
| `base` | the PR's base commit, else `HEAD^` | baseline ref; fetched if the clone is shallow |
| `key` | (all) | awk ERE of package names to list |
| `impure` | `false` | evaluate with `--impure` |
| `build` | `false` | also build and `diff-closures` |
| `working-directory` | `.` | where `flake.lock` lives |
| `comment` | `true` | post or update one comment on the PR |
| `token` | `github.token` | token allowed to comment |
| `api-url` | from the runner | e.g. `https://codeberg.org/api/v1` |

Outputs: `changed` (`'true'` if any attribute's derivation changed) and
`report` (path to the plain-text report).

The comment carries the whole report, never a cut-down one. GitHub refuses a
comment over 65536 characters, so a longer report (a nixpkgs bump with
`--all`, say) is split at line boundaries over as many comments as it needs,
numbered "part 2 of 3" and so on. On every push to the PR the action edits
its earlier comments instead of adding new ones, and deletes the parts a
shorter report no longer needs; a hidden marker per part identifies them. A
PR from a fork gets a read-only token on both forges, so the comment is
skipped with a warning, and the report is still in the job log.

> [!WARNING]
> Use `pull_request`, never `pull_request_target`. Evaluating a flake runs
> its code (import-from-derivation and `--impure` included), and
> `pull_request_target` would run the PR's code with a write token.

### Forgejo

Forgejo resolves a bare `owner/repo` against its own default actions host,
so name the action by full URL. `actions/checkout` needs Node; on a Nix image,
check out with plain git:

```yaml
on: pull_request
jobs:
  flake-diff:
    runs-on: docker
    container: { image: nixos/nix }
    steps:
      - name: checkout
        run: |
          git init -q .
          git remote add origin "${{ forge.server_url }}/${{ forge.repository }}"
          git config http.extraHeader "Authorization: token ${{ forge.token }}"
          git fetch -q --depth=1 origin "${{ forge.sha }}"
          git checkout -q FETCH_HEAD
      - uses: https://github.com/nix-gizmos/flake-diff-action@<commit> # v0.1.0
        with:
          key: '^(openssl|linux|qemu.*)$'
```

### GitHub

```yaml
on: pull_request
permissions:
  contents: read
  pull-requests: write
jobs:
  flake-diff:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - uses: DeterminateSystems/nix-installer-action@v23   # or any other way to get Nix
      - uses: nix-gizmos/flake-diff-action@<commit> # v0.1.0
        with:
          attributes: packages.x86_64-linux.default
```

To run it only when the lock changes, add `paths: [flake.lock]` under
`pull_request`.

## Versions

Releases are tagged `vX.Y.Z`; there is no moving `v1`-style tag. Pin the
action by commit with the version as a comment, which Renovate's
`helpers:pinGitHubActionDigestsToSemver` keeps current:

```yaml
- uses: nix-gizmos/flake-diff-action@<commit> # v0.1.0
```

While the major version is 0, inputs, outputs, CLI flags and the report
format may change between minor releases; the release notes call it out.

## Development

```sh
nix develop          # shellcheck, git-cliff, gh, gsemver
make hooks           # pre-commit lints
make lint            # shellcheck on every script
make test            # nix flake check: packages, action.sh, the comment tests
```

`make release-tag` cuts a release from the Conventional Commit history, and
CI publishes it with notes from `cliff.toml`.

## License

MIT
