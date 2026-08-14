# Viento Market

Viento Market'in statik mağaza ve yönetim paneli kaynağıdır. Vercel üzerinde yayınlanır; katalog, sipariş, müşteri hesabı, bülten ve hizmet talepleri Supabase ile saklanır.

## Kontroller

```bash
npm test
npm run check
```

## Canlı sistem sınırları

- Ödeme adımı test modundadır ve gerçek tahsilat yapmaz.
- Trendyol, Hepsiburada ve Amazon satıcı API'leri bağlanana kadar senkronizasyon devre dışıdır.
- Gerçek zamanlı ziyaretçi/dönüşüm ölçümü için ayrı bir analiz sağlayıcısı gerekir.
- E-posta otomasyonu bağlanana kadar terk edilmiş sepet ekranı yalnızca e-posta taslağı açar.

## Veritabanı

Yeni şema değişiklikleri `supabase/migrations` altında tutulur. Halka açık tablolarda RLS zorunludur.
