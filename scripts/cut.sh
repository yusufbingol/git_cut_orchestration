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
# Eski base onayı: serinin daha yüksek FINAL'i varken eski base'den hotfix'e
# izin verir (workflow'da environment approval sonrası true geçilir).
ALLOW_STALE_BASE="${ALLOW_STALE_BASE:-false}"
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
  # Başında sıfır kabul edilmez (023 → octal/isim kirliliği riski).
  if ! [[ "$VERSION" =~ ^(0|[1-9][0-9]*)\.0\.0$ ]]; then
    echo "::error::Versiyon 'X.0.0' formatında olmalı, başında sıfır olmadan (girilen: $VERSION). Minor/patch cut bu workflow'un kapsamında değil."
    exit 1
  fi
  NEW_MAJOR="${BASH_REMATCH[1]}"
  NEW_VERSION="$VERSION"
  SOURCE_REF_DESC="main"
  TITLE="Cut Release v$NEW_VERSION"
elif [[ "$MODE" == "hotfix" ]]; then
  : "${BASE_VERSION:?BASE_VERSION gerekli (hotfix modu)}"
  # Başında sıfır kabul edilmez (023 → octal/isim kirliliği riski).
  if ! [[ "$BASE_VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
    echo "::error::Base versiyon 'X.Y.Z' formatında olmalı, başında sıfır olmadan (girilen: $BASE_VERSION)"
    exit 1
  fi
  MAJOR="${BASH_REMATCH[1]}"; MINOR="${BASH_REMATCH[2]}"; PATCH="${BASH_REMATCH[3]}"
  NEW_VERSION="$MAJOR.$MINOR.$((PATCH + 1))"
  SOURCE_REF_DESC="v$BASE_VERSION"
  TITLE="Cut Hotfix v$NEW_VERSION (base: v$BASE_VERSION)"
else
  echo "::error::Geçersiz MODE: $MODE (release|hotfix)"
  exit 1
fi

ERRORS=()
read -r -a REPO_LIST <<< "$REPOS"
SRC_SHA=(); SKIP_BRANCH=(); SKIP_TAG=()

# ---------- Faz 0.5 (hotfix): eski base tespiti ----------
# "Eski base" iki durumda oluşur:
#   a) Base'in KENDİ serisinde daha yeni bir kesim (RC veya FINAL) var
#      (örn. v23.0.2 kesilmişken base 23.0.1) — zincir en yeniden sürmeli.
#   b) Daha yüksek bir seride release edilmiş (FINAL) versiyon var
#      (örn. canlıda v22.0.2 varken base 21.0.1).
# Not: üst seride sadece RC olması (yeni major kesilmiş ama release
# edilmemiş) eski base sayılmaz — önceki serinin hotfix'i normal akıştır.
# Varsayılan: red. ALLOW_STALE_BASE=true ise (workflow'da environment
# approval sonrası) devam edilir; yeni versiyon base'in kendi serisinde,
# mevcut kesimlerle çakışmasın diye serinin en yüksek kesiminin patch+1'i olur.
STALE_BASE=false
APPROVAL_MESSAGE=""
if [[ "$MODE" == "hotfix" ]]; then
  ALL_FINALS=""; SERIES_CUTS=""
  for repo in "${REPO_LIST[@]}"; do
    tags=$(list_tags "$repo" || true)
    # Not: sadece düzgün formatlı sayılar eşleşir (sıfır önekli, örn. "08",
    # tag'ler yok sayılır — bash aritmetiğinde octal hatasına yol açardı).
    ALL_FINALS+=$(printf '%s' "$tags" | sed -nE 's/^v((0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*))-FINAL$/\1/p')$'\n'
    SERIES_CUTS+=$(printf '%s' "$tags" | sed -nE "s/^v$MAJOR\.$MINOR\.(0|[1-9][0-9]*)-(RC|FINAL)\$/\1/p")$'\n'
  done
  # Base serisindeki en yüksek kesilmiş patch (RC veya FINAL).
  HIGHEST_CUT_PATCH=$(printf '%s' "$SERIES_CUTS" | grep -v '^$' | sort -n | tail -1 || true)
  HIGHEST_CUT_PATCH="${HIGHEST_CUT_PATCH:-$PATCH}"
  (( HIGHEST_CUT_PATCH < PATCH )) && HIGHEST_CUT_PATCH="$PATCH"
  # Referans versiyon: max(global en yüksek FINAL, seri içi en yüksek kesim).
  REFERENCE=$(printf '%s\n%s\n' "$ALL_FINALS" "$MAJOR.$MINOR.$HIGHEST_CUT_PATCH" \
    | grep -v '^$' | sort -u -t. -k1,1n -k2,2n -k3,3n | tail -1 || true)

  if [[ -n "$REFERENCE" && "$REFERENCE" != "$BASE_VERSION" ]] \
     && [[ "$(printf '%s\n%s\n' "$REFERENCE" "$BASE_VERSION" | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)" == "$REFERENCE" ]]; then
    # Referansın durumu: FINAL'i varsa release edilmiş ("canlıda"),
    # sadece RC'liyse kesilmiş ama henüz release edilmemiş.
    if printf '%s' "$ALL_FINALS" | grep -qx "$REFERENCE"; then
      REF_DESC="v$REFERENCE canlıda"
    else
      REF_DESC="v$REFERENCE kesilmiş (RC, henüz release edilmedi)"
    fi
    if [[ "$ALLOW_STALE_BASE" != "true" ]]; then
      echo "::error::$REF_DESC iken eski base v$BASE_VERSION üzerinden hotfix onay gerektirir — workflow üzerinden çalıştırın (environment approval) veya lokalde bilinçli olarak ALLOW_STALE_BASE=true verin."
      exit 1
    fi
    STALE_BASE=true
    NEW_VERSION="$MAJOR.$MINOR.$((HIGHEST_CUT_PATCH + 1))"
    TITLE="Cut Hotfix v$NEW_VERSION (base: v$BASE_VERSION — ESKİ BASE)"
    APPROVAL_MESSAGE="$REF_DESC, v$BASE_VERSION üzerinden v$NEW_VERSION alınacak. Onaylıyor musunuz?"
    echo "⚠️  Eski base tespit edildi: $APPROVAL_MESSAGE"
  fi
  echo "Base: v$BASE_VERSION → Yeni hotfix versiyonu: v$NEW_VERSION"
  # Workflow'un approval job'ına karar verdirmek için output'lar.
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

    # Major guard'ı (typo koruması): sadece en yüksek RC major'ın kendisi
    # (idempotent re-run) veya +1'i (yeni cut) kabul edilir. Hiç RC yoksa
    # ilk cut serbest. (Sıfır önekli bozuk tag'ler yok sayılır — octal riski.)
    highest_major=$(list_tags "$repo" \
      | sed -nE 's/^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)-RC$/\1/p' \
      | sort -n | tail -1 || true)
    if [[ -n "$highest_major" ]]; then
      if [[ "$NEW_MAJOR" -gt $((highest_major + 1)) ]]; then
        ERRORS+=("$repo: girilen major v$NEW_MAJOR, mevcut en yüksek RC major'ı v$highest_major — en fazla v$((highest_major + 1)).0.0 kesilebilir (typo koruması)")
      elif [[ "$NEW_MAJOR" -lt "$highest_major" ]]; then
        ERRORS+=("$repo: girilen major v$NEW_MAJOR, mevcut en yüksek RC major'ından (v$highest_major) küçük — güncel main'den geriye dönük versiyon kesilemez. Yeni cut için v$((highest_major + 1)).0.0 kullanın (typo koruması)")
      fi
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
    # (Eski base durumu Faz 0.5'te global olarak yakalanır; onaylıysa geçilir.)
    if [[ "$ALLOW_STALE_BASE" != "true" ]]; then
      highest_final_patch=$(list_tags "$repo" \
        | sed -nE "s/^v$MAJOR\.$MINOR\.([0-9]+)-FINAL\$/\1/p" \
        | sort -n | tail -1 || true)
      if [[ -n "$highest_final_patch" && "$highest_final_patch" -gt "$PATCH" ]]; then
        ERRORS+=("$repo: v$MAJOR.$MINOR.$highest_final_patch-FINAL mevcut — hotfix zinciri v$MAJOR.$MINOR.$highest_final_patch üzerinden devam etmeli (eski base'den cut onay gerektirir)")
      fi
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
      hint=""
      if [[ "$MODE" == "release" ]]; then
        hint=" Bu versiyon daha önce kesilmiş ve main o zamandan beri ilerlemiş olabilir — yeni bir cut istiyorsanız bir sonraki versiyonu girin."
      fi
      ERRORS+=("$repo: $NEW_BRANCH branch'i zaten var ama SHA'sı $SOURCE_REF_DESC HEAD'den farklı ($existing_branch != $sha) — elle müdahale gerekli.$hint")
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
