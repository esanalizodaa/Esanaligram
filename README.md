# Esnaligram (iOS)

Resmi açık kaynak **Telegram-iOS** üzerine yama seti. Temel: `release-13.0.0` (commit `f1dd7a2`) — bkz. `UPSTREAM`.
Lisans: GPLv2/GPLv3 (Telegram-iOS ile aynı). Kaynak kodu açık kalmalıdır.

## Neler değişti
- **Sekmeler:** sadece **Sohbetler** (sol) ve **Profil** (sağ). Kişiler ve Aramalar sekmeleri kaldırıldı.
  Profil sekmesine **basılı tutunca hesap değiştirme** menüsü açılır (Telegram'ın kendi özelliği, korunuyor).
- **Çeviri butonu:** mesaj yazma çubuğunda, çıkartma (sticker) butonunun **solunda**.
  - **Dokun:** yazdığın metni DeepInfra `deepseek-ai/DeepSeek-V4-Flash-0731` ile çevirir. Tekrar dokunursan geri alır.
  - Türkçe yazdıysan karşı tarafın son mesajlarından dili otomatik bulur (`NLLanguageRecognizer`). Türkçe değilse Türkçeye çevirir.
  - Dil bulunamazsa dil seçme ekranı açılır; dili seç, sonra tekrar Çevir'e bas.
  - **Basılı tut:** hedef dil seçimi + **ek prompt** alanı.
  - Sistem prompt'u gömülü: `esnaligram/EsnaligramTranslate/Sources/EsnaligramPrompt.swift`.
- Uygulama adı: **Esnaligram**.
- Android sürümündeki AFK / otomasyon özellikleri **yok** (bilinçli olarak taşınmadı).

## DeepInfra anahtarı
Anahtar repoda **yok**. GitHub → Settings → Secrets and variables → Actions → **New repository secret**:
`DEEPINFRA_API_KEY` = anahtarın. Derleme sırasında uygulamaya gömülür.
Yerel derleme için `config/local.env` dosyası (git'e girmez): `DEEPINFRA_API_KEY=sk-di-...`
Not: IPA'yı açan biri anahtarı çıkarabilir; IPA'yı paylaşma.

## GitHub Actions ile derleme
1. github.com'da **boş, public** repo aç: `esanalizodaa/esnaligram-ios` (README ekleme).
2. Bu klasörü push et:
   ```
   git remote add origin https://github.com/esanalizodaa/esnaligram-ios.git
   git push -u origin main
   ```
3. `DEEPINFRA_API_KEY` secret'ını ekle.
4. **Actions** → *Build Esnaligram IPA (unsigned)* → **Run workflow**. İlk derleme uzun sürer (1–3 saat).
5. Bitince çalışmanın altındaki **Artifacts** kısmından `Esnaligram-ipa-N` zip'ini indir, içinden `Esnaligram.ipa` çıkar.

## MacBook'ta yerel derleme
Xcode 26.6 (bkz. upstream `versions.json`), sonra: `./scripts/build-local.sh`

## iPhone'a kurulum (Sideloadly, ücretsiz Apple ID)
1. Windows/Mac'e **Sideloadly** kur (sideloadly.io), Windows'ta iTunes + iCloud'un web sürümünü kur.
2. iPhone'u kabloyla bağla, "Bu bilgisayara güven" de.
3. Sideloadly'de IPA'yı seç, Apple ID'ni yaz.
4. **Advanced options**: *Bundle ID* = `com.esnaligram.app` (benzersiz kimlik), *Remove app extensions* işaretle
   (ücretsiz hesap en fazla 3 uygulama/10 kimlik izni verir; uzantılar bildirim/paylaşım içindir).
5. **Start**. iPhone'da: Ayarlar → Genel → VPN ve Cihaz Yönetimi → Apple ID'ne **Güven**.
   iOS 16+ için: Ayarlar → Gizlilik ve Güvenlik → **Geliştirici Modu** aç.
6. Ücretsiz Apple ID ile imza **7 gün** geçerli; 7 günde bir Sideloadly ile tekrar kur (veriler kalır).
   Ücretli Apple Developer hesabı (yıllık 99$) ile 1 yıl geçerli olur.

## Bilinen sınırlar
- Kod Linux'ta yazıldı, henüz derlenmedi; ilk CI derlemesinde küçük derleme hataları çıkabilir.
- Push bildirimleri sideload'da çalışmaz (Telegram'ın APNs sertifikası gerekir).
- Nagram (nconfig) ayarlarının iOS karşılığı yok; taşınmadı (Telegram-iOS ile Android kod tabanı tamamen farklı).
