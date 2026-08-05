# git_cut_orchestration

Assistbox mobil **cut alma sürecinin** GitHub Actions ile otomasyonu — test/deneme kurulumu.

Bu repo, gerçek ortamdaki `assistbox-mobile-release` orchestration reposunun prototipidir.
Test için 3 dummy repo kullanılır:

| Dummy repo | Simüle ettiği repo |
|---|---|
| `yusufbingol/git_deneme` | `assistbox-ios` |
| `yusufbingol/git_deneme_2` | `assistbox-android` |
| `yusufbingol/git_deneme_3` | `assistbox-mobile-web-content` |

## Yapı

```
git_cut_orchestration/
├── .github/workflows/
│   ├── cut-release.yml   # ince katman: input + concurrency → scripts/cut.sh
│   └── cut-hotfix.yml    # ince katman: input + concurrency → scripts/cut.sh
└── scripts/
    └── cut.sh            # tüm ortak mantık (MODE=release|hotfix)
```

Cut mantığının tamamı `scripts/cut.sh`'ta — iki workflow arasında kopya kod yok,
script lokalde de çalıştırılıp test edilebilir (shellcheck temiz):

```bash
export GH_TOKEN=... OWNER=yusufbingol REPOS="git_deneme git_deneme_2 git_deneme_3"
MODE=release VERSION=23.0.0 DRY_RUN=true ./scripts/cut.sh
MODE=hotfix  BASE_VERSION=23.0.0 DRY_RUN=true ./scripts/cut.sh
```

## Workflow'lar

### `cut-release.yml` — Normal Cut

**Input:** `version` (örn. `23.0.0`, sadece `X.0.0` kabul edilir), `dry_run`

**Akış (iki fazlı):**
1. **Validate** (3 repoda, hiçbir yazma yok):
   - Format `X.0.0` mi?
   - `main` branch'i mevcut mu?
   - **Major sıçrama guard'ı:** girilen major, mevcut en yüksek RC major'ının
     en fazla +1'i olabilir (typo koruması, örn. `99.0.0` reddedilir)
   - `vX.0.0` branch'i / `vX.0.0-RC` tag'i çakışıyor mu? (Aynı SHA'daysa → skip, farklıysa → hata)
   - Herhangi biri failse **hiçbir repoya dokunulmaz**.
2. **Execute:** Her repoda `main` HEAD'inden `vX.0.0` branch'i + aynı SHA'ya
   **annotated** `vX.0.0-RC` tag'i (GitHub API ile, clone yok).

### `cut-hotfix.yml` — Hotfix Cut

**Input:** `base_version` (örn. `22.0.0`), `dry_run`
**Yeni versiyon elle girilmez, hesaplanır:** base patch+1 → `22.0.1`

**Hotfix'e özel validasyonlar (3 repoda):**
1. `v{base}` branch'i mevcut mu?
2. `v{base}-FINAL` tag'i var mı? → release kanıtı (**hard-fail**)
3. **FINAL-HEAD tutarlılığı (hard-fail):** `v{base}` branch HEAD'i FINAL
   tag'inin commit'iyle aynı mı? Farklıysa FINAL sonrası branch'e commit
   pushlanmış demektir — hotfix release edilmemiş kod içerir, reddedilir.
4. Base, o `major.minor` serisinin **en yüksek FINAL'i** mi? (örn. `v22.0.1-FINAL` varken base `22.0.0` girilirse hata)
5. Yeni branch/tag çakışması yok mu?

**Execute:** `v{base}` HEAD'inden `v{new}` branch + `v{new}-RC` tag (cherry-pick'lerden **önce** — dokümanla uyumlu).

## Güvenlik Ağları

- **İki fazlı validate→execute:** kısmi cut riski minimum
- **SHA validasyon anında yakalanır:** execute aynı SHA'yı kullanır — validasyon
  ile push arasında main'e commit gelse bile tutarlılık korunur
- **İdempotent re-run:** branch/tag zaten var ve doğru SHA'da → skip; farklı SHA'da → hata (elle müdahale)
- **Concurrency guard:** aynı versiyon için paralel çift tetikleme serileştirilir
- **Annotated tag:** GitHub Desktop'ın ürettiğiyle aynı tip (önce tag objesi,
  sonra ref) — mevcut tag'lerle tutarlı, `git describe` vb. tooling sorunsuz
- **`dry_run` modu:** validasyonları çalıştırır, ne yapılacağını job summary'de gösterir, push yapmaz
- **Job summary:** her run sonunda repo × (SHA, branch, tag) durum tablosu + tetikleyen kişi

> Not (testte öğrenildi): GitHub API'de ref güncellemesinden hemen sonra okuma,
> read-replica gecikmesiyle eski değer döndürebilir. Cut akışı bundan etkilenmez
> (SHA bir kez okunur, aynı SHA ile yazılır) ama testlerde peş peşe
> yaz-oku yaparken birkaç saniye beklemek gerekebilir.

## Kurulum

1. Bu klasörü GitHub'da bir repo olarak yayınla (örn. `yusufbingol/git_cut_orchestration`).
2. **Token:**
   - **Test ortamı (bu kurulum):** Fine-grained PAT oluştur — Repository access: 3 dummy repo, Permission: `Contents: Read & Write`. Repo secrets'a `RELEASE_BOT_TOKEN` adıyla ekle.
   - **Gerçek ortam:** GitHub App (`assistbox-release-bot`) — `Contents: R/W`, sadece 3 repoya install. Workflow'daki yorum satırındaki `actions/create-github-app-token` adımını aç, `APP_ID` / `APP_PRIVATE_KEY` secret'larını ekle.
3. Actions sekmesinden `Cut Release` veya `Cut Hotfix` workflow'unu `Run workflow` ile tetikle (önce `dry_run: true` önerilir).

## Test Durumu

`scripts/cut.sh` lokalde gerçek `gh` ile uçtan uca test edildi (2026-08-05).
Dummy repolarda şu an mevcut durum: `v23.0.0` + `v23.0.1` branch'leri,
`-RC` ve `-FINAL` tag'leri (hepsi annotated).

Geçen senaryolar:
1. ✅ Release dry-run + gerçek cut (`v23.0.0`, 3 repoda branch + annotated RC)
2. ✅ İdempotent re-run (skip)
3. ✅ Format guard (`23.1.0` reddedildi)
4. ✅ Major sıçrama guard'ı (`99.0.0` reddedildi)
5. ✅ FINAL yokken hotfix reddi
6. ✅ Hotfix mutlu yol (`23.0.0` → `v23.0.1`)
7. ✅ Zincir guard'ı (`v23.0.1-FINAL` varken base `23.0.0` reddedildi)
8. ✅ FINAL-HEAD tutarlılık guard'ı (FINAL sonrası commit → hard-fail)

GitHub Actions üzerinde test için: bu klasörü repo olarak yayınla,
`RELEASE_BOT_TOKEN` secret'ını ekle, `dry_run: true` ile tetikle.
(İdempotency sayesinde mevcut `v23.x` durumu sorun çıkarmaz; temiz test
için `24.0.0` kullanılabilir.)

## Kapsam Dışı (Faz-2)

- FINAL tag'leme workflow'u (`tag-final.yml`)
- Jenkins/Bitrise build tetikleme
- Jira release task oluşturma, Slack bildirimi
- Minor cut (`vX.Y.0`, Y>0)

## Open Questions

1. **Eski versiyona müşteri-özel hotfix:** Canlıda `v22.0.2` varken müşterideki `v22.0.1` üzerine hotfix çıkmak gerekirse mevcut `vX.Y.Z` şemasında yeri yok. Adaylar: 4. segment (`v22.0.1.1`) veya suffix (`v22.0.1-cust-acme.1`). Karar verilene kadar workflow bu durumu **reddediyor** (en yüksek FINAL guard'ı).
2. Minor cut semantiği: `main`'den mi, release branch'inden mi?
3. FINAL tag otomasyonu: hard-fail guard geçmişteki eksik FINAL'leri yüzeye çıkaracak — eski versiyonlara elle FINAL atmak gerekebilir.
