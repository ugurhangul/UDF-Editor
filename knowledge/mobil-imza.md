# Mobil İmza — Geliştirici Rehberi

## Mobil İmza Nedir?

Mobil imza, Türkiye'de GSM operatörleri tarafından sunulan, SIM karta entegre bir **nitelikli elektronik imza** çözümüdür. 5070 sayılı Elektronik İmza Kanunu kapsamında yasal geçerliliği olan ıslak imza ile eşdeğer bir dijital imza yöntemidir.

---

## Nasıl Çalışır?

```
Kullanıcı işlem başlatır
       ↓
Uygulaman → Operatör API'sine istek gönderir (MSISDN ile)
       ↓
Operatör → Kullanıcının telefonuna imzalama isteği gönderir
       ↓
Kullanıcı → Ekranda özeti görür, PIN girer
       ↓
SIM kart → Kriptografik imzayı oluşturur
       ↓
Uygulaman → İmzalanmış veriyi alır ve doğrular
```

---

## Türkiye'deki Servis Sağlayıcılar

| Operatör | Servis Adı | API Türü |
|---|---|---|
| **Turkcell** | e-İmza / Mobil İmza | SOAP / REST |
| **Vodafone TR** | Mobil İmza | SOAP |
| **Türk Telekom** | Mobil İmza | SOAP |

Her operatörle **ayrı ayrı entegrasyon anlaşması** yapman gerekir.

---

## Teknik Entegrasyon Adımları

### 1. Operatörle Sözleşme
- İlgili operatörün kurumsal API portalına başvuru yapılır
- Test ortamı (sandbox) erişimi alınır
- Üretim ortamı için onay süreci işletilir

### 2. Temel API Akışı (SOAP örneği)

```xml
<!-- 1. İmza isteği başlat -->
<MobileSignatureInit>
  <MSISDN>905xxxxxxxxx</MSISDN>
  <Message>Ödeme onayı: 150 TL</Message>
  <DataToBeSigned>BASE64_HASH</DataToBeSigned>
  <TransactionID>unique-tx-id</TransactionID>
</MobileSignatureInit>

<!-- 2. İmza durumunu sorgula (polling) -->
<GetMobileSignatureStatus>
  <TransactionID>unique-tx-id</TransactionID>
</GetMobileSignatureStatus>
```

### 3. İmza Doğrulama

İmzalı veri `PKCS#7 / CMS` formatında döner. Doğrulama için:

```java
// Java örneği
CMSSignedData signedData = new CMSSignedData(signatureBytes);
SignerInformationStore signers = signedData.getSignerInfos();
// Sertifika zinciri doğrula → OCSP/CRL ile iptal kontrolü yap
```

---

## Dikkat Edilmesi Gereken Noktalar

**Güvenlik**
- İletişim her zaman **TLS 1.2+** üzerinden yapılmalı
- `TransactionID` tahmin edilemez, benzersiz olmalı (UUID v4)
- İmzalanacak veri hash'i kullanıcıya gösterilmeli

**UX**
- Kullanıcı PIN giriş ekranı **operatör tarafından** SIM'de açılır, senin uygulamana değil
- Timeout süresi genellikle **120 saniye**, bunu UI'da göster
- Hata kodlarını kullanıcı dostu mesajlara çevir

**Mevzuat**
- Kişisel veri (MSISDN) işleme için **KVKK** kapsamında aydınlatma metni zorunlu
- İşlem logları belirli süre saklanmalı

---

## Alternatif / Tamamlayıcı Çözümler

| Çözüm | Ne Zaman Tercih Edilir |
|---|---|
| **e-Devlet Kapısı API** | Kimlik doğrulama odaklıysa |
| **Nitelikli e-İmza (USB token)** | Masaüstü uygulamalarda |
| **e-İmza SaaS** (Turkcell, UATECH) | Çoklu operatör desteği istiyorsan |

---

Uygulamanın **hangi platforma** (iOS/Android/web) ve **hangi senaryoya** (login, sözleşme imzalama, ödeme onayı vb.) yönelik olduğunu söylersen daha spesifik yönlendirme yapabilirim.