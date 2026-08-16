# assistbox-mobile-tools

Tooling and automation for the Assistbox mobile ecosystem
(`assistbox-android`, `assistbox-ios`, `assistbox-mobile-web-content`).

Each tool lives under its own top-level section below.

---

## Release Cut Automation

Automation of the mobile **release cut process** with GitHub Actions: what
used to be done by hand (create a branch in 3 repos → create the RC tag →
push) now runs with a single button, with every process rule validated
automatically.

### Usage

Actions tab → select workflow → **Run workflow**:

| Workflow | Input | What it does |
|---|---|---|
| **Cut Release** | `version` (e.g. `24.0.0`), `dry_run` | Creates `v24.0.0` + `v24.0.0-RC` from `main` in 3 repos |
| **Cut Hotfix** | `base_version` (e.g. `23.0.1`), `dry_run` | Creates `v23.0.2` + `v23.0.2-RC` from `v23.0.1` in 3 repos |

**`dry_run: true`** lets you rehearse first: all validations run, the plan
is reported, nothing is pushed and no approval is requested. Every run
writes a repo × (SHA, branch, tag) status table and the triggering user to
the job summary.

### Approval flow (environment approvals)

Both workflows follow the `validate → approve → cut` pattern with **two
separate approval gates**:

**1. `cut-approval` (general gate):** runs before every *real* cut. The
`validate` job performs a dry run and writes the plan to the job summary
(source SHAs, branch/tag table); the `approve-cut` job waits until this
plan is reviewed and approved. Dry runs never request approval.

**2. `hotfix-approval` (risky gate — Cut Hotfix only):** engages *before*
the general gate when a stale base is detected:

- **Fresh base** (newest cut of its series, no released version above):
  `approve-stale-base` is skipped; only the general `cut-approval` approval
  is required.
- **Stale base** (e.g. entering `23.0.1` while `v23.0.2` is already cut):
  `validate` writes the approval message to the job summary
  (*"v23.0.2 is live; v23.0.3 will be cut from v23.0.1. Do you approve?"*
  — if the reference has no FINAL tag, *"is live"* becomes *"is cut (RC,
  not yet released)"*) and `approve-stale-base` waits for a required
  reviewer of the `hotfix-approval` environment.
  - **Approve** → the flow proceeds to the general `cut-approval` gate; once
    that is approved too, the cut continues with the series' highest cut
    patch+1 (`23.0.1` → `v23.0.3`, no collision with the existing `v23.0.2`).
  - **Reject** → the workflow stops; nothing is written to any repo.

Current policy for both environments: **a small reviewer list** (release
owners) with **self-review allowed** — the person cutting can review the
validate summary and approve it themselves. Keeping the gates separate
allows assigning different reviewers/policies later if needed.

### Layout

```
.github/workflows/
├── cut-release.yml   # validate → approve-cut → cut → scripts/cut.sh
└── cut-hotfix.yml    # validate → (approve-stale-base if stale) → approve-cut → cut
scripts/
└── cut.sh            # all cut logic (MODE=release|hotfix) — single source
```

All logic lives in `scripts/cut.sh`: no code duplication between the two
workflows, and the script can also be run locally:

```bash
export GH_TOKEN=... OWNER=assistbox REPOS="assistbox-android assistbox-ios assistbox-mobile-web-content"
MODE=release VERSION=24.0.0 DRY_RUN=true ./scripts/cut.sh
MODE=hotfix  BASE_VERSION=23.0.1 DRY_RUN=true ./scripts/cut.sh
# Deliberate cut from a stale base (the workflow uses environment approval instead):
MODE=hotfix  BASE_VERSION=22.0.1 ALLOW_STALE_BASE=true DRY_RUN=true ./scripts/cut.sh
```

### Rule table (consolidated)

#### Common — input/format rules

| Rule | Behavior |
|---|---|
| Format `X.Y.Z`, no `v` prefix, no leading zeros | Otherwise rejected (`v23.0.0`, `abc`, `23.0`, `023.0.0`, empty → rejected) |
| Release accepts only `X.0.0` | `23.1.0`, `23.0.1` are rejected (minor/patch cuts are out of scope) |
| Two-phase validate→execute | **All** validations run across the 3 repos first (no writes); a single violation → no repo is touched |
| `dry_run: true` | Validation + plan report only, no pushes, **no approval requested** |
| Malformed tags (leading zeros, e.g. `v23.0.08-FINAL`) | Ignored — never enter version calculations (octal protection) |

#### Cut Release — flow: `validate → approve-cut → cut`

| Case | Behavior |
|---|---|
| Given major = highest **RC** major + 1 | ✅ Normal cut (branch + RC tag from `main` HEAD) |
| Given major > highest RC major + 1 (e.g. `99.0.0`) | ❌ Rejected — typo protection |
| Given major < highest RC major (backdated) | ❌ Rejected — "use v(highest+1).0.0 for a new cut" |
| Same version again, `main` unchanged | ⏭️ Idempotent skip (harmless re-run) |
| Same version again, `main` moved on | ❌ Rejected — "use the next version" |
| No RC exists yet (first cut) | ✅ Unrestricted |
| Real run | 🔔 **`cut-approval`** approval required (with the validate summary) |

RC tags are used as the reference because they live on `main`'s cut
history; FINAL tags live on the release branches and are therefore not
suitable for this check.

#### Cut Hotfix — flow: `validate → [approve-stale-base] → approve-cut → cut`

| Case | Behavior |
|---|---|
| Base branch (`vX.Y.Z`) missing | ❌ Rejected |
| Base has no `-FINAL` tag | ❌ Rejected (hard-fail) — hotfixes can only be cut from a released version |
| Commits pushed to the base branch after FINAL | ❌ Rejected (hard-fail) — would contain unreleased code |
| Base = newest cut of its series, no released version above | ✅ Normal hotfix: `patch+1` (e.g. `23.0.1` → `v23.0.2`) |
| **A newer cut exists in the base's own series** (RC *or* FINAL, e.g. base `23.0.1` while `v23.0.2-RC` exists) | ⚠️ **`hotfix-approval`** approval; if approved → series' highest cut +1 (→ `v23.0.3`) |
| **A released (FINAL) version exists in a higher series** (e.g. base `22.0.1` while `v23.0.1-FINAL` is live) | ⚠️ **`hotfix-approval`** approval; if approved → continues in the base's own series (→ `v22.0.2`) |
| Higher series has *RC only* (e.g. `v24.0.0-RC`) | ✅ Not a stale base — while the new major is not live yet, hotfixing the previous series is the normal flow |
| Approval message wording | *"vX is live"* if the reference has a FINAL, *"vX is cut (RC, not yet released)"* if RC only |
| Real run | 🔔 **Two approvals** on a stale base (`hotfix-approval` first, then `cut-approval`); only `cut-approval` on a fresh base |

#### Approval gates

| Environment | When | Policy |
|---|---|---|
| `cut-approval` | Every real cut (release + hotfix), except dry runs | Small reviewer list, self-review allowed |
| `hotfix-approval` | Only hotfixes from a stale base | Small reviewer list, self-review allowed |
| Any rejection | The workflow stops; nothing is written to any repo | — |

#### Operational safety nets

| Case | Behavior |
|---|---|
| New branch/tag already exists on the same SHA | ⏭️ Skip (idempotent re-run — recovers partial failures) |
| New branch/tag already exists on a **different** SHA | ❌ Rejected — manual review required |
| Parallel duplicate triggers (same version/base) | Serialized via concurrency group |
| SHA pinning | Read once during validation; pushes use the same SHA (even if `main` moves on in between) |
| Tag type | Annotated — same type GitHub Desktop produces (`git describe` etc. work fine) |
| Audit | Pushes are made with the bot identity; the job summary shows the triggering user |

### Known limitations

| Case | Why / Impact |
|---|---|
| **Intent error:** entering the target version instead of the base in a hotfix (e.g. `23.0.2` instead of `23.0.1`) when `v23.0.2` happens to be a valid base | The script cannot know the intent; a technically valid cut is produced. Mitigation: "Base → New" is shown clearly in the summary + the approval gate + the dry-run habit |
| **The execute phase is not atomic:** an unexpected error during pushes (token, ruleset, network) can leave some repos cut | Recovered by an idempotent re-run; the guarantee is not "never half-done" but "safely completable if half-done" |
| **Parallel triggers of different versions** open a theoretical race window | The concurrency group is version-based; in practice the guards catch it, the risk is negligible |
| **Local runs with `DRY_RUN=True`** (capital T) execute for real | Local-use footgun only; the Actions boolean input always produces lowercase |
| **Version scheme for stale-base cuts** | An approved stale-base cut stays in the normal `vX.Y.Z` scheme (highest cut +1); a dedicated customer-specific suffix / 4th-segment scheme is still an open question |

### Setup

1. **GitHub App:** permission `Contents: Read & Write`, installed only on
   the 3 mobile repos. Define the `APP_CLIENT_ID` repository variable and
   the `APP_PRIVATE_KEY` secret in this repo; the workflows create a
   short-lived token per job via `actions/create-github-app-token`.
   No PAT is used.
2. **Ruleset bypass:** if the repos have a `v*` tag/branch protection
   ruleset, the GitHub App must be added to its bypass list — otherwise the
   cut pushes are rejected.
3. **FINAL backfill:** past versions that were released but are missing the
   FINAL tag must be scanned and tagged manually — otherwise the guards
   raise false alarms when those versions need a hotfix.
4. **Approval environments:** under Settings → Environments create both
   environments with the same policy — **required reviewers = small list**
   (release owners, at least 1 required; otherwise the approval job passes
   without waiting) and **prevent self-review = off**.
   - **`cut-approval`:** general approval gate for every real cut.
   - **`hotfix-approval`:** additional approval gate for stale-base hotfixes.

> **Technical note:** reading a ref from the GitHub API right after writing
> it may return a stale value due to read-replica lag. The cut flow is not
> affected (the SHA is read once and written with the same SHA), but
> back-to-back write-read sequences in tests may need a few seconds of wait.
