# git-prune-merged

Delete local branches whose GitHub PRs have been merged. See the header of
`git-prune-merged` for the safety rules.

## Install

```sh
ln -sf ~/Code/Other/git-prune-merged/git-prune-merged ~/.local/bin/git-prune-merged
```

Requires bash 4+, `git`, and an authenticated `gh`.

## Usage

```sh
git prune-merged          # dry run
git prune-merged --live   # delete
```

## Test

```sh
brew install bats-core
bats test/
shellcheck git-prune-merged test/stubs/gh
shellcheck -s bash test/git-prune-merged.bats
```

Tests build throwaway git repos and use a fake `gh` (`test/stubs/gh`), so they
need no network access or GitHub credentials.
