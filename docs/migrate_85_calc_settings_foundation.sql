/* ═══════════════════════════════════════════════════════════════════
   أساس توحيد حساب المعدل والفائض — التصنيف + الإعدادات + الأعمدة
   ═══════════════════════════════════════════════════════════════════
   الحالة قبل ده (اتجردت 2026-10-01): تلات حسابات منفصلة لنفس الحاجة.

     الأدوية   → get_consumption_rates → consumption_flat (demand_tiers)
     الكوزمو   → جوّه cosmo_order.html — جدول قواعد **في المتصفح**
                 و**مش محفوظ في أي مكان**، بيتكتب من الأول كل جلسة
     الورقيات  → **سويتش** في نفس شاشة الكوزمو بيغيّر المعامل 1.2 → 0.75

   وأربع أماكن بتحسب «فائض» من تلات مصادر معدل مختلفة:
     الطلبيات (consumption_flat) · الحد الأدنى (consumption_flat) ·
     إدارة المخزون «الزائد» و«التوزيع» (بتحسب معدل خام بنفسها).

   الهدف (قرار المالك): **مكان واحد** في إعدادات المؤسسة يحدّد المعدل
   والفائض **لكل فرع × تصنيف**، وكل السيستم يقرا منه. والوضع الحالي
   هو الافتراضي لكل الفروع، وقابل للتغيير لكل فرع على حدة.

   الترحيل ده الأساس بس (جداول + تصنيف + أعمدة). الدوال في 86.

   يتطبّق على: السحابة **و** السيرفر الذاتي.
   ═══════════════════════════════════════════════════════════════════ */

/* ── 1) التصنيف ──────────────────────────────────────────────────
   «ورقيات» شركة حقيقية في المخزون (379 صنف)، فهي العلامة الوحيدة
   الموجودة في البيانات — مفيش عمود تصنيف ولا جدول فئات.

   ⚠️ الشركة **تغلب** على `med`: فيه 6 أصناف شركتها «ورقيات» ومتعلّمة
      med=1 في eplus (دراى جو — حفاضات بالغين)، فكانت بتتطلب بمعدل
      الأدوية. الأولوية دي بتصلّحهم من غير تعديل بيانات. */
create or replace function public.item_category(p_co text, p_med integer)
returns text
language sql
immutable
as $fn$
  select case
           when btrim(coalesce(p_co, '')) = 'ورقيات' then 'paper'
           when coalesce(p_med, 0) = 1                then 'med'
           else                                            'cos'
         end;
$fn$;

comment on function public.item_category(text, integer) is
  'تصنيف الصنف لحساب المعدل: paper (شركة ورقيات — الأولوية) · med · cos';

/* ── 2) شرائح المعامل لكل تصنيف ──────────────────────────────────
   بتحل محل demand_tiers كمصدر وحيد، ومعاها البعد الجديد (التصنيف)
   وإمكانية التخصيص لفرع.

   `branch` فاضي = القاعدة الافتراضية لكل الفروع. لو فيه سطر باسم فرع
   معيّن، بيغلب على الافتراضي **لنفس التصنيف**. */
create table if not exists public.category_rate_tiers (
  id         bigserial primary key,
  category   text    not null check (category in ('med','cos','paper')),
  branch     text,                                  -- فاضي = كل الفروع
  rate_min   numeric not null default 0,            -- المعدل الخام ≥
  active_min integer not null default 0,            -- الشهور النشطة ≥
  multiply   numeric not null default 1,            -- × المعامل
  updated_at timestamptz not null default now()
);

create unique index if not exists category_rate_tiers_key
  on public.category_rate_tiers (category, coalesce(branch, ''), rate_min, active_min);

/* البذرة = الوضع الحالي بالحرف.
   الأدوية: نسخة من demand_tiers زي ما هي.
   الكوزمو/الورقيات: القاعدة الافتراضية في شاشة الكوزمو
   (معدل ≥ 1 · شهور ≥ 2 · ×1.2 للكوزمو و×0.75 للورقيات). */
insert into public.category_rate_tiers (category, branch, rate_min, active_min, multiply)
select 'med', null, t.rate_min, t.active_min, t.save_factor
  from public.demand_tiers t
 where not exists (select 1 from public.category_rate_tiers c where c.category = 'med')
on conflict do nothing;

insert into public.category_rate_tiers (category, branch, rate_min, active_min, multiply)
select * from (values
  ('cos',   null::text, 1::numeric, 2, 1.2::numeric),
  ('paper', null::text, 1::numeric, 2, 0.75::numeric)
) as v(category, branch, rate_min, active_min, multiply)
where not exists (select 1 from public.category_rate_tiers c where c.category = v.category)
on conflict do nothing;

/* ── 3) إعدادات الحساب لكل فرع × تصنيف ───────────────────────────
   rate_source     own     = معدل مبيعات الفرع نفسه
                   derived = مشتق من فرع تاني (شرائح new_branch_rate_tiers)
   surplus_mode    same        = الفائض بنفس معدل الشراء
                   source_full = الفائض بمعدل الفرع المصدر **الكامل**
                                 (السبب في migrate_84: الشريحة المنخفضة
                                  متحفّظة في الشراء، والتحفّظ في الفائض
                                  يتطلب معدل أعلى وإلا الرصيد كله فائض) */
create table if not exists public.branch_calc_settings (
  id                bigserial primary key,
  branch            text not null,
  category          text not null check (category in ('med','cos','paper')),
  rate_source       text not null default 'own'  check (rate_source in ('own','derived')),
  source_branch     text,
  surplus_mode      text not null default 'same' check (surplus_mode in ('same','source_full')),
  min_stock_surplus numeric not null default 2,
  active            boolean not null default true,
  updated_at        timestamptz not null default now(),
  unique (branch, category),
  constraint derived_needs_source
    check (rate_source <> 'derived' or nullif(btrim(coalesce(source_branch,'')), '') is not null)
);

/* البذرة: سطر لكل (فرع × تصنيف) بالوضع الحالي.
   الافتراضي own/same، وبنرث حالة الفرع الجديد من new_branch_rate. */
insert into public.branch_calc_settings
  (branch, category, rate_source, source_branch, surplus_mode, min_stock_surplus, active)
select b.name, c.cat,
       case when nbr.source_branch is not null then 'derived' else 'own' end,
       nbr.source_branch,
       case when nbr.source_branch is not null then 'source_full' else 'same' end,
       coalesce((select min_stock_surplus from public.purchase_settings where id = 1), 2),
       true
  from public.branch_letters() b
  cross join (values ('med'),('cos'),('paper')) as c(cat)
  left join public.new_branch_rate nbr
         on nbr.active and nbr.target_branch = b.name
on conflict (branch, category) do nothing;

/* ── 4) عمود معدل الفائض في consumption_flat ─────────────────────
   مصدر الحقيقة الواحد. بيتضاف لأي فرع جديد تلقائيًا زي باقي الأعمدة. */
create or replace function public.sync_branch_sales_columns()
returns text
language plpgsql
as $fn$
declare
  r     record;
  v_add text := '';
  spec  record;
begin
  for r in select * from public.branch_letters() loop
    for spec in
      select * from (values
        ('monthly_sales',        r.code,               'numeric'),
        ('consumption_flat',     'av_'   || r.code,    'numeric'),
        ('consumption_flat',     'base_' || r.code,    'numeric'),
        ('consumption_flat',     'act_'  || r.code,    'integer'),
        ('consumption_flat',     'sur_'  || r.code,    'numeric'),
        ('purchase_orders_flat', 'surplus_' || r.code, 'integer')
      ) as t(tbl, col, typ)
    loop
      if to_regclass('public.' || quote_ident(spec.tbl)) is not null
         and not exists (select 1 from information_schema.columns
                          where table_schema = 'public'
                            and table_name = spec.tbl and column_name = spec.col)
      then
        execute format('alter table public.%I add column %I %s', spec.tbl, spec.col, spec.typ);
        v_add := v_add || spec.tbl || '.' || spec.col || '  ';
      end if;
    end loop;
  end loop;
  return case when v_add = '' then 'مفيش أعمدة ناقصة' else 'اتضاف: ' || v_add end;
end
$fn$;

select public.sync_branch_sales_columns();

/* ── 5) الصلاحيات ────────────────────────────────────────────────
   القراءة للكل (الشاشات محتاجاها)، والكتابة من شاشة إعدادات المؤسسة
   اللي محمية بالدور — زي باقي جداول الإعدادات في المشروع. */
grant select on public.category_rate_tiers, public.branch_calc_settings to anon, authenticated;
grant insert, update, delete on public.category_rate_tiers, public.branch_calc_settings to authenticated;
grant usage, select on sequence public.category_rate_tiers_id_seq  to authenticated;
grant usage, select on sequence public.branch_calc_settings_id_seq to authenticated;
