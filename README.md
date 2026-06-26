# gh-reviews

A read-only **heat check on your work in progress**, across every repo you have checked out locally. `gh reviews` walks your repos, asks GitHub who the ball is on for every open PR, and prints a two-section board: **what needs you**, and **your PRs that are parked on someone else**.

It's the reporting companion to [gh-sweep](https://github.com/sarcasticbird/gh-sweep): where `gh sweep` cleans things up, `gh reviews` just tells you where things stand. Nothing is ever modified.

```
Heat check — 3 need you · 1 waiting on others

▶ Needs you
REPO            PR    STATE             ROLE      LAST-COMMIT       WHO                LATEST            TITLE
kata            #5    REVIEW_REQUIRED   review    2026-06-24T09:00  alice                                feat: add task workspaces
msgvault        #332  CHANGES_REQUESTED re-review 2026-06-20T10:00  bob                2026-06-21T08:00  feat(oauth): embedded client
roborev         #40   APPROVED          merge     2026-06-25T12:00                                       fix: flaky test

▶ Waiting on others
REPO            PR    STATE             ROLE      LAST-COMMIT       WHO                LATEST            TITLE
middleman       #12   REVIEW_REQUIRED   waiting   2026-06-26T01:00  carol,@acme/backend                  chore: bump deps
```

## Install

```sh
gh extension install sarcasticbird/gh-reviews
```

Requires [`gh`](https://cli.github.com) (authenticated) and [`jq`](https://jqlang.github.io/jq/).

## Usage

```sh
gh reviews [view] [flags]
```

### Views

| View | Shows |
|------|-------|
| *(default)* | Heat check: the reviews you owe **plus** all your open PRs, grouped into **Needs you** and **Waiting on others** |
| `todo` | Reviews you owe — your review is requested (you *or a team you're on*), OR you left feedback and the author has pushed since (re-review) |
| `mine` | Your PRs needing your action — changes requested, new feedback to address, or approved and ready to merge |
| `waiting` | Your PRs parked on others — pushed and waiting on reviewers |
| `all` | Team-wide: any open PR (any author) stalled waiting on its author |

### Roles

The `ROLE` column says *why* a PR is on your board:

| Role | Bucket | Meaning |
|------|--------|---------|
| `review` | Needs you | Someone requested your review |
| `re-review` | Needs you | You reviewed; the author has pushed since (even if they never re-requested you) |
| `address` | Needs you | Your PR has changes requested or new feedback |
| `approved` | Needs you | Your PR is approved — your move (CI/mergeability not checked) |
| `nudge` | Needs you | Your PR has no reviewers and no activity — needs a nudge |
| `waiting` | Waiting on others | Your PR is waiting on reviewers |
| `stalled` | Waiting on others | Someone else's PR is waiting on its author |

### Scope

Like `gh sweep`, scope follows your **current directory**. `gh reviews` walks
from wherever you are: depth `0` is just the current repo, and `--depth N`
cascades `N` levels into subprojects. `cd` into a project to scope the heat
check to that project and its subprojects — there's no global "all my repos"
scan unless you run it from a directory that contains all of them.

```sh
cd ~/Projects/voicebrain
gh reviews            # just this repo
gh reviews --depth 1  # this repo + its immediate subprojects
gh reviews --depth 2  # deeper cascade
```

### Flags

| Flag | Description |
|------|-------------|
| `--depth N` | How many directory levels below the current folder to walk (default: 0, current repo) |
| `--json` | Emit matched PRs as a JSON array instead of a table |
| `--version` | Print version |
| `--help` | Show help |

### Examples

```sh
gh reviews                  # heat check of the current repo
gh reviews --depth 1        # heat check across every repo one level down
gh reviews todo             # just the reviews you owe
gh reviews mine --depth 1   # your PRs needing action, across repos
gh reviews waiting          # your PRs parked on reviewers
gh reviews all --depth 1    # every PR stalled on its author
gh reviews todo --json | jq '.[].number'   # machine-readable
```

## How it works

For every open PR, `gh reviews` looks at all reviews, issue comments, and review-thread comments, keeps only those from a real person (not a bot) who isn't the author and who acted *after* the author's last commit, and uses GitHub's `reviewDecision` for the headline state. It then classifies the PR by who the ball is on (the roles above).

- **Re-review** is the case the `gh search prs --review-requested=@me` shortcut misses: you reviewed, the author pushed new commits, and *forgot to re-request you*. `gh reviews` catches it by comparing your last review's timestamp to the author's last commit.
- **Team review requests** count too — if your review is requested via a team you belong to, not just you directly. (Needs the token's `read:org` scope; without it, only direct requests are matched.)
- **Repo identity** is resolved by parsing each working tree's remotes locally (no API call) — preferring `upstream`, then `origin` — so a fork reports on the canonical repo where your PRs and review requests actually live. Worktrees and submodules are discovered, and multiple worktrees of one repo are queried once.
- **All open PRs are fetched** (paginated, no cap), and repos are queried concurrently. Each `--depth` scan costs GitHub API budget proportional to the number of repos walked.
- **Per-PR activity is sampled from the most recent 50** reviews, comments, and review threads — ample for normal PRs, since the signals we care about are recent. A single PR with more activity than that may miss its oldest signals; merge-readiness (CI, conflicts, branch protection) is not evaluated, so `approved` reflects the review decision only.
- **Failures are never hidden.** If a repo can't be queried (rate limit, network), a warning goes to stderr and the exit code is non-zero — even in `--json` mode — so automation can't mistake an error for "nothing to do".

Colors: `STATE` is green (approved), red (changes requested), yellow (review required), or dim — suppressed when output isn't a terminal or `NO_COLOR` is set.

## Tests

The classification logic (the core of the tool) has a committed suite that
extracts the live jq program from the script and asserts every role/bucket
transition against representative PR payloads:

```sh
./test/classify_test.sh
```

## License

[MIT](LICENSE)
