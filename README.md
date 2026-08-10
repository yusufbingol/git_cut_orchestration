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
- Versiyon, mevcut en yüksek versiyonun major+1'i olmalıdır

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
  Onaylıyor musunuz?"); onay verilirse yeni versiyon base'in kendi serisinde,
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

### Hotfix'te eski base onay akışı

Cut Hotfix üç job'dan oluşur: `validate` → `approve-stale-base` → `cut`.

- **Güncel base** (serinin en yeni kesimi, üst seride FINAL yok):
  `approve-stale-base` skip edilir, cut doğrudan devam eder — davranış
  eskisiyle aynı.
- **Eski base** (örn. `v23.0.2` kesilmişken `23.0.1` girilirse):
  `validate` job summary'sine onay mesajı yazar
  (*"v23.0.2 canlıda, v23.0.1 üzerinden v23.0.3 alınacak. Onaylıyor
  musunuz?"*) ve `approve-stale-base` job'ı `hotfix-approval`
  environment'ının required reviewer'ı onay verene kadar bekler.
  - **Onay** → cut, base serisinin en yüksek kesiminin patch+1'i ile devam
    eder (`23.0.1` → `v23.0.3`, mevcut `v23.0.2` ile çakışmaz).
  - **Red** → workflow durur, hiçbir repoya yazılmaz.

Böylece yanlışlıkla eski branch üzerinden cut alınması engellenir; bilinçli
(müşteri-özel) durumlarda ise ikinci bir göz onayıyla yol açılır.

### Yapı

```
.github/workflows/
├── cut-release.yml   # ince katman: input + concurrency → scripts/cut.sh
└── cut-hotfix.yml    # validate → (eski base ise approval) → cut → scripts/cut.sh
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

## 3. Handle Edilen Hatalar ve Guard'lar

### Girdi hataları

| Hatalı giriş | Davranış |
|---|---|
| `23.1.0`, `23.0.1` (normal cut'ta) | Reddedilir — normal cut sadece `X.0.0` |
| `v23.0.0`, `abc`, `23.0`, boş | Format regex'i reddeder |
| `023.0.0`, `23.0.01` (başında sıfır) | Reddedilir (isim kirliliği/octal riski) |
| `99.0.0` (ileri sıçrama) | Reddedilir — en fazla mevcut en yüksek major+1 |
| `5.0.0` (geriye dönük, en son v23 iken) | Reddedilir — "yeni cut için v24.0.0 kullanın" |
| Aynı versiyonu tekrar girmek (main değişmemiş) | Zararsız — idempotent skip |
| Aynı versiyonu tekrar girmek (main ilerlemiş) | Reddedilir + "bir sonraki versiyonu girin" ipucu |

### Süreç guard'ları (hotfix)

| Durum | Davranış |
|---|---|
| Base branch mevcut değil | Reddedilir |
| Base'in `-FINAL` tag'i yok (release edilmemiş) | Reddedilir (hard-fail) |
| FINAL'den sonra base branch'e commit pushlanmış | Reddedilir (hard-fail) — hotfix release edilmemiş kod içeremez |
| Base'den daha yeni kesim/FINAL varken eski base | **Environment approval** istenir — onaylanırsa serinin en yüksek kesiminin patch+1'i ile devam, reddedilirse durur |
| Yeni branch/tag başka SHA'da zaten var | Reddedilir — elle inceleme istenir |

### Operasyonel güvenlik ağları

- **İki fazlı validate→execute:** kısmi cut riski minimum; hata → sıfır yazma
- **SHA validasyon anında sabitlenir:** validasyon ile push arasında main'e
  commit gelse bile branch ve tag doğrulanan SHA'dan oluşur
- **İdempotent re-run:** kısmi başarısızlıkta (örn. network) aynı input ile
  güvenle yeniden çalıştırılır; tamamlanan repolar skip edilir
- **Concurrency guard:** aynı versiyon için paralel çift tetikleme serileşir
- **Annotated tag:** GitHub Desktop'ın ürettiğiyle aynı tip — mevcut
  tag'lerle tutarlı (`git describe` vb. tooling sorunsuz)
- **Audit:** push'lar bot kimliğiyle, job summary'de tetikleyen kişi

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
5. **`hotfix-approval` environment'ı:** orchestration reposunda
   Settings → Environments → New environment → `hotfix-approval`.
   - **Required reviewers:** eski base'den cut'ı onaylayabilecek kişiler
     (örn. release sorumluları) eklenir — en az 1 kişi zorunlu, yoksa
     approval job'ı beklemeden geçer.
   - **Prevent self-review:** cut'ı tetikleyen kişinin kendi isteğini
     onaylayamaması isteniyorsa **açık** olmalı (önerilen); tek kişilik
     ekipte/testte kapalı bırakılabilir.
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
6. **Onay katmanı (opsiyonel):** eski base hotfix'i için environment
   approval **eklendi** (`hotfix-approval`); istenirse aynı desen tüm
   execute fazlarına genişletilebilir.

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
