# Mobil Cut Alma Otomasyonu

Assistbox mobil **cut alma sürecinin** GitHub Actions ile otomasyonu.

Bugün elle yapılan süreç (3 repoda branch oluştur → RC tag'i at → push), tek
butonla, tüm kurallar otomatik doğrulanarak çalışır hale geliyor.

> Bu repo deneme/prototip ortamıdır. Gerçek ortamdaki karşılıkları:
>
> | Test reposu | Gerçek repo |
> |---|---|
> | `git_deneme` | `assistbox-ios` |
> | `git_deneme_2` | `assistbox-android` |
> | `git_deneme_3` | `assistbox-mobile-web-content` |

---

## 1. Süreç Kuralları (otomasyonun uyguladığı)

Mevcut versioning/hotfix dokümanlarımızdaki kurallar birebir kod'a taşındı:

**Normal cut (sprint sonu, `vX.0.0`):**
- `main` HEAD'inden `vX.0.0` branch'i oluşturulur — 3 repoda birden
- Branch'in oluşturulduğu commit'e `vX.0.0-RC` tag'i atılır (annotated)
- Versiyon, mevcut en yüksek RC major'ının +1'i olmalıdır (RC tag'leri
  `main` kesim geçmişini temsil eder; FINAL tag'leri release branch'lerinde
  yaşadığından bu kontrol için uygun değildir)

**Hotfix cut (`vX.Y.Z+1`):**
- Asla `main`'den alınmaz — release edilmiş `vX.Y.Z` branch'inden alınır
- Yeni versiyon **elle girilmez**, base'in patch+1'i olarak hesaplanır
  (yanlış giriş riski sıfır)
- Base versiyonun release edildiğinin kanıtı: `vX.Y.Z-FINAL` tag'i (zorunlu)
- Base zaten hotfix'li release edilmişse zincir oradan devam eder
  (v22.0.1-FINAL varken v22.0.0'dan hotfix alınamaz)
- **Eski base'den hotfix onayla mümkün:** base'in kendi serisinde daha yeni
  bir kesim (RC/FINAL) varsa **veya** daha yüksek bir seride release edilmiş
  (FINAL) versiyon varsa workflow otomatik reddetmek yerine **environment
  approval** ister ("v23.0.2 canlıda, v23.0.1 üzerinden v23.0.3 alınacak.
  Onaylıyor musunuz?" — referans release edilmemişse "canlıda" yerine
  "kesilmiş (RC, henüz release edilmedi)" denir); onay verilirse yeni
  versiyon base'in kendi serisinde,
  çakışmayı önlemek için serinin en yüksek kesiminin patch+1'i olur.
  (Üst seride *sadece RC* olması eski base sayılmaz — yeni major kesilmişken
  önceki serinin hotfix'i normal akıştır.)
- Web-content'te değişiklik olmasa bile 3 repoda da kesilir
- RC tag'i cherry-pick'lerden **önce** atılır (dokümanla uyumlu)

**Ya hep ya hiç:** Önce 3 repoda **tüm** validasyonlar çalışır (hiçbir yazma
yapılmadan). Tek bir kural bile ihlal ediliyorsa hiçbir repoya dokunulmaz.

---

## 2. Kullanım

Actions sekmesi → workflow seç → **Run workflow**:

| Workflow | Input | Ne yapar |
|---|---|---|
| **Cut Release** | `version` (örn. `24.0.0`), `dry_run` | 3 repoda `main`'den `v24.0.0` + `v24.0.0-RC` |
| **Cut Hotfix** | `base_version` (örn. `23.0.1`), `dry_run` | 3 repoda `v23.0.1`'den `v23.0.2` + `v23.0.2-RC` |

**`dry_run: true`** ile önce prova yapılabilir: tüm validasyonlar çalışır,
ne yapılacağı raporlanır, hiçbir şey pushlanmaz. Her run sonunda job
summary'de repo × (SHA, branch, tag) durum tablosu ve tetikleyen kişi görünür.

### Onay akışı (environment approval)

Her iki workflow da `validate → onay → cut` desenindedir ve **iki ayrı onay
kapısı** vardır:

**1. `cut-approval` (genel kapı):** her *gerçek* cut'tan önce çalışır.
`validate` job'ı dry-run yapıp job summary'ye planı yazar (kaynak SHA'lar,
oluşturulacak branch/tag tablosu); `approve-cut` job'ı bu plan incelenip
onaylanana kadar bekler. `dry_run: true`'da onay istenmez — prova
sürtünmesizdir.

**2. `hotfix-approval` (riskli kapı — sadece Cut Hotfix):** eski base
tespitinde genel kapıdan *önce* devreye girer:

- **Güncel base** (serinin en yeni kesimi, üst seride FINAL yok):
  `approve-stale-base` skip edilir, sadece genel `cut-approval` onayı
  gerekir.
- **Eski base** (örn. `v23.0.2` kesilmişken `23.0.1` girilirse):
  `validate` job summary'sine onay mesajı yazar
  (*"v23.0.2 canlıda, v23.0.1 üzerinden v23.0.3 alınacak. Onaylıyor
  musunuz?"* — referansın FINAL'i yoksa "canlıda" yerine *"kesilmiş (RC,
  henüz release edilmedi)"* ifadesi kullanılır) ve `approve-stale-base`
  job'ı `hotfix-approval` environment'ının required reviewer'ı onay verene
  kadar bekler.
  - **Onay** → sıra genel `cut-approval` kapısına geçer; o da onaylanırsa
    cut, base serisinin en yüksek kesiminin patch+1'i ile devam eder
    (`23.0.1` → `v23.0.3`, mevcut `v23.0.2` ile çakışmaz).
  - **Red** → workflow durur, hiçbir repoya yazılmaz.

İki kapının ayrı olması, gerekirse ileride farklı reviewer/policy atanmasına
izin verir. Mevcut policy: her iki kapıda da **dar reviewer listesi**
(release sorumluları) ve **self-review serbest** (prevent self-review
kapalı) — cut'ı alan kişi validate özetini inceleyip kendisi onaylayabilir.

### Yapı

```
.github/workflows/
├── cut-release.yml   # validate → approve-cut → cut → scripts/cut.sh
└── cut-hotfix.yml    # validate → (eski base ise approve-stale-base) → approve-cut → cut
scripts/
└── cut.sh            # tüm cut mantığı (MODE=release|hotfix) — tek kaynak
```

Mantığın tamamı `scripts/cut.sh`'ta: iki workflow arasında kopya kod yok,
script lokalde de çalıştırılıp test edilebilir (shellcheck temiz):

```bash
export GH_TOKEN=... OWNER=yusufbingol REPOS="git_deneme git_deneme_2 git_deneme_3"
MODE=release VERSION=24.0.0 DRY_RUN=true ./scripts/cut.sh
MODE=hotfix  BASE_VERSION=23.0.1 DRY_RUN=true ./scripts/cut.sh
# Eski base'den bilinçli cut (workflow'da bunun yerine environment approval var):
MODE=hotfix  BASE_VERSION=22.0.1 ALLOW_STALE_BASE=true DRY_RUN=true ./scripts/cut.sh
```

---

## 3. Kural Tablosu (konsolide)

### Ortak — girdi/format kuralları

| Kural | Davranış |
|---|---|
| Format `X.Y.Z`, `v`'siz, başında sıfırsız | Aksi halde red (`v23.0.0`, `abc`, `23.0`, `023.0.0`, boş → red) |
| Release'de sadece `X.0.0` | `23.1.0`, `23.0.1` girilirse red (minor/patch cut kapsam dışı) |
| İki fazlı validate→execute | Önce 3 repoda **tüm** validasyonlar (yazma yok); tek ihlal → hiçbir repoya dokunulmaz |
| `dry_run: true` | Sadece validasyon + plan raporu, push yok, **onay istenmez** |
| Bozuk tag'ler (sıfır önekli, örn. `v23.0.08-FINAL`) | Yok sayılır — versiyon hesaplarına girmez (octal koruması) |

### Cut Release — akış: `validate → approve-cut → cut`

| Durum | Davranış |
|---|---|
| Girilen major = en yüksek **RC** major + 1 | ✅ Normal cut (`main` HEAD'inden branch + RC tag) |
| Girilen major > en yüksek RC major + 1 (örn. `99.0.0`) | ❌ Red — typo koruması |
| Girilen major < en yüksek RC major (geriye dönük) | ❌ Red — "yeni cut için v(en yüksek+1).0.0 kullanın" |
| Aynı versiyon tekrar, `main` değişmemiş | ⏭️ İdempotent skip (zararsız re-run) |
| Aynı versiyon tekrar, `main` ilerlemiş | ❌ Red — "bir sonraki versiyonu girin" |
| Hiç RC yoksa (ilk cut) | ✅ Serbest |
| Gerçek run | 🔔 **`cut-approval`** onayı gerekir (validate özetiyle) |

### Cut Hotfix — akış: `validate → [approve-stale-base] → approve-cut → cut`

| Durum | Davranış |
|---|---|
| Base branch (`vX.Y.Z`) yok | ❌ Red |
| Base'in `-FINAL` tag'i yok | ❌ Red (hard-fail) — release edilmemiş versiyondan hotfix alınamaz |
| FINAL sonrası base branch'e commit pushlanmış | ❌ Red (hard-fail) — release edilmemiş kod içerir |
| Base = en güncel kesim, üst seride FINAL yok | ✅ Normal hotfix: `patch+1` (örn. `23.0.1` → `v23.0.2`) |
| **Base'in kendi serisinde daha yeni kesim var** (RC *veya* FINAL, örn. `v23.0.2-RC` varken base `23.0.1`) | ⚠️ **`hotfix-approval`** onayı; onaylanırsa serinin en yüksek kesimi+1 (→ `v23.0.3`) |
| **Üst seride release edilmiş (FINAL) versiyon var** (örn. `v23.0.1-FINAL` canlıyken base `22.0.1`) | ⚠️ **`hotfix-approval`** onayı; onaylanırsa base'in kendi serisinde devam (→ `v22.0.2`) |
| Üst seride *sadece RC* var (örn. `v24.0.0-RC`) | ✅ Eski base sayılmaz — yeni major henüz canlıda değilken önceki serinin hotfix'i normal akıştır |
| Onay mesajı ifadesi | Referans FINAL'liyse *"vX canlıda"*, sadece RC'liyse *"vX kesilmiş (RC, henüz release edilmedi)"* |
| Gerçek run | 🔔 Eski base'de **iki onay** (önce `hotfix-approval`, sonra `cut-approval`); güncel base'de sadece `cut-approval` |

### Onay kapıları

| Environment | Ne zaman | Policy |
|---|---|---|
| `cut-approval` | Her gerçek cut (release + hotfix), dry-run hariç | Dar reviewer listesi, self-review serbest |
| `hotfix-approval` | Sadece eski base'den hotfix | Dar reviewer listesi, self-review serbest |
| Herhangi bir red | Workflow durur, hiçbir repoya yazılmaz | — |

### Operasyonel güvenlik ağları

| Durum | Davranış |
|---|---|
| Yeni branch/tag zaten var, aynı SHA'da | ⏭️ Skip (idempotent re-run — kısmi başarısızlık telafisi) |
| Yeni branch/tag zaten var, **farklı** SHA'da | ❌ Red — elle inceleme istenir |
| Paralel çift tetikleme (aynı versiyon/base) | Concurrency grubu ile serileşir |
| SHA sabitleme | Validasyon anında okunur; push aynı SHA ile yapılır (arada `main` ilerlese bile) |
| Tag tipi | Annotated — GitHub Desktop'ın ürettiğiyle aynı (`git describe` vb. tooling sorunsuz) |
| Audit | Push'lar bot kimliğiyle; job summary'de tetikleyen kişi |

---

## 4. Handle EDİLMEYEN Durumlar (bilinen sınırlar)

| Durum | Neden / Etki |
|---|---|
| **Niyet hatası:** hotfix'te base yerine hedef versiyonu girmek (base `23.0.1` yerine `23.0.2` girmek) ve `v23.0.2` tesadüfen geçerli bir base ise | Script niyeti bilemez; teknik olarak geçerli bir cut oluşur. Mitigasyon: summary'de "Base → Yeni" net gösteriliyor + dry_run alışkanlığı. Kalıcı çözüm: dropdown (bkz. Sonraki Fazlar) |
| **Execute fazı atomik değil:** push sırasında beklenmedik hata (token, ruleset, network) → bazı repolar kesilmiş kalabilir | İdempotent re-run ile telafi edilir; "asla yarım kalmaz" değil, "yarım kalırsa güvenle tamamlanır" garantisi |
| **Farklı versiyonlar paralel tetiklenirse** teorik yarış penceresi | Concurrency grubu versiyon bazlı; pratikte guard'lar yakalar, risk ihmal edilebilir |
| **Lokal çalıştırmada `DRY_RUN=True`** (büyük T) gerçek run olur | Sadece lokal kullanım footgun'ı; Actions boolean input'u her zaman küçük harf üretir |
| **Eski base cut'ında versiyon şeması** | Onaylı eski base cut'ı normal `vX.Y.Z` şemasında devam eder (en yüksek FINAL+1); müşteri-özel suffix/4. segment şeması hâlâ açık — bkz. Açık Sorular #1 |

---

## 5. Kurulum (gerçek ortama geçiş)

1. **Orchestration reposu:** bu yapı `assistbox-mobile-release` gibi bir repoya taşınır.
2. **GitHub App** (`assistbox-release-bot`): izin `Contents: Read & Write`,
   sadece 3 repo + orchestration reposuna install. `APP_ID` /
   `APP_PRIVATE_KEY` secret'ları eklenir, workflow'lardaki
   `create-github-app-token` adımı açılır.
   *(Test ortamında fine-grained PAT `RELEASE_BOT_TOKEN` kullanılıyor.)*
3. **Ruleset bypass:** repolarda `v*` tag/branch protection ruleset'i varsa
   GitHub App bypass listesine eklenmeli — yoksa cut push'ları reddedilir.
4. **FINAL backfill:** release edilmiş ama FINAL tag'i eksik geçmiş
   versiyonlar taranıp elle FINAL atılmalı (örn. v6.9.7, v6.9.9) — aksi halde
   bu versiyonlara hotfix gerektiğinde guard yanlış alarm verir.
5. **Onay environment'ları:** orchestration reposunda Settings →
   Environments altında iki environment oluşturulur. Her ikisinde de aynı
   policy: **required reviewers = dar liste** (release sorumluları, en az
   1 kişi zorunlu — yoksa approval job'ı beklemeden geçer) ve **prevent
   self-review = kapalı** (cut'ı alan kişi validate özetini inceleyip
   kendisi onaylayabilir).
   - **`cut-approval`:** her gerçek cut'ın genel onay kapısı.
   - **`hotfix-approval`:** eski base'den hotfix'in ek onay kapısı.
6. Workflow'lardaki `OWNER` / `REPOS` değerleri gerçek repolarla güncellenir.

---

## 6. Test Durumu

`scripts/cut.sh` lokalde gerçek GitHub API ile uçtan uca test edildi
(2026-08-05). Dummy repolarda test artefaktı olarak `v23.0.0` / `v23.0.1`
branch'leri + RC/FINAL tag'leri duruyor (hepsi annotated).

Geçen senaryolar (17):
- Release: dry-run, gerçek cut, idempotent re-run, format/leading-zero
  guard'ları, ileri ve geri major guard'ları
- Hotfix: FINAL yokken red, mutlu yol (v23.0.0 → v23.0.1), zincir guard'ı,
  FINAL-HEAD tutarlılık guard'ı (hard-fail), format guard'ları
- Annotated tag tipi API'den doğrulandı (`object.type=tag`)

---

## 7. Sonraki Fazlar

1. **Hotfix input'unu dropdown yapma (niyet hatası çözümü):**
   GitHub Actions'ta `workflow_dispatch` dropdown'ı (`type: choice`) **sadece
   statik liste** destekler — seçenekler API'den dinamik doldurulamaz, YAML
   dosyasına yazılı olmak zorunda. Seçenekler:
   - *Self-updating workflow:* her cut/FINAL sonrası bir bot commit'i,
     workflow YAML'ındaki `options:` listesini günceller (son N release
     branch'i, yeniden eskiye). Teknik olarak mümkün, orta karmaşıklık.
   - *Alternatif:* dropdown yerine mevcut serbest metin + guard'lar
     (bugünkü durum) — guard'lar zaten yanlış base'lerin büyük kısmını
     yakalıyor.
   - Ekip kararı bekliyor: self-update karmaşıklığına değer mi?
2. **`tag-final.yml`:** production release sonrası FINAL tag'leme workflow'u
   (aynı validate→execute desenli).
3. **Build tetikleme:** cut sonrası assistbox-ios / assistbox-android için
   Jenkins/Bitrise `app_release` tetiklemesi.
4. **Jira entegrasyonu:** "Assistbox Mobile Release vX.Y.Z" task'ının
   otomatik oluşturulması (team/label/assignee).
5. **Slack bildirimi:** cut sonucu özeti.
6. **Onay katmanı:** ✅ **tamamlandı** — genel `cut-approval` kapısı tüm
   gerçek cut'ların execute fazını, `hotfix-approval` kapısı eski base
   hotfix'lerini korur (bkz. Kullanım → Onay akışı).

---

## 8. Açık Sorular

1. **Eski versiyona müşteri-özel hotfix — versiyon şeması:** Eski base'den
   cut artık **environment approval ile destekleniyor** (yukarıda anlatıldı):
   onay sonrası yeni versiyon serinin en yüksek FINAL'inin patch+1'i olur
   (canlıda `v22.0.2` varken `v22.0.1` base'inden `v22.0.3` kesilir — normal
   şemada, çakışmasız). Açık kalan kısım: müşteri-özel kalıcı bir ayrım
   gerekirse şema adayları 4. segment (`v22.0.1.1`) veya suffix
   (`v22.0.1-cust-acme.1`). Store versiyonlama ve CI guard'larıyla
   etkileşimi düşünülmeli.
2. **Minor cut (`vX.Y.0`, Y>0) semantiği:** main'den mi, release
   branch'inden mi kesilecek? Netleşince workflow'a eklenecek.
3. **FINAL backfill kapsamı:** geçmişte hangi versiyonların FINAL'i eksik,
   hangileri gerçekten release edildi? Go-live öncesi bir kerelik tarama.

---

> **Teknik not:** GitHub API'de ref yazımından hemen sonra okuma,
> read-replica gecikmesiyle eski değer döndürebilir. Cut akışı bundan
> etkilenmez (SHA bir kez okunur, aynı SHA ile yazılır) ama testlerde peş
> peşe yaz-oku yaparken birkaç saniye beklemek gerekebilir.
