-- ═══════════════════════════════════════════════════════════════════
-- الفرع الرابع: السيوف
-- ═══════════════════════════════════════════════════════════════════
-- اتطبّق على السحابة 2026-09-24. السيرفر الذاتي لسه.
--
--   الاسم            السيوف
--   الكود            seyouf   →  جدول stock_seyouf
--   اسم المخزن في eplus  «السيوف» (نفس الاسم، مش زي باقي الفروع)
--   بادئة الشكل العريض   f     →  أعمدة f_h · f_q · f_p
--                              (m/s/b محجوزين، و s بتاعة سان)
--   سيرفر eplus      eplus3
--
-- ⚠️ الفخ اللي اتفادى: الـswap في n8n بيبدأ بـ
--       alter table stock_seyouf rename to stock_seyouf_old
--    فلو الجدول مش موجود، **أول تشغيل للمزامنة بيفشل**. عشان كده
--    بنعمله فاضي هنا بنفس بنية باقي الفروع.
--
-- ═══ اللي اتعمل تلقائي من غير تدخّل ═══════════════════════════════
--   الست دوال المتربطة بـbranches (item_lookup · item_balance ·
--   get_shortages · get_stock_limits · get_jard_items · get_jard_stale)
--   شغّالة على السيوف من أول ما الصف اتضاف — ترحيلات 39-43.
--   ensure_branch_partitions()  → قسم السيوف في الجدول الموحّد
--   sync_stock_flat_columns()   → عمود f في جدول الظل
--   branches.js                 → قوايم الفروع في كل الشاشات
-- ═══════════════════════════════════════════════════════════════════

insert into public.branches (name, code, aliases, is_active, sort_order)
values ('السيوف', 'seyouf', array['السيوف'], true, 4)
on conflict (name) do update
  set code = excluded.code, aliases = excluded.aliases, is_active = true;

create table if not exists public.stock_seyouf (like public.stock_san including all);
alter table public.stock_seyouf enable row level security;
revoke all on public.stock_seyouf from anon, authenticated;

insert into public.stock_flat_prefix(branch_code, prefix) values ('seyouf','f')
on conflict (branch_code) do nothing;

do $$ begin
  if not exists (select 1 from information_schema.columns
                  where table_schema='public' and table_name='stock_flat' and column_name='f_h') then
    alter table public.stock_flat add column f_h boolean, add column f_q numeric, add column f_p numeric;
  end if;
end $$;

-- refresh_stock_flat · get_stock_summary · rebind_v_stock_units_full
-- اتعدّلوا بإضافة السيوف. النص الكامل للتلاتة:
--   select pg_get_functiondef('public.refresh_stock_flat()'::regprocedure);
--   select pg_get_functiondef('public.get_stock_summary()'::regprocedure);
--   select pg_get_functiondef('public.rebind_v_stock_units_full()'::regprocedure);
-- (اتحطّوا كاملين وقت التنفيذ — مش متكررين هنا عشان الملف يفضل مقروء.
--  دول آخر 3 دوال فيهم خريطة فروع بالإيد؛ التوحيد بيلغيهم.)

select public.rebind_v_stock_units_full();

-- إجبار إعادة بناء stock_flat في دورة الكرون الجاية عشان أعمدة f تتملى
update public.stock_flat_meta set src_max = null where id = 1;

-- ═══ الفحص بعد التنفيذ (اتعمل 2026-09-24) ══════════════════════════
--   الفروع              المعمورة/mamora · سان ستيفانو/san · سيدى بشر/bishr · السيوف/seyouf
--   stock_seyouf        موجود · 0 صف (لحد ما n8n يشتغل)
--   أعمدة stock_flat    f_h · f_q · f_p
--   branch_code_of      'السيوف' → seyouf
--   views على المخزون   0  ← لازم تفضل صفر، غير كده المزامنة هتقف
--
-- ═══ الباقي ════════════════════════════════════════════════════════
--   n8n: نسخة ورك فلو + مسار get_balance على eplus3
--   الشاشتين: inventory_management.html و medicine_orders.html يقروا
--             المفتاح 'f' من get_stock_summary (بعد ما يبقى فيه بيانات)
-- ═══════════════════════════════════════════════════════════════════
