# Edge Functions — نسخة من Supabase

المشروع فيه **19 Edge Function** موجودة على Supabase Cloud بس. المجلد ده لتنزيلهم
للريبو عشان (أ) يبقى فيه نسخة لو المشروع ضاع، (ب) يتنشروا على أي استضافة تانية
بـ`supabase functions deploy`.

الشكل المتوقّع: `supabase/functions/<slug>/index.ts`

## القائمة الكاملة (19)
clever-action · swift-api · send-push · send-fcm · driver-poll · driver-mark ·
create-driver · set-driver-active · change-password · delivery-performance ·
apk-publish · db-backup · db-restore · trip-return-perf · eplus_proxy ·
eplus_sync · pharma_search · pharma_probe · pharma_sync

## اللي اتنزّل لحد دلوقتي
- `db-backup/index.ts`

## ⚠️ ملاحظة أمنية
`db-backup/index.ts` فيه `TRIGGER_TOKEN` **مكتوب صريح في الكود**
(`phlx_bkp_...`) — ونفس التوكن في أمر cron. أي حد يعرفه يقدر يشغّل النسخ
الاحتياطي. يُفضّل ينتقل لمتغيّر بيئة (`Deno.env.get`) ويتغيّر.
