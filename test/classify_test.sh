#!/usr/bin/env bash
# Tests for the gh-reviews PR classification logic (the JQ_PROGRAM in ../gh-reviews).
# Extracts the live program from the script so tests can't drift from the code,
# feeds representative single-PR GraphQL payloads through it, and asserts the
# resulting role/bucket (or that the PR is filtered out).
#
# Run: ./test/classify_test.sh   (needs jq)

set -euo pipefail

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/gh-reviews"

# Pull JQ_PROGRAM='...' out of the script verbatim.
PROG="$(sed -n "/^JQ_PROGRAM='/,/^'/p" "$SCRIPT" | sed "1s/^JQ_PROGRAM='//" | sed '$ s/^.$//')"

pass=0
fail=0

# Build a one-PR repository response.
#   payload <number> <author> <isDraft> <reviewDecision-json> <lastCommit> \
#           <reviews-json> <reviewRequests-json> [comments-json] [reviewThreads-json]
payload() {
  local comments="${8:-[]}"
  local threads="${9:-[]}"
  cat <<EOF
{"data":{"repository":{"pullRequests":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
 {"number":$1,"title":"t","isDraft":$3,"reviewDecision":$4,"author":{"login":"$2"},
  "commits":{"nodes":[{"commit":{"committedDate":"$5"}}]},
  "reviews":{"nodes":$6},
  "comments":{"nodes":$comments},
  "reviewThreads":{"nodes":$threads},
  "reviewRequests":{"nodes":$7}}]}}}}
EOF
}

# classify <me> <view> <myteams-json>  (payload on stdin) -> "role bucket" or "FILTERED"
classify() {
  local out
  out="$(jq -r --arg me "$1" --arg view "$2" --arg repo demo --argjson myteams "$3" "$PROG" \
         | jq -r '"\(.role) \(.bucket)"' 2>/dev/null)" || true
  [[ -z "$out" ]] && out="FILTERED"
  printf '%s' "$out"
}

check() { # <description> <expected> <actual>
  if [[ "$2" == "$3" ]]; then
    pass=$((pass + 1))
    printf '  ok   %s\n' "$1"
  else
    fail=$((fail + 1))
    printf '  FAIL %s — expected [%s], got [%s]\n' "$1" "$2" "$3"
  fi
}

REVIEW_ME='[{"requestedReviewer":{"__typename":"User","login":"me"}}]'
REVIEW_TEAM='[{"requestedReviewer":{"__typename":"Team","name":"backend","combinedSlug":"acme/backend"}}]'
REVIEW_ALICE='[{"requestedReviewer":{"__typename":"User","login":"alice"}}]'
MY_TEAMS='["acme/backend"]'
EARLY=2026-06-18T09:00:00Z
MID=2026-06-19T10:00:00Z
LATE=2026-06-20T10:00:00Z
BOB_CR_THEN_APPROVE='[{"author":{"login":"bob","__typename":"User"},"submittedAt":"'"$MID"'","state":"CHANGES_REQUESTED"},{"author":{"login":"bob","__typename":"User"},"submittedAt":"'"$LATE"'","state":"APPROVED"}]'
BOB_CR_ALICE_APPROVE='[{"author":{"login":"bob","__typename":"User"},"submittedAt":"'"$MID"'","state":"CHANGES_REQUESTED"},{"author":{"login":"alice","__typename":"User"},"submittedAt":"'"$LATE"'","state":"APPROVED"}]'
COMMENTED_EARLY='[{"author":{"login":"me","__typename":"User"},"submittedAt":"'"$EARLY"'","state":"COMMENTED"}]'
APPROVED_EARLY='[{"author":{"login":"me","__typename":"User"},"submittedAt":"'"$EARLY"'","state":"APPROVED"}]'
BOB_COMMENT_LATE='[{"author":{"login":"bob","__typename":"User"},"createdAt":"'"$LATE"'"}]'
BOB_APPROVE_LATE='[{"author":{"login":"bob","__typename":"User"},"submittedAt":"'"$LATE"'","state":"APPROVED"}]'
BOB_CHANGES_LATE='[{"author":{"login":"bob","__typename":"User"},"submittedAt":"'"$LATE"'","state":"CHANGES_REQUESTED"}]'
BOB_CHANGES_EARLY='[{"author":{"login":"bob","__typename":"User"},"submittedAt":"'"$EARLY"'","state":"CHANGES_REQUESTED"}]'
BOT_COMMENT_LATE='[{"author":{"login":"dependabot","__typename":"Bot"},"createdAt":"'"$LATE"'"}]'
UNRESOLVED_THREAD_LATE='[{"isResolved":false,"comments":{"nodes":[{"author":{"login":"bob","__typename":"User"},"createdAt":"'"$LATE"'"}]}}]'
RESOLVED_THREAD_LATE='[{"isResolved":true,"comments":{"nodes":[{"author":{"login":"bob","__typename":"User"},"createdAt":"'"$LATE"'"}]}}]'

echo "classification tests:"

check "direct review request -> review/you" "review you" \
  "$(payload 1 someone false null "$LATE" '[]' "$REVIEW_ME" | classify me default '[]')"

check "team review request, I'm a member -> review/you" "review you" \
  "$(payload 2 someone false null "$LATE" '[]' "$REVIEW_TEAM" | classify me default "$MY_TEAMS")"

check "team review request, not my team -> filtered (default)" "FILTERED" \
  "$(payload 3 someone false null "$LATE" '[]' "$REVIEW_TEAM" | classify me default '[]')"

check "I commented, author pushed since -> re-review/you" "re-review you" \
  "$(payload 4 someone false null "$LATE" "$COMMENTED_EARLY" '[]' | classify me default '[]')"

check "I commented, no new commit since -> filtered" "FILTERED" \
  "$(payload 5 someone false null "$EARLY" "$COMMENTED_EARLY" '[]' | classify me default '[]')"

check "I approved, author pushed since -> re-review/you (stale approval)" "re-review you" \
  "$(payload 6 someone false null "$LATE" "$APPROVED_EARLY" '[]' | classify me default '[]')"

check "my PR approved -> approved/you" "approved you" \
  "$(payload 7 me false '"APPROVED"' "$LATE" '[]' '[]' | classify me default '[]')"

check "my PR approved but newer comment -> address/you (feedback wins over approval)" "address you" \
  "$(payload 17 me false '"APPROVED"' "$EARLY" '[]' '[]' "$BOB_COMMENT_LATE" | classify me default '[]')"

check "my PR, changes requested after my last commit -> address/you" "address you" \
  "$(payload 8 me false '"CHANGES_REQUESTED"' "$EARLY" "$BOB_CHANGES_LATE" '[]' | classify me default '[]')"

check "my PR, changes requested but I pushed fixes since -> nudge/you (not stuck in address)" "nudge you" \
  "$(payload 81 me false '"CHANGES_REQUESTED"' "$LATE" "$BOB_CHANGES_EARLY" '[]' | classify me default '[]')"

check "my PR, unresolved thread comment after commit -> address/you" "address you" \
  "$(payload 82 me false null "$EARLY" '[]' '[]' '[]' "$UNRESOLVED_THREAD_LATE" | classify me default '[]')"

check "my PR, resolved thread comment after commit -> nudge/you (resolved ignored)" "nudge you" \
  "$(payload 83 me false null "$EARLY" '[]' '[]' '[]' "$RESOLVED_THREAD_LATE" | classify me default '[]')"

check "my PR, reviewer commented after push -> address/you" "address you" \
  "$(payload 9 me false null "$EARLY" '[]' '[]' "$BOB_COMMENT_LATE" | classify me default '[]')"

check "my PR, reviewers pending, no feedback -> waiting/others" "waiting others" \
  "$(payload 10 me false '"REVIEW_REQUIRED"' "$LATE" '[]' "$REVIEW_ALICE" | classify me default '[]')"

check "my PR, pending reviewer but reviewDecision null -> STATE=REVIEW_REQUIRED (not NONE)" "REVIEW_REQUIRED" \
  "$(payload 101 me false null "$LATE" '[]' "$REVIEW_ALICE" \
     | jq -r --arg me me --arg view default --arg repo demo --argjson myteams '[]' "$PROG" | jq -r '.state')"

check "my PR, no reviewers, no activity -> nudge/you" "nudge you" \
  "$(payload 11 me false null "$LATE" '[]' '[]' | classify me default '[]')"

check "my PR, team request to my team -> waiting/others (own PR, not review)" "waiting others" \
  "$(payload 12 me false '"REVIEW_REQUIRED"' "$LATE" '[]' "$REVIEW_TEAM" | classify me default "$MY_TEAMS")"

check "someone else's PR, human commented after commit, all view -> stalled/others" "stalled others" \
  "$(payload 13 someone false null "$EARLY" '[]' '[]' "$BOB_COMMENT_LATE" | classify me all '[]')"

check "someone else's PR, only an approval after commit, all view -> filtered (approval not actionable)" "FILTERED" \
  "$(payload 16 someone false '"APPROVED"' "$EARLY" "$BOB_APPROVE_LATE" '[]' | classify me all '[]')"

check "reviewer requested changes then approved, all view -> filtered (latest verdict supersedes)" "FILTERED" \
  "$(payload 161 someone false '"APPROVED"' "$EARLY" "$BOB_CR_THEN_APPROVE" '[]' | classify me all '[]')"

check "one reviewer still wants changes, another approved -> stalled/others" "stalled others" \
  "$(payload 162 someone false null "$EARLY" "$BOB_CR_ALICE_APPROVE" '[]' | classify me all '[]')"

check "bot comment after commit -> filtered (bots ignored)" "FILTERED" \
  "$(payload 14 someone false null "$EARLY" '[]' '[]' "$BOT_COMMENT_LATE" | classify me all '[]')"

check "my draft PR -> filtered (default)" "FILTERED" \
  "$(payload 15 me true null "$LATE" '[]' '[]' | classify me default '[]')"

echo
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
