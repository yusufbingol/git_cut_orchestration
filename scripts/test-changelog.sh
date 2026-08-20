#!/usr/bin/env bash
# RC → FINAL changelog üretimi (release sonrası).
# Her repo için vX.Y.Z-RC..vX.Y.Z-FINAL aralığındaki commit'leri listeler,
# AS-XXXXX Jira ticket'larını ayıklar ve job summary'ye yazar.
# Kullanım (env üzerinden):
#   VERSION=25.0.0 ./test-changelog.sh
# Gerekli env: OWNER, REPOS (boşlukla ayrılmış), GH_TOKEN, VERSION
# Opsiyonel env:
#   JIRA_BASE_URL     — örn. https://xxx.atlassian.net/browse (boşsa ticket'lar linksiz listelenir)
#   SLACK_WEBHOOK_URL — boşsa Slack bildirimi atlanır
#   COMPARE_HEAD      — sadece lokal test için: FINAL yerine karşılaştırılacak ref (örn. branch adı)
set -euo pipefail

: "${OWNER:?OWNER gerekli}"
: "${REPOS:?REPOS gerekli}"
: "${GH_TOKEN:?GH_TOKEN gerekli (ortam gh oturumuna düşmeyi engeller)}"
: "${VERSION:?VERSION gerekli}"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"

if ! [[ "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
  echo "::error::Versiyon 'X.Y.Z' formatında olmalı (girilen: $VERSION)"
  exit 1
fi

RC_TAG="v$VERSION-RC"
HEAD_REF="${COMPARE_HEAD:-v$VERSION-FINAL}"
read -r -a REPO_LIST <<< "$REPOS"

# Tag/branch adını COMMIT SHA'sına çözer (annotated tag'i dereference eder); yoksa boş.
commit_sha_of() { # repo, ref-adı
  local out
  if out=$(gh api "repos/$OWNER/$1/commits/$2" --jq .sha 2>/dev/null); then
    echo "$out"
  fi
}

ALL_TICKETS=""
SLACK_LINES=""

{
  echo "## 📋 Changelog — v$VERSION ($RC_TAG → $HEAD_REF)"
  echo ""
  echo "Cut sonrası release branch'ine giren değişiklikler (cherry-pick'ler)."
  echo ""
} >> "$SUMMARY"

for repo in "${REPO_LIST[@]}"; do
  echo "--- Changelog: $OWNER/$repo ---"

  rc_sha=$(commit_sha_of "$repo" "$RC_TAG")
  head_sha=$(commit_sha_of "$repo" "$HEAD_REF")
  if [[ -z "$rc_sha" || -z "$head_sha" ]]; then
    echo "::error::$repo: '$RC_TAG' veya '$HEAD_REF' çözümlenemedi — changelog üretilemiyor."
    exit 1
  fi

  # Compare API: RC ile FINAL arasındaki commit'ler (merge commit'leri atlanır;
  # PR merge'lerinde asıl iş commit'i zaten listede).
  # Hata durumunda fail-fast: changelog eksik/yanıltıcı üretilmesin.
  commits=$(gh api "repos/$OWNER/$repo/compare/$rc_sha...$head_sha" \
    --jq '[.commits[] | select((.parents | length) < 2)
           | {sha: .sha[0:10], msg: (.commit.message | split("\n")[0]), author: .commit.author.name}]') || {
    echo "::error::$repo: compare çağrısı başarısız — changelog üretilemiyor."
    exit 1
  }
  count=$(printf '%s' "$commits" | jq 'length')

  {
    echo "### $OWNER/$repo"
    echo ""
  } >> "$SUMMARY"

  if (( count == 0 )); then
    echo "$repo: değişiklik yok"
    echo "_Değişiklik yok — FINAL, RC ile aynı kod._" >> "$SUMMARY"
    echo "" >> "$SUMMARY"
    SLACK_LINES+="• $repo: değişiklik yok"$'\n'
  else
    {
      echo "| Commit | Açıklama | Yazar |"
      echo "|---|---|---|"
      printf '%s' "$commits" | jq -r '.[] | "| `\(.sha)` | \(.msg) | \(.author) |"'
      echo ""
    } >> "$SUMMARY"
    printf '%s' "$commits" | jq -r '.[] | "\(.sha) \(.msg)"'
    SLACK_LINES+="• $repo: $count commit"$'\n'
  fi

  # Jira ticket'larını commit mesajlarından ayıkla (AS-XXXXX).
  ALL_TICKETS+=$(printf '%s' "$commits" | jq -r '.[].msg' | grep -oE 'AS-[0-9]+' || true)$'\n'
done

# ---------- Birleşik Jira ticket listesi (3 repo genelinde tekilleştirilmiş) ----------

TICKETS=$(printf '%s' "$ALL_TICKETS" | grep -v '^$' | sort -u -t- -k2,2n || true)
{
  echo "### 🎫 Jira Ticket'ları"
  echo ""
} >> "$SUMMARY"
if [[ -z "$TICKETS" ]]; then
  echo "_Commit mesajlarında ticket referansı bulunamadı._" >> "$SUMMARY"
else
  while IFS= read -r t; do
    if [[ -n "${JIRA_BASE_URL:-}" ]]; then
      echo "- [$t](${JIRA_BASE_URL%/}/$t)" >> "$SUMMARY"
    else
      echo "- $t" >> "$SUMMARY"
    fi
  done <<< "$TICKETS"
fi
echo "" >> "$SUMMARY"
echo "Ticket'lar: $(printf '%s' "$TICKETS" | tr '\n' ' ')"

# ---------- Slack bildirimi (webhook tanımlıysa) ----------

if [[ -n "${SLACK_WEBHOOK_URL:-}" ]]; then
  TICKET_LINE=$(printf '%s' "$TICKETS" | tr '\n' ' ')
  payload=$(jq -n --arg text "🎉 *v$VERSION released* ($RC_TAG → $HEAD_REF)
$SLACK_LINES
🎫 Tickets: ${TICKET_LINE:-yok}" '{text: $text}')
  # Bildirim hatası release'i geriye dönük bozamaz — uyarı verip devam edilir.
  if curl -sS -f -X POST -H 'Content-Type: application/json' -d "$payload" "$SLACK_WEBHOOK_URL" > /dev/null; then
    echo "Slack bildirimi gönderildi."
  else
    echo "::warning::Slack bildirimi gönderilemedi (webhook hatası) — changelog yine de üretildi."
  fi
else
  echo "Slack bildirimi atlandı (SLACK_WEBHOOK_URL tanımlı değil)."
fi

echo "✅ Changelog üretildi: v$VERSION"
