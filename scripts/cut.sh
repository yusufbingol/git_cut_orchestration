#!/usr/bin/env bash
# Cut alma sürecinin ortak mantığı.
# Kullanım (env üzerinden):
#   MODE=release VERSION=23.0.0        [DRY_RUN=true] ./cut.sh
#   MODE=hotfix  BASE_VERSION=22.0.0   [DRY_RUN=true] ./cut.sh
# Gerekli env: OWNER, REPOS (boşlukla ayrılmış), GH_TOKEN
# GITHUB_STEP_SUMMARY tanımlıysa özet tablo oraya yazılır.
set -euo pipefail

: "${OWNER:?OWNER gerekli}"
: "${REPOS:?REPOS gerekli}"
: "${MODE:?MODE gerekli (release|hotfix)}"
DRY_RUN="${DRY_RUN:-false}"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"

# ---------- Yardımcılar ----------

# Ref'in işaret ettiği objenin SHA'sı; ref yoksa boş.
# Annotated tag'lerde bu SHA tag OBJESİNİN sha'sıdır, commit değil.
# Not: gh api HTTP hatasında hata gövdesini stdout'a basar — bu yüzden
# çıktı sadece exit code 0 ise kullanılır.
ref_sha() { # repo, ref (heads/... | tags/...)
  local out
  if out=$(gh api "repos/$OWNER/$1/git/ref/$2" --jq .object.sha 2>/dev/null); then
    echo "$out"
  fi
}

# Tag/branch adını COMMIT SHA'sına çözer (annotated tag'i dereference eder); yoksa boş.
commit_sha_of() { # repo, ref-adı (örn. v22.0.0-FINAL)
  local out
  if out=$(gh api "repos/$OWNER/$1/commits/$2" --jq .sha 2>/dev/null); then
    echo "$out"
  fi
}

create_branch() { # repo, branch, sha
  gh api -X POST "repos/$OWNER/$1/git/refs" -f ref="refs/heads/$2" -f sha="$3" --jq .ref
}

# Annotated tag: önce tag objesi, sonra ref (GitHub Desktop'ın ürettiğiyle aynı tip).
create_annotated_tag() { # repo, tag, sha, message
  local tag_obj
  tag_obj=$(gh api -X POST "repos/$OWNER/$1/git/tags" \
    -f tag="$2" -f message="$4" -f object="$3" -f type=commit --jq .sha)
  gh api -X POST "repos/$OWNER/$1/git/refs" -f ref="refs/tags/$2" -f sha="$tag_obj" --jq .ref
}

# Repodaki tüm tag adları (pagination dahil).
list_tags() { # repo
  gh api --paginate "repos/$OWNER/$1/git/matching-refs/tags/" --jq '.[].ref' | sed 's|refs/tags/||'
}

fail_with_errors() { # başlık
  echo "## ❌ $1 — Validasyon Hatası" >> "$SUMMARY"
  local e
  for e in "${ERRORS[@]}"; do
    echo "- $e" >> "$SUMMARY"
    echo "::error::$e"
  done
  echo "Hiçbir repoya yazma yapılmadı."
  exit 1
}

# ---------- Faz 0: format validasyonu + versiyon hesabı ----------

if [[ "$MODE" == "release" ]]; then
  : "${VERSION:?VERSION gerekli (release modu)}"
  if ! [[ "$VERSION" =~ ^([0-9]+)\.0\.0$ ]]; then
    echo "::error::Versiyon 'X.0.0' formatında olmalı (girilen: $VERSION). Minor/patch cut bu workflow'un kapsamında değil."
    exit 1
  fi
  NEW_MAJOR="${BASH_REMATCH[1]}"
  NEW_VERSION="$VERSION"
  SOURCE_REF_DESC="main"
  TITLE="Cut Release v$NEW_VERSION"
elif [[ "$MODE" == "hotfix" ]]; then
  : "${BASE_VERSION:?BASE_VERSION gerekli (hotfix modu)}"
  if ! [[ "$BASE_VERSION" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    echo "::error::Base versiyon 'X.Y.Z' formatında olmalı (girilen: $BASE_VERSION)"
    exit 1
  fi
  MAJOR="${BASH_REMATCH[1]}"; MINOR="${BASH_REMATCH[2]}"; PATCH="${BASH_REMATCH[3]}"
  NEW_VERSION="$MAJOR.$MINOR.$((PATCH + 1))"
  SOURCE_REF_DESC="v$BASE_VERSION"
  TITLE="Cut Hotfix v$NEW_VERSION (base: v$BASE_VERSION)"
  echo "Base: v$BASE_VERSION → Yeni hotfix versiyonu: v$NEW_VERSION"
else
  echo "::error::Geçersiz MODE: $MODE (release|hotfix)"
  exit 1
fi

NEW_BRANCH="v$NEW_VERSION"
RC_TAG="v$NEW_VERSION-RC"
ERRORS=()
read -r -a REPO_LIST <<< "$REPOS"
SRC_SHA=(); SKIP_BRANCH=(); SKIP_TAG=()

# ---------- Faz 1: tüm repolarda validasyon (yazma yok) ----------

for i in "${!REPO_LIST[@]}"; do
  repo=${REPO_LIST[$i]}
  echo "--- Validating $OWNER/$repo ---"
  SRC_SHA[i]=""; SKIP_BRANCH[i]=""; SKIP_TAG[i]=""

  if [[ "$MODE" == "release" ]]; then
    # Kaynak: main HEAD
    sha=$(ref_sha "$repo" "heads/main")
    if [[ -z "$sha" ]]; then
      ERRORS+=("$repo: 'main' branch'i bulunamadı")
      continue
    fi

    # Major sıçrama guard'ı (typo koruması): en yüksek RC major'ı + 1'den
    # büyük major reddedilir. Hiç RC yoksa ilk cut kabul edilir.
    highest_major=$(list_tags "$repo" \
      | sed -nE 's/^v([0-9]+)\.[0-9]+\.[0-9]+-RC$/\1/p' \
      | sort -n | tail -1 || true)
    if [[ -n "$highest_major" && "$NEW_MAJOR" -gt $((highest_major + 1)) ]]; then
      ERRORS+=("$repo: girilen major v$NEW_MAJOR, mevcut en yüksek RC major'ı v$highest_major — en fazla v$((highest_major + 1)).0.0 kesilebilir (typo koruması)")
    fi
  else
    # Kaynak: base release branch HEAD
    sha=$(ref_sha "$repo" "heads/v$BASE_VERSION")
    if [[ -z "$sha" ]]; then
      ERRORS+=("$repo: base branch 'v$BASE_VERSION' bulunamadı")
      continue
    fi

    # Base release edilmiş mi? (-FINAL tag kontrolü, hard-fail)
    final_commit=$(commit_sha_of "$repo" "v$BASE_VERSION-FINAL")
    if [[ -z "$final_commit" ]]; then
      ERRORS+=("$repo: 'v$BASE_VERSION-FINAL' tag'i yok — base versiyon release edilmemiş görünüyor. Hotfix sadece release edilmiş versiyondan alınabilir.")
    elif [[ "$final_commit" != "$sha" ]]; then
      # FINAL-HEAD tutarlılığı (hard-fail): FINAL'den sonra branch'e commit gelmiş.
      ERRORS+=("$repo: v$BASE_VERSION branch HEAD'i ($sha) FINAL tag'inin commit'inden ($final_commit) farklı — FINAL sonrası branch'e commit pushlanmış, hotfix release edilmemiş kod içerir. Elle inceleme gerekli.")
    fi

    # Base, o major.minor serisinin en yüksek FINAL'i mi?
    highest_final_patch=$(list_tags "$repo" \
      | sed -nE "s/^v$MAJOR\.$MINOR\.([0-9]+)-FINAL\$/\1/p" \
      | sort -n | tail -1 || true)
    if [[ -n "$highest_final_patch" && "$highest_final_patch" -gt "$PATCH" ]]; then
      ERRORS+=("$repo: v$MAJOR.$MINOR.$highest_final_patch-FINAL mevcut — hotfix zinciri v$MAJOR.$MINOR.$highest_final_patch üzerinden devam etmeli (eski versiyona müşteri-özel hotfix v1'de desteklenmiyor, bkz. Open Questions)")
    fi
  fi
  SRC_SHA[i]=$sha

  # Yeni branch çakışması (idempotency): aynı SHA → skip, farklı → hata
  existing_branch=$(ref_sha "$repo" "heads/$NEW_BRANCH")
  if [[ -n "$existing_branch" ]]; then
    if [[ "$existing_branch" == "$sha" ]]; then
      SKIP_BRANCH[i]=1
      echo "$repo: $NEW_BRANCH zaten var ve $SOURCE_REF_DESC HEAD ile aynı — skip edilecek"
    else
      ERRORS+=("$repo: $NEW_BRANCH branch'i zaten var ama SHA'sı $SOURCE_REF_DESC HEAD'den farklı ($existing_branch != $sha) — elle müdahale gerekli")
    fi
  fi

  # RC tag çakışması: annotated tag'i commit'e çözerek karşılaştır
  existing_tag_commit=$(commit_sha_of "$repo" "$RC_TAG")
  if [[ -n "$existing_tag_commit" ]]; then
    if [[ "$existing_tag_commit" == "$sha" ]]; then
      SKIP_TAG[i]=1
      echo "$repo: $RC_TAG tag'i zaten var ve doğru commit'te — skip edilecek"
    else
      ERRORS+=("$repo: $RC_TAG tag'i zaten var ama farklı commit'te ($existing_tag_commit != $sha) — elle müdahale gerekli")
    fi
  fi
done

if (( ${#ERRORS[@]} > 0 )); then
  fail_with_errors "$TITLE"
fi
echo "✅ Tüm validasyonlar geçti."

# ---------- Faz 2: execute ----------

{
  echo "## $TITLE $( [[ "$DRY_RUN" == "true" ]] && echo '(DRY RUN)' )"
  echo ""
  echo "Kaynak: \`$SOURCE_REF_DESC\` — Tetikleyen: ${GITHUB_ACTOR:-local}"
  echo ""
  echo "| Repo | Kaynak SHA | Branch $NEW_BRANCH | Tag $RC_TAG |"
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
  echo "🔎 Dry run tamamlandı — hiçbir yazma yapılmadı."
else
  echo "🎉 Cut tamamlandı: $NEW_BRANCH"
fi
