# nginx قدّام سوبابيز الذاتي — إعداد لازم

**الملف على السيرفر:** `/etc/nginx/sites-available/supabase.ebrahimhamdy.com`
**السلسلة:** المتصفح ← Cloudflare ← nginx ← `127.0.0.1:8000` (بوابة سوبابيز) ← PostgREST

---

## المشكلة اللي خلّتنا نكتب ده

**2026-09-19 — شاشة الطلبات مابتفتحش على السيرفر، وشغّالة على السحابة.**

الأعراض في المتصفح: طلبات `trip_orders` بترجّع **502**، و`preflight` لنفس الرابط بيرجّع **200**.

التشخيص خطوة بخطوة:

| المستوى | النتيجة |
|---|---|
| بوابة سوبابيز الداخلية `127.0.0.1:8000` | ✅ **200** ورد سليم `[]` |
| السيرفر مباشرة (من غير Cloudflare) | ❌ 502 — وصفحة الخطأ مكتوب فيها **nginx** |
| عبر Cloudflare | ❌ 502 |

والسطر الحاسم في `/var/log/nginx/error.log`:

```
upstream sent too big header while reading response header from upstream
```

**السبب:** سوبابيز بيرجّع هيدر `Content-Location` فيه **نسخة من الاستعلام كله**. شاشة الطلبات بتسأل عن ١٥٠ طلب مرة واحدة، فالاستعلام ~٦ كيلوبايت — والهيدر اللي راجع بنفس الحجم. حاجز nginx الافتراضي للهيدرات **٤ كيلوبايت**، فبيرفض **رد سليم** ويطلّع 502.

ليه مابانش على السحابة؟ لأن بوابة سوبابيز السحابية حاجزها أوسع.

> 💡 الدرس: 502 هنا ماكانتش معناها «سوبابيز وقع» — كانت معناها «الوسيط رفض رد سليم». ابدأ التشخيص دايمًا من جوّه لبرّه: البوابة الداخلية، ثم السيرفر مباشرة، ثم Cloudflare.

---

## الإعداد المطلوب

جوّه بلوك `server` بتاع سوبابيز:

```nginx
server {
    server_name supabase.ebrahimhamdy.com;
    client_max_body_size 50M;

    # سوبابيز بيرجّع هيدر Content-Location فيه الاستعلام كله،
    # وده بيعدّي حاجز nginx الافتراضي (4k) فيطلّع 502 على رد سليم.
    proxy_buffer_size           64k;
    proxy_buffers               8 64k;
    proxy_busy_buffers_size     128k;
    # وده للروابط الطويلة نفسها (كانت بتطلّع 414 فوق 8k)
    large_client_header_buffers 8 64k;

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;       # ضروري للـRealtime
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
    # … شهادة Certbot
}
```

**التطبيق:** `nginx -t` الأول (بيفحص الصياغة)، وبعدين `systemctl reload nginx` — **reload مش restart**، يعني من غير أي قطع للخدمة.

**التأكد إنه محمّل فعلًا** (مش بس مكتوب في ملف مش مستعمل):

```bash
nginx -T | grep -c "proxy_buffer_size           64k"   # لازم 1
```

---

## ⏳ الحل الجذري — لسه مطلوب

الإعداد ده بيوسّع الحاجز، بس **مابيحلّش أصل المشكلة**: الشاشة بتحط ١٥٠ معرّف في رابط واحد، والرابط بيكبر مع البيانات.

الأرقام اللي قسناها:

| عدد المعرّفات | طول الرابط | النتيجة قبل الإصلاح |
|---|---|---|
| 150 | ~5.6 ألف حرف | 502 (الهيدر الراجع) |
| 300 | ~11 ألف | 414 من nginx |
| 600 | ~22 ألف | **520 من Cloudflare** — برّه سيطرتنا |

يعني حتى مع nginx مظبوط، فيه سقف عند Cloudflare مش بإيدنا. **الحل الدائم:** الشاشات تقسّم على دفعات أصغر (٥٠ بدل ١٥٠)، أو تستعمل RPC بترسل القايمة في **جسم** الطلب مش في الرابط.

الأماكن المعروفة اللي بتبني `in.(...)` من قايمة:

| الملف | السطر | الحجم الحالي |
|---|---|---|
| `delivery/pages/orders.html` | 343 · 446 | ١٥٠ |
| `shift_history.html` | 307 | حسب الفترة |
| `api.js` | 120 | قايمة حالات (صغيرة) |

⚠️ ده بيتطبّق على **الريبوهين** — البرودكشن معرّض لنفس السقف لما الطلبات تزيد.
