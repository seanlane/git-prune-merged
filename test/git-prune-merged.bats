#!/usr/bin/env bats

setup() {
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
  export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
  export GH_MERGED_FILE="$BATS_TEST_TMPDIR/merged"
  export GH_CALL_LOG="$BATS_TEST_TMPDIR/gh-calls"
  export PATH="$BATS_TEST_DIRNAME/stubs:$PATH"
  SCRIPT="$BATS_TEST_DIRNAME/../git-prune-merged"
  ORIGIN="$BATS_TEST_TMPDIR/origin.git"
  : > "$GH_MERGED_FILE"

  git init -q --bare -b staging "$ORIGIN"
  git init -q -b staging "$BATS_TEST_TMPDIR/work"
  cd "$BATS_TEST_TMPDIR/work" || return 1
  git commit -q --allow-empty -m base
  git remote add origin "$ORIGIN"
  git push -q origin staging
}

# new_branch <name> [<start>]: create <name> from <start> with one new commit.
new_branch() {
  git branch "$1" "${2:-staging}"
  git commit-tree -p "$1" -m "$1" "$1^{tree}" | xargs git update-ref "refs/heads/$1"
}

# add_commit <branch>: add one commit to <branch>; print the new commit id.
add_commit() {
  local commit
  commit=$(git commit-tree -p "$1" -m "more on $1" "$1^{tree}")
  git update-ref "refs/heads/$1" "$commit"
  echo "$commit"
}

# merged <branch> <oid> <pr-number>: record a merged PR for the gh stub.
merged() {
  echo "$1 $2 $3" >> "$GH_MERGED_FILE"
}

branch_exists() {
  git rev-parse --verify --quiet "refs/heads/$1" > /dev/null
}

# Bash ignores errexit for `! cmd`, so `! branch_exists x` would never fail a test.
branch_gone() {
  if branch_exists "$1"; then
    echo "branch $1 still exists"
    return 1
  fi
}

@test "deletes a branch whose tip equals the merged PR head" {
  new_branch exact
  merged exact "$(git rev-parse exact)" 1

  run "$SCRIPT" --live
  [ "$status" -eq 0 ]
  [[ "$output" == *"Deleted branch exact"* ]]
  branch_gone exact
}

@test "deletes a branch whose tip is behind the merged PR head" {
  new_branch behind
  local_tip=$(git rev-parse behind)
  head=$(add_commit behind)
  git update-ref refs/heads/behind "$local_tip"
  merged behind "$head" 2

  run "$SCRIPT" --live
  [ "$status" -eq 0 ]
  branch_gone behind
}

@test "skips a branch with commits that are not in the merged PR head" {
  new_branch extra
  merged extra "$(git rev-parse extra)" 3
  add_commit extra > /dev/null

  run "$SCRIPT" --live
  [ "$status" -eq 0 ]
  [[ "$output" == *"Skipped (local tip has commits not in the merged PR head"* ]]
  [[ "$output" == *"extra (local "*" not contained in PR #3 head "* ]]
  branch_exists extra
}

@test "fetches a merged PR head that is missing locally, then deletes" {
  new_branch gone
  git push -q origin gone
  git clone -q "$ORIGIN" "$BATS_TEST_TMPDIR/other"
  head=$(git -C "$BATS_TEST_TMPDIR/other" commit-tree -p origin/gone -m remote-only "origin/gone^{tree}")
  git -C "$BATS_TEST_TMPDIR/other" push -q origin "$head:refs/pull/4/head"
  if git cat-file -e "$head^{commit}" 2> /dev/null; then
    echo "PR head is already local; the fetch path is not exercised"
    return 1
  fi
  merged gone "$head" 4

  run "$SCRIPT" --live
  [ "$status" -eq 0 ]
  git cat-file -e "$head^{commit}"
  branch_gone gone
}

@test "skips a branch when the missing merged PR head cannot be fetched" {
  new_branch unfetchable
  merged unfetchable 1111111111111111111111111111111111111111 5

  run "$SCRIPT" --live
  [ "$status" -eq 0 ]
  [[ "$output" == *"unfetchable (local "*" not contained in PR #5 head 1111111"* ]]
  branch_exists unfetchable
}

@test "skips a branch checked out in a worktree" {
  new_branch busy
  merged busy "$(git rev-parse busy)" 6
  git worktree add -q "$BATS_TEST_TMPDIR/wt" busy

  run "$SCRIPT" --live
  [ "$status" -eq 0 ]
  [[ "$output" == *"Skipped (in use by a worktree):"*"busy"* ]]
  branch_exists busy
}

@test "never touches protected branches" {
  new_branch develop
  merged develop "$(git rev-parse develop)" 7

  run "$SCRIPT" --live
  [ "$status" -eq 0 ]
  [[ "$output" != *develop* ]]
  branch_exists develop
}

@test "ignores branches without a merged PR" {
  new_branch unmerged

  run "$SCRIPT" --live
  [ "$status" -eq 0 ]
  [ "$output" = "No merged local branches to prune." ]
  branch_exists unmerged
}

@test "dry run lists branches but deletes nothing" {
  new_branch exact
  merged exact "$(git rev-parse exact)" 8

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Dry-run — would delete:"*"exact"* ]]
  [[ "$output" == *"Re-run with --live"* ]]
  branch_exists exact
}

@test "aborts and deletes nothing when the GraphQL query fails" {
  new_branch exact
  merged exact "$(git rev-parse exact)" 9
  export GH_FAIL_GRAPHQL=1

  run "$SCRIPT" --live
  [ "$status" -ne 0 ]
  branch_exists exact
}

@test "looks up branches past the first query chunk" {
  base=$(git rev-parse staging)
  for i in $(seq 1 120); do
    git branch "many-$i" staging
    merged "many-$i" "$base" "$((100 + i))"
  done

  run "$SCRIPT" --live
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$GH_CALL_LOG")" -eq 3 ]
  [ "$(git branch --list 'many-*' | wc -l)" -eq 0 ]
}

@test "reports a failed delete and still prints the skipped sections" {
  new_branch locked
  merged locked "$(git rev-parse locked)" 11
  new_branch ok
  merged ok "$(git rev-parse ok)" 12
  new_branch extra
  merged extra "$(git rev-parse extra)" 13
  add_commit extra > /dev/null
  touch "$(git rev-parse --git-dir)/refs/heads/locked.lock"

  run "$SCRIPT" --live
  [ "$status" -eq 0 ]
  [[ "$output" == *"warning: some branches could not be deleted"* ]]
  [[ "$output" == *"Skipped (local tip has commits not in the merged PR head"* ]]
  branch_exists locked
  branch_gone ok
}
