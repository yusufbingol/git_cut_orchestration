#!/usr/bin/env bash
# Shared logic for the release/hotfix cut process.
# Usage (via env):
#   MODE=release VERSION=23.0.0        [DRY_RUN=true] ./cut.sh
#   MODE=hotfix  BASE_VERSION=22.0.0   [DRY_RUN=true] ./cut.sh
# Required env: OWNER, REPOS (space-separated), GH_TOKEN
# If GITHUB_STEP_SUMMARY is set, a summary table is written there.
set -euo pipefail

: "${OWNER:?OWNER is required}"
: "${REPOS:?REPOS is required}"
: "${MODE:?MODE is required (release|hotfix)}"
DRY_RUN="${DRY_RUN:-false}"
# Stale-base consent: allows a hotfix from a stale base when a newer cut
# exists (the workflow passes true after the environment approval).
ALLOW_STALE_BASE="${ALLOW_STALE_BASE:-false}"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"

# ---------- Helpers ----------

# SHA of the object a ref points to; empty if the ref does not exist.
# For annotated tags this is the SHA of the TAG OBJECT, not the commit.
# Note: on HTTP errors gh api prints the error body to stdout — therefore
# the output is only used when the exit code is 0.
ref_sha() { # repo, ref (heads/... | tags/...)
  local out
  if out=$(gh api "repos/$OWNER/$1/git/ref/$2" --jq .object.sha 2>/dev/null); then
    echo "$out"
  fi
}

# Resolves a tag/branch name to its COMMIT SHA (dereferences annotated tags); empty if missing.
commit_sha_of() { # repo, ref-name (e.g. v22.0.0-FINAL)
  local out
  if out=$(gh api "repos/$OWNER/$1/commits/$2" --jq .sha 2>/dev/null); then
    echo "$out"
  fi
}

create_branch() { # repo, branch, sha
  gh api -X POST "repos/$OWNER/$1/git/refs" -f ref="refs/heads/$2" -f sha="$3" --jq .ref
}

# Annotated tag: tag object first, then the ref (same type GitHub Desktop produces).
create_annotated_tag() { # repo, tag, sha, message
  local tag_obj
  tag_obj=$(gh api -X POST "repos/$OWNER/$1/git/tags" \
    -f tag="$2" -f message="$4" -f object="$3" -f type=commit --jq .sha)
  gh api -X POST "repos/$OWNER/$1/git/refs" -f ref="refs/tags/$2" -f sha="$tag_obj" --jq .ref
}

# All tag names in the repo (pagination included).
list_tags() { # repo
  gh api --paginate "repos/$OWNER/$1/git/matching-refs/tags/" --jq '.[].ref' | sed 's|refs/tags/||'
}

fail_with_errors() { # title
  echo "## ❌ $1 — Validation Failed" >> "$SUMMARY"
  local e
  for e in "${ERRORS[@]}"; do
    echo "- $e" >> "$SUMMARY"
    echo "::error::$e"
  done
  echo "No writes were made to any repository."
  exit 1
}

# ---------- Phase 0: format validation + version calculation ----------

if [[ "$MODE" == "release" ]]; then
  : "${VERSION:?VERSION is required (release mode)}"
  # Leading zeros are not accepted (023 → octal/name-pollution risk).
  if ! [[ "$VERSION" =~ ^(0|[1-9][0-9]*)\.0\.0$ ]]; then
    echo "::error::Version must be in 'X.0.0' format, without leading zeros (given: $VERSION). Minor/patch cuts are out of scope for this workflow."
    exit 1
  fi
  NEW_MAJOR="${BASH_REMATCH[1]}"
  NEW_VERSION="$VERSION"
  SOURCE_REF_DESC="main"
  TITLE="Cut Release v$NEW_VERSION"
elif [[ "$MODE" == "hotfix" ]]; then
  : "${BASE_VERSION:?BASE_VERSION is required (hotfix mode)}"
  # Leading zeros are not accepted (023 → octal/name-pollution risk).
  if ! [[ "$BASE_VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
    echo "::error::Base version must be in 'X.Y.Z' format, without leading zeros (given: $BASE_VERSION)"
    exit 1
  fi
  MAJOR="${BASH_REMATCH[1]}"; MINOR="${BASH_REMATCH[2]}"; PATCH="${BASH_REMATCH[3]}"
  NEW_VERSION="$MAJOR.$MINOR.$((PATCH + 1))"
  SOURCE_REF_DESC="v$BASE_VERSION"
  TITLE="Cut Hotfix v$NEW_VERSION (base: v$BASE_VERSION)"
else
  echo "::error::Invalid MODE: $MODE (release|hotfix)"
  exit 1
fi

ERRORS=()
read -r -a REPO_LIST <<< "$REPOS"
SRC_SHA=(); SKIP_BRANCH=(); SKIP_TAG=()

# ---------- Phase 0.5 (hotfix): stale-base detection ----------
# A "stale base" occurs in two cases:
#   a) A newer cut (RC or FINAL) exists in the base's OWN series
#      (e.g. base 23.0.1 while v23.0.2 is already cut) — the chain must
#      continue from the newest one.
#   b) A released (FINAL) version exists in a higher series
#      (e.g. base 21.0.1 while v22.0.2 is live).
# Note: an RC-only higher series (new major cut but not yet released) does
# NOT count as a stale base — hotfixing the previous series is the normal flow.
# Default: reject. With ALLOW_STALE_BASE=true (passed by the workflow after
# the environment approval) it proceeds; the new version stays in the base's
# own series and becomes highest-cut patch+1 to avoid collisions.
STALE_BASE=false
APPROVAL_MESSAGE=""
if [[ "$MODE" == "hotfix" ]]; then
  ALL_FINALS=""; SERIES_CUTS=""
  for repo in "${REPO_LIST[@]}"; do
    tags=$(list_tags "$repo" || true)
    # Note: only well-formed numbers match (tags with leading zeros, e.g.
    # "08", are ignored — they would cause octal errors in bash arithmetic).
    ALL_FINALS+=$(printf '%s' "$tags" | sed -nE 's/^v((0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*))-FINAL$/\1/p')$'\n'
    SERIES_CUTS+=$(printf '%s' "$tags" | sed -nE "s/^v$MAJOR\.$MINOR\.(0|[1-9][0-9]*)-(RC|FINAL)\$/\1/p")$'\n'
  done
  # Highest cut patch (RC or FINAL) in the base's series.
  HIGHEST_CUT_PATCH=$(printf '%s' "$SERIES_CUTS" | grep -v '^$' | sort -n | tail -1 || true)
  HIGHEST_CUT_PATCH="${HIGHEST_CUT_PATCH:-$PATCH}"
  (( HIGHEST_CUT_PATCH < PATCH )) && HIGHEST_CUT_PATCH="$PATCH"
  # Reference version: max(global highest FINAL, highest cut within the series).
  REFERENCE=$(printf '%s\n%s\n' "$ALL_FINALS" "$MAJOR.$MINOR.$HIGHEST_CUT_PATCH" \
    | grep -v '^$' | sort -u -t. -k1,1n -k2,2n -k3,3n | tail -1 || true)

  if [[ -n "$REFERENCE" && "$REFERENCE" != "$BASE_VERSION" ]] \
     && [[ "$(printf '%s\n%s\n' "$REFERENCE" "$BASE_VERSION" | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)" == "$REFERENCE" ]]; then
    # Reference status: released ("live") if it has a FINAL tag,
    # otherwise cut but not yet released (RC only).
    if printf '%s' "$ALL_FINALS" | grep -qx "$REFERENCE"; then
      REF_DESC="v$REFERENCE is live"
    else
      REF_DESC="v$REFERENCE is cut (RC, not yet released)"
    fi
    if [[ "$ALLOW_STALE_BASE" != "true" ]]; then
      echo "::error::While $REF_DESC, a hotfix from stale base v$BASE_VERSION requires approval — run it via the workflow (environment approval) or, locally and deliberately, set ALLOW_STALE_BASE=true."
      exit 1
    fi
    STALE_BASE=true
    NEW_VERSION="$MAJOR.$MINOR.$((HIGHEST_CUT_PATCH + 1))"
    TITLE="Cut Hotfix v$NEW_VERSION (base: v$BASE_VERSION — STALE BASE)"
    APPROVAL_MESSAGE="$REF_DESC; v$NEW_VERSION will be cut from v$BASE_VERSION. Do you approve?"
    echo "⚠️  Stale base detected: $APPROVAL_MESSAGE"
  fi
  echo "Base: v$BASE_VERSION → New hotfix version: v$NEW_VERSION"
  # Outputs for the workflow's approval job to decide on.
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    {
      echo "needs_approval=$STALE_BASE"
      echo "new_version=$NEW_VERSION"
      echo "approval_message=$APPROVAL_MESSAGE"
    } >> "$GITHUB_OUTPUT"
  fi
fi

NEW_BRANCH="v$NEW_VERSION"
RC_TAG="v$NEW_VERSION-RC"

# ---------- Phase 1: validation across all repos (no writes) ----------

for i in "${!REPO_LIST[@]}"; do
  repo=${REPO_LIST[$i]}
  echo "--- Validating $OWNER/$repo ---"
  SRC_SHA[i]=""; SKIP_BRANCH[i]=""; SKIP_TAG[i]=""

  if [[ "$MODE" == "release" ]]; then
    # Source: main HEAD
    sha=$(ref_sha "$repo" "heads/main")
    if [[ -z "$sha" ]]; then
      ERRORS+=("$repo: 'main' branch not found")
      continue
    fi

    # Major guard (typo protection): only the highest RC major itself
    # (idempotent re-run) or +1 (new cut) is accepted. If no RC exists,
    # the first cut is unrestricted. (Malformed leading-zero tags are
    # ignored — octal risk.)
    highest_major=$(list_tags "$repo" \
      | sed -nE 's/^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)-RC$/\1/p' \
      | sort -n | tail -1 || true)
    if [[ -n "$highest_major" ]]; then
      if [[ "$NEW_MAJOR" -gt $((highest_major + 1)) ]]; then
        ERRORS+=("$repo: given major v$NEW_MAJOR, but the highest existing RC major is v$highest_major — at most v$((highest_major + 1)).0.0 can be cut (typo protection)")
      elif [[ "$NEW_MAJOR" -lt "$highest_major" ]]; then
        ERRORS+=("$repo: given major v$NEW_MAJOR is lower than the highest existing RC major (v$highest_major) — a backdated version cannot be cut from the current main. Use v$((highest_major + 1)).0.0 for a new cut (typo protection)")
      fi
    fi
  else
    # Source: base release branch HEAD
    sha=$(ref_sha "$repo" "heads/v$BASE_VERSION")
    if [[ -z "$sha" ]]; then
      ERRORS+=("$repo: base branch 'v$BASE_VERSION' not found")
      continue
    fi

    # Has the base been released? (-FINAL tag check, hard-fail)
    final_commit=$(commit_sha_of "$repo" "v$BASE_VERSION-FINAL")
    if [[ -z "$final_commit" ]]; then
      ERRORS+=("$repo: 'v$BASE_VERSION-FINAL' tag is missing — the base version does not appear to be released. Hotfixes can only be cut from a released version.")
    elif [[ "$final_commit" != "$sha" ]]; then
      # FINAL-HEAD consistency (hard-fail): commits were pushed to the branch after FINAL.
      ERRORS+=("$repo: v$BASE_VERSION branch HEAD ($sha) differs from the FINAL tag's commit ($final_commit) — commits were pushed to the branch after FINAL, so a hotfix would contain unreleased code. Manual review required.")
    fi

    # Is the base the highest FINAL of its major.minor series?
    # (The stale-base case is caught globally in Phase 0.5; skipped if approved.)
    if [[ "$ALLOW_STALE_BASE" != "true" ]]; then
      highest_final_patch=$(list_tags "$repo" \
        | sed -nE "s/^v$MAJOR\.$MINOR\.([0-9]+)-FINAL\$/\1/p" \
        | sort -n | tail -1 || true)
      if [[ -n "$highest_final_patch" && "$highest_final_patch" -gt "$PATCH" ]]; then
        ERRORS+=("$repo: v$MAJOR.$MINOR.$highest_final_patch-FINAL exists — the hotfix chain must continue from v$MAJOR.$MINOR.$highest_final_patch (a cut from a stale base requires approval)")
      fi
    fi
  fi
  SRC_SHA[i]=$sha

  # New-branch collision (idempotency): same SHA → skip, different → error
  existing_branch=$(ref_sha "$repo" "heads/$NEW_BRANCH")
  if [[ -n "$existing_branch" ]]; then
    if [[ "$existing_branch" == "$sha" ]]; then
      SKIP_BRANCH[i]=1
      echo "$repo: $NEW_BRANCH already exists and matches $SOURCE_REF_DESC HEAD — will be skipped"
    else
      hint=""
      if [[ "$MODE" == "release" ]]; then
        hint=" This version may have been cut before and main has moved on since — if you want a new cut, use the next version."
      fi
      ERRORS+=("$repo: branch $NEW_BRANCH already exists but its SHA differs from $SOURCE_REF_DESC HEAD ($existing_branch != $sha) — manual intervention required.$hint")
    fi
  fi

  # RC tag collision: compare by resolving the annotated tag to its commit
  existing_tag_commit=$(commit_sha_of "$repo" "$RC_TAG")
  if [[ -n "$existing_tag_commit" ]]; then
    if [[ "$existing_tag_commit" == "$sha" ]]; then
      SKIP_TAG[i]=1
      echo "$repo: tag $RC_TAG already exists on the correct commit — will be skipped"
    else
      ERRORS+=("$repo: tag $RC_TAG already exists but on a different commit ($existing_tag_commit != $sha) — manual intervention required")
    fi
  fi
done

if (( ${#ERRORS[@]} > 0 )); then
  fail_with_errors "$TITLE"
fi
echo "✅ All validations passed."

# ---------- Phase 2: execute ----------

{
  echo "## $TITLE $( [[ "$DRY_RUN" == "true" ]] && echo '(DRY RUN)' )"
  echo ""
  echo "Source: \`$SOURCE_REF_DESC\` — Triggered by: ${GITHUB_ACTOR:-local}"
  echo ""
  echo "| Repo | Source SHA | Branch $NEW_BRANCH | Tag $RC_TAG |"
  echo "|---|---|---|---|"
} >> "$SUMMARY"

for i in "${!REPO_LIST[@]}"; do
  repo=${REPO_LIST[$i]}
  sha=${SRC_SHA[$i]}
  b_status="created"; t_status="created"

  if [[ "$DRY_RUN" == "true" ]]; then
    b_status=$([[ -n "${SKIP_BRANCH[$i]}" ]] && echo "exists (skip)" || echo "would create")
    t_status=$([[ -n "${SKIP_TAG[$i]}" ]] && echo "exists (skip)" || echo "would create")
  else
    if [[ -n "${SKIP_BRANCH[$i]}" ]]; then
      b_status="skipped (exists)"
    else
      create_branch "$repo" "$NEW_BRANCH" "$sha"
    fi
    if [[ -n "${SKIP_TAG[$i]}" ]]; then
      t_status="skipped (exists)"
    else
      create_annotated_tag "$repo" "$RC_TAG" "$sha" "Release candidate $NEW_BRANCH (cut from $SOURCE_REF_DESC)"
    fi
    echo "$repo: $NEW_BRANCH + $RC_TAG @ $sha"
  fi

  echo "| $OWNER/$repo | \`${sha:0:10}\` | $b_status | $t_status |" >> "$SUMMARY"
done

if [[ "$DRY_RUN" == "true" ]]; then
  echo "🔎 Dry run completed — no writes were made."
else
  echo "🎉 Cut completed: $NEW_BRANCH"
fi
