-- ٢٠٢: تصنيف «مستلزمات طبية» (sup) + تعيين الشركات للتصنيفات من الشاشة
--
-- الليه: فيه مدير مشتريات مخصّص للمستلزمات، ومحتاج تبويب طلبيات خاص بيه.
-- المشكلة إن التصنيف دلوقتي **مستنتج** مش مخزّن:
--     item_category(co, med) = ورقيات→paper · med=1→med · غير كده→cos
-- يعني «ورقيات» بقت تصنيف لمجرد إن فيه شركة اسمها كده محفور في الدالة.
-- لو عملنا «مستلزمات» بنفس الطريقة هتبقى محفورة تاني، والمطلوب إن
-- الشركات تتحدد من الشاشة.
--
-- الحل: جدول company_category يعيّن الشركة لتصنيف، وitem_category تقرا
-- منه الأول وترجع للمنطق القديم لو الشركة مش معيّنة. كده «ورقيات»
-- المحفورة بقى ليها بديل من البيانات كمان، من غير ما نكسر أي حاجة قايمة.
--
-- ⚠️ الدالة كانت IMMUTABLE وبقت STABLE لأنها بقت تقرا جدول. اتأكدنا إن
-- مفيش فهرس ولا عمود محسوب ولا view معتمد عليها، فالتحويل آمن. وحطّينا
-- مفتاح أساسي على company عشان القراءة تبقى فهرسية — الدالة بتتنادى
-- صف‑بصف في ٤ دوال (get_consumption_rates, get_min_stock_alerts,
-- get_purchase_orders, get_purchase_surplus_return_impl).
--
-- ⚠️ القيود: category_rate_tiers و branch_calc_settings الاتنين عندهم
-- CHECK مقيّد بـ med/cos/paper، فلازم يترخّوا الأول وإلا إدراج sup هيقع.
--
-- الإعدادات الجديدة **منسوخة من الكوزمو** بقصد: أول ما المالك يعيّن
-- شركة، سلوك أصنافها مايتغيّرش فجأة — يظبط الشرائح بعدين وهو مطمّن.

begin;

/* ═══ ١) جدول التعيين ═══ */
create table if not exists public.company_category (
  company     text primary key,
  category    text not null,
  assigned_by text,
  assigned_at timestamptz not null default now()
);
comment on table public.company_category is
  'تعيين شركة eplus لتصنيف. item_category بتقرا منه قبل المنطق المحفور.';

/* ═══ ٢) ترخية القيود قبل أي إدراج لـsup ═══ */
alter table public.category_rate_tiers   drop constraint if exists category_rate_tiers_category_check;
alter table public.branch_calc_settings  drop constraint if exists branch_calc_settings_category_check;
alter table public.company_category      drop constraint if exists company_category_category_check;

alter table public.category_rate_tiers
  add constraint category_rate_tiers_category_check
  check (category = any (array['med','cos','paper','sup']));
alter table public.branch_calc_settings
  add constraint branch_calc_settings_category_check
  check (category = any (array['med','cos','paper','sup']));
alter table public.company_category
  add constraint company_category_category_check
  check (category = any (array['med','cos','paper','sup']));

/* ═══ ٣) التصنيف بقى يقرا من الجدول ═══ */
create or replace function public.item_category(p_co text, p_med integer)
returns text language sql stable as $function$
  select coalesce(
    (select cc.category from public.company_category cc
      where cc.company = btrim(coalesce(p_co, ''))),
    case
      when btrim(coalesce(p_co, '')) = 'ورقيات' then 'paper'
      when coalesce(p_med, 0) = 1                then 'med'
      else                                            'cos'
    end);
$function$;

/* ═══ ٤) إعدادات الفروع للتصنيف الجديد — نسخة من الكوزمو ═══ */
insert into public.branch_calc_settings
  (branch, category, rate_source, source_branch, surplus_mode,
   min_stock_surplus, active, reorder_ratio, min_immediate)
select b.branch, 'sup', b.rate_source, b.source_branch, b.surplus_mode,
       b.min_stock_surplus, b.active, b.reorder_ratio, b.min_immediate
  from public.branch_calc_settings b
 where b.category = 'cos'
   and not exists (select 1 from public.branch_calc_settings z
                    where z.branch = b.branch and z.category = 'sup');

insert into public.category_rate_tiers (category, branch, rate_min, active_min, multiply)
select 'sup', t.branch, t.rate_min, t.active_min, t.multiply
  from public.category_rate_tiers t
 where t.category = 'cos'
   and not exists (select 1 from public.category_rate_tiers z
                    where z.category = 'sup'
                      and z.rate_min = t.rate_min
                      and z.branch is not distinct from t.branch);

/* ═══ ٥) الصلاحيات ═══
   القراءة للمستخدم المسجّل؛ الكتابة من RPC محروس بس، مش مباشرة على الجدول
   (الذاتي بيدّي authenticated كل حاجة تلقائيًا فمحتاج revoke صريح). */
revoke all on table public.company_category from public, anon, authenticated;
grant select on table public.company_category to authenticated, service_role;
alter table public.company_category enable row level security;
drop policy if exists company_category_read on public.company_category;
create policy company_category_read on public.company_category for select to authenticated using (true);

/* ═══ ٦) RPC الحفظ — محروس بصلاحية تعديل شاشة الطلبيات ═══ */
create or replace function public.set_company_category(
  p_companies text[], p_category text)
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare v_n int := 0; v_user text;
begin
  perform public.require_page_edit('cosmo_order');

  if p_category is null or btrim(p_category) = '' then
    raise exception 'لازم تحدد التصنيف';
  end if;
  if p_category not in ('med','cos','paper','sup') then
    raise exception 'تصنيف غير معروف: %', p_category;
  end if;

  v_user := coalesce(nullif(btrim(current_setting('request.jwt.claims', true)::jsonb ->> 'full_name'), ''),
                     nullif(btrim(current_setting('request.jwt.claims', true)::jsonb ->> 'username'), ''),
                     'غير معروف');

  /* التعيين كامل لهذا التصنيف: اللي اتشال من القايمة يرجع لتصنيفه الطبيعي.
     بنمسح تعيينات التصنيف ده بس — مابنلمسش تعيينات التصنيفات التانية. */
  delete from public.company_category
   where category = p_category
     and company <> all (coalesce(p_companies, array[]::text[]));

  insert into public.company_category (company, category, assigned_by, assigned_at)
  select btrim(c), p_category, v_user, now()
    from unnest(coalesce(p_companies, array[]::text[])) c
   where btrim(coalesce(c,'')) <> ''
  on conflict (company) do update
    set category = excluded.category,
        assigned_by = excluded.assigned_by,
        assigned_at = excluded.assigned_at;
  get diagnostics v_n = row_count;

  return jsonb_build_object('ok', true, 'saved', v_n, 'category', p_category);
end
$function$;

revoke all on function public.set_company_category(text[], text) from public, anon;
grant execute on function public.set_company_category(text[], text) to authenticated, service_role;

commit;

/* ═══ ٧) قايمة الشركات للنافذة ═══
   من الكتالوج كله مش من نتائج الحساب — شركة مستلزمات ممكن ماتكونش ظهرت
   في أي تبويب اتحسب لسه، فلازم تبان عشان تقدر تعيّنها. */
begin;

create or replace function public.get_company_catalog()
returns table (company text, n_items bigint)
language sql stable security definer set search_path to 'public' as $function$
  select btrim(sf.co) as company, count(*)::bigint as n_items
    from public.stock_flat sf
   where btrim(coalesce(sf.co, '')) <> ''
   group by btrim(sf.co)
   order by 2 desc, 1;
$function$;

revoke all on function public.get_company_catalog() from public, anon;
grant execute on function public.get_company_catalog() to authenticated, service_role;

commit;
