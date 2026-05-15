# نظام إدارة التوصيل — هيكل المشروع

## 📁 الهيكل الكامل

```
delivery/
├── auth.html              ← صفحة تسجيل الدخول
├── app.html               ← الـ Shell الرئيسي (sidebar + iframe)
├── driver.html            ← بورتال الطيار (موبايل)
├── delivery-style.css     ← CSS مشترك لكل الصفحات
├── supabase-config.js     ← إعدادات Supabase
├── permissions.js         ← الصلاحيات والأدوار
│
└── pages/                 ← صفحات تُحمَّل داخل الـ iframe
    ├── overview.html      ← نظرة عامة (KPIs + charts + latest orders)
    ├── orders.html        ← إدارة الطلبات (كاردات + فلاتر + مودالات)
    ├── trips.html         ← الرحلات (إنشاء + تتبع)
    ├── drivers.html       ← الطيارين (أداء + إدارة)
    ├── reports.html       ← التقارير (charts + export CSV)
    ├── users.html         ← المستخدمون (admin only)
    └── permissions.html   ← عرض الصلاحيات
```

## 🔐 الأدوار والصلاحيات

| الدور | الطلبات | الرحلات | التقارير | المستخدمون |
|-------|---------|---------|---------|------------|
| Admin | ✅ كاملة | ✅ | ✅ | ✅ |
| مشرف | ✅ | ✅ | ✅ | ❌ |
| كاشير | عرض فقط | ❌ | مالية | ❌ |
| صيدلي | عرض فقط | ❌ | ❌ | ❌ |
| طيار | رحلاته فقط | ❌ | ❌ | ❌ |

## 🔄 تدفق العمل

```
تسجيل دخول (auth.html)
     ↓
   طيار? ──→ driver.html (بورتال الطيار)
     ↓
   app.html (الداشبورد)
     ├── overview.html   (iframe)
     ├── orders.html     (iframe)
     ├── trips.html      (iframe)
     ├── drivers.html    (iframe)
     ├── reports.html    (iframe)
     ├── users.html      (iframe - admin only)
     └── permissions.html (iframe - admin only)
```

## 📋 حالات الطلب

`pending` → `picked` → `delivered` → `completed`
                                   ↘ `cancelled`
           `postponed` ←──────────

## 🗄️ Supabase Tables

- `orders` — الطلبات
- `users` — المستخدمون
- `trips` — الرحلات
- `trip_orders` — ربط الطلبات بالرحلات
- `branches` — الفروع

## ⚡ ميزات كل صفحة

### overview.html
- KPI cards (جاهز، في الطريق، تم التسليم، مكتمل، متأخر، إيرادات)
- Donut chart توزيع الحالات
- Bar chart الطلبات بالساعة
- صف الطيارين النشطين
- جدول آخر الطلبات

### orders.html
- Grid كاردات الطلبات مع timers
- فلتر بالحالة / الطيار / البحث
- تعيين طيار، تأجيل، إلغاء، تعديل
- إضافة طلب يدوي
- Auto-refresh كل دقيقة

### trips.html
- إنشاء رحلة جديدة (اختيار طيار + طلبات)
- تتبع الرحلات الحالية
- إنهاء رحلة وتحويل الطلبات لـ completed

### drivers.html
- Grid بطاقات الطيارين مع الحالة
- جدول أداء اليوم
- إضافة / تفعيل / تعطيل طيار

### reports.html
- فلتر بالتاريخ (اليوم / أسبوع / شهر)
- KPIs: طلبات، مكتمل، ملغي، إيرادات، معدل إنجاز
- Bar chart يومي
- Pie chart الحالات
- أكثر المناطق طلبات
- ترتيب الطيارين
- تصدير CSV

### driver.html (موبايل)
- عرض رحلاته فقط
- تحديث حالة الطلب (تسليم / إنجاز)
- الإبلاغ عن مشكلة
- Auto-refresh كل 30 ثانية
