-- fix_san_stock_swap.sql
-- تبديل مخزون سان ستيفانو يدويًا (نفس SQL عقدة Swap Tables في n8n + حارس أمان).
--
-- ليه: 2026-10-26 الـstaging بيتعبّى طازة كل نبضة لكن التبديل مابيحصلش،
-- فـstock_san متجمّد من 10-25 14:10 والشاشات بتقرا رصيد بايت.
-- التبديل كله ترانزاكشن واحدة: أي خطوة تقع = كل حاجة ترجع زي ما كانت.
--
-- التشغيل: SQL Editor على السحابة (rxtjoqulmgkkcohmgzgi)، نسخ ولصق كله مرة واحدة.

begin;

-- ① حارس: يوقّف قبل أي تعديل لو الـstaging ناقص أو أقدم من الحالي
do $g$
declare n_new int; n_old int; t_new timestamptz; t_old timestamptz;
begin
  select count(*), max(updated_at) into n_new, t_new from public.stock_san_staging;
  select count(*), max(updated_at) into n_old, t_old from public.stock_san;
  if n_new < n_old * 0.9 then
    raise exception 'وقّفت: staging فيه % صف والحالي % — ناقص أكتر من 10٪', n_new, n_old;
  end if;
  if t_new is null or t_new <= t_old then
    raise exception 'وقّفت: staging (%) مش أحدث من الحالي (%)', t_new, t_old;
  end if;
  raise notice 'الحارس تمام: % صف، آخر تحديث %', n_new, t_new;
end $g$;

-- ② التبديل بإعادة التسمية
alter table public.stock_san         rename to stock_san_old;
alter table public.stock_san_staging rename to stock_san;

-- ③ تسجيل تغيّرات الأسعار (تبويب «تغيّرات الأسعار» بيقرا من هنا)
insert into public.price_changes (branch, itm_code, itm_name_ar, company, old_price, new_price, diff)
select 'san', n.itm_code, n.itm_name_ar, n."Company_Name_Ar",
       nullif(o.itm_sell_price_big,'')::numeric,
       nullif(n.itm_sell_price_big,'')::numeric,
       nullif(n.itm_sell_price_big,'')::numeric - nullif(o.itm_sell_price_big,'')::numeric
  from public.stock_san n
  join public.stock_san_old o on o.itm_code = n.itm_code
 where nullif(n.itm_sell_price_big,'')::numeric is distinct from nullif(o.itm_sell_price_big,'')::numeric;

-- ④ إعادة ربط الـview بالجدول الجديد **قبل** حذف القديم (وإلا الحذف يرفض)
select public.rebind_v_stock_units_full();

-- ⑤ حذف القديم
drop table public.stock_san_old;

commit;

-- تأكيد بعد التنفيذ (لازم يطلع تاريخ النهاردة)
select count(*) as rows,
       max(updated_at) at time zone 'Africa/Cairo' as last_update
  from public.stock_san;
