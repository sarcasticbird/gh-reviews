# gh-reviews — design

**Date:** 2026-06-26
**Status:** built

## Purpose

A read-only **heat check on your work in progress** across local repos. Where
`gh-sweep` *cleans up* (destructive), `gh-reviews` *reports* (pure read). It
answers, in one board, who the ball is on for every open PR:

- **What needs me?** — reviews I owe, and my PRs that need my action.
- **What's parked on someone else?** — my PRs waiting on reviewers.

It replaces and subsumes the `gh alias` `reviews`
(`search prs --review-requested=@me --state=open`), which is removed.

## Form

Single bash file `gh-reviews` (bash 3.2 compatible), mirroring gh-sweep:
`usage()`, `discover_repos()` (walk cwd by `--depth`, matching `.git`
directories *and* files so worktrees/submodules are included), `--version`/
`--help`. Its own repo at `~/Projects/gh-reviews`, installed as `gh reviews`.
No mutations, no confirmations.

**Scope follows the current directory**, exactly like `gh sweep`: depth 0 is the
current repo; `--depth N` cascades N levels into subprojects. There is no global
"all repos" scan unless invoked from a directory that contains them all.

Repo identity (`owner/repo`) is resolved by parsing remotes locally — prefer
`upstream`, then `origin` — not via `gh repo view`. This avoids an API call per
repo (and the rate-limit false-skips it caused) and is fork-aware: it reports on
the canonical repo, not your fork. Resolved repos are de-duplicated so multiple
worktrees of one repo are queried once.

## Views

| View | Selection |
|------|-----------|
| *(default)* | reviews owed (`review`/`re-review`) ∪ all my open non-draft PRs |
| `todo` | `review` or `re-review` |
| `mine` | `address` or `merge` |
| `waiting` | `waiting` |
| `all` | any PR (any author) with non-author activity after the author's last commit |

`--depth N`, `--json`, `--version`, `--help` apply to every view.

## Roles & buckets

Each kept PR is classified into one role, which determines its heat-check
section (bucket):

| Role | Bucket | Condition |
|------|--------|-----------|
| `review` | you | my review is requested (direct or via a team I'm on), pending |
| `re-review` | you | I last reviewed (any verdict, incl. a stale approval) and the author has committed since |
| `address` | you | my PR: changes requested, or new *actionable* feedback after my last push |
| `approved` | you | my PR: approved (review decision only; CI/mergeability not checked) |
| `nudge` | you | my PR: no reviewers requested and no activity — needs a nudge |
| `waiting` | others | my PR: pending reviewers, nothing actionable yet |
| `stalled` | others | not-mine PR: *actionable* non-author activity after the author's last commit |

"Actionable" = a comment or a changes-requested/commented review — something the
author must respond to. A bare approval is **not** actionable, so an approval
landing after the last commit never makes a PR look `stalled`.

## Data per PR (GraphQL, paginated)

- `pullRequests(first:50, after:$cursor)` with `pageInfo{hasNextPage endCursor}`
  — **all** open PRs are fetched, looping pages until exhausted.
- `number`, `title`, `isDraft`, `reviewDecision`, `author.login`
- `commits(last:1)` → last `committedDate`
- `reviews(last:50)`, `comments(last:50)`, `reviewThreads(last:50){isResolved,
  comments(last:5)}` — each with `author.login`, `author.__typename`, timestamp,
  review `state`. Comments in **resolved** threads are excluded from actionable.
  Bounded recent windows keep node cost down; post-commit activity is recent, so
  the windows don't lose signal. (`reviewThreads` uses `last` so the *most recent*
  threads are sampled, not the oldest.)
- `reviewRequests(first:50).requestedReviewer` → `... on User{login}`,
  `... on Team{name combinedSlug}`

## Computed fields (jq, given `$me`, `$view`, `$myteams`)

- `after` = per-reviewer latest review ∪ comments ∪ (comments in *unresolved*
  threads) where `__typename=="User"`, `login != author`, `ts > lastCommit`. Each
  item carries `actionable` (comments → true; reviews → true only if the
  reviewer's *latest* post-commit verdict is CHANGES_REQUESTED/COMMENTED, so a
  later approval that supersedes an earlier objection doesn't count).
  `address`/`stalled` use only post-commit actionable items, so a prior
  changes-requested review you've already pushed fixes for no longer fires.
- `actionable` / `hasActionable` = the subset/any of `after` that the author must
  respond to — drives `address` and `stalled`, so bare approvals never trigger them.
- `awaitingMe` = my login in pending user requests, OR a pending team request
  whose `combinedSlug` is in `$myteams` (and author ≠ me)
- `needsReReview` = my latest submitted review is CHANGES_REQUESTED/COMMENTED/
  APPROVED and `lastCommit > myLastReview.submittedAt` (author ≠ me, not draft)
- `state` = `DRAFT` if draft; else `reviewDecision`; else `NONE`
- `role`, `bucket`, `keep` per the tables above (non-mine PRs with no actionable
  activity get role `none` and are dropped)
- `who` = author (review/re-review), pending reviewers (waiting), or the
  actionable actors (address/stalled)

`$myteams` is fetched once via `gh api --paginate user/teams` (REST), as an array
of `org/slug`. Needs the token's `read:org` scope; degrades to direct-only.

## Execution

Repos are queried **concurrently** with a bounded pool (cap 6, batch-waited for
bash-3.2 portability), writing per-repo stdout/stderr to temp files and
concatenating in order. The cap stays modest to avoid GitHub's secondary rate
limits. A full `~/Projects` (~60 repos) `--depth 1` scan runs in ~17s vs ~67s
sequential.

## Output

Table grouped into `▶ Needs you` and `▶ Waiting on others`, each with its own
column header; default view prints a `Heat check — N need you · M waiting on
others` summary line. `STATE` colorized (green/red/yellow/dim) unless non-TTY or
`NO_COLOR`. `--json` emits an array of the computed objects (with `role`/`bucket`)
and skips the table.

## Error handling

- Missing `gh`/`jq` → error, exit 1.
- Working tree with no github.com `upstream`/`origin` → skip with a note. If
  *every* discovered repo is skipped, error and exit non-zero rather than print a
  false "all clear".
- GraphQL string variables (`owner`/`repo`) are passed with `-f` (raw) so repo
  names like `2026`/`true`/`null` aren't coerced to non-string types; only the
  pagination `cursor` uses typed `-F …=null`.
- Per-repo query failure (errors envelope incl. RATE_LIMITED, or empty) → warn to
  stderr (**always**, even in `--json`) and mark the run failed → non-zero exit.
- Empty results **with** a failure never prints "all clear" — it says results may
  be incomplete and exits non-zero.

## Known limitations

- Team review-request matching needs `read:org`; without it only direct requests
  are matched.
- A repo whose canonical remote isn't named `upstream` or `origin` is skipped.
- Each `--depth` scan costs API budget proportional to the repo count.
- Per-PR activity is sampled from the most recent 50 reviews/comments/threads.
  A single PR with more activity than that may miss its oldest signals — an
  intentional cost/coverage tradeoff, since the signals we need are recent.
  Full per-PR nested pagination was rejected as over-engineering for this tool.
- Merge-readiness (CI, conflicts, branch protection) is not evaluated; `approved`
  reflects the review decision only. `mergeStateStatus` was rejected because it
  is async/UNKNOWN right after pushes and pulls CI evaluation out of scope.

## Testing

Synthetic jq unit tests cover every role/bucket transition, team matching, and
re-review edges (new commits after a non-approval review fire; stale approvals
and already-current reviews don't). Live: the `all` view classifies real PRs into
sections correctly; parallel scan timing confirmed.
