/* ═══════════════════════════════════════════════════════════════════
   رفع المخزون يدويًا من تقرير eplus — من الشاشة بدل سطر الأوامر
   ═══════════════════════════════════════════════════════════════════
   `scripts/load_stock_xlsx.js` (2026-11-10) بيعمل ده صح، بس بيتشغّل
   من جهاز المبرمج. ووقت ما الـAPI تقع المالك أو الموظف محتاج يرفع
   الملف بنفسه من غير ما يستنى حد.

   ── إيه اللي بيتحسب هنا بدل المتصفح ──────────────────────────────
   التقرير ٢٨ ألف صف. لو المتصفح جاب جدول الفرع (٢٨ ألف صف × ٢٢
   عمود) عشان يدمج، ده ميجابايتات على نت الصيدلية اللي أصلًا بيقطّع.
   فالمتصفح بيبعت **٦ حقول بس** لكل صف (كود·كمية·سعر·وحدة·شركة·اسم)
   على دفعات، والدمج كله بيحصل هنا.

   ── الدمج ───────────────────────────────────────────────────────
   الصف الموجود في الفرع هو الأساس، والتقرير بيدوس على الكمية والسعر
   والاسم والشركة بس. لو الصنف مش في الفرع ناخد وصفه من فرع تاني
   (نفس الكتالوج). وآخر حل صف من التقرير لوحده.

   ⚠️ **ليه الأساس مهم:** `upsert_branch_stock` بيكتب **كل** أعمدة
      الجدول من الـJSON، فأي عمود غايب بيتكتب NULL. يعني من غير
      الدمج ده كنا هنمسح الباركود وعلم «دواء» ومعاملات الوحدات.

   ⚠️ **الوحدات**: التقرير بالوحدة الكبرى (عنوانه بيقول «الوحدة كبرى»).
      الصغرى والمتوسطة بتتحسب بالمعامل المحفوظ في الصف — مش بتتاخد
      من التقرير لأنها مش فيه. راجع [[unit-trap-strips-vs-boxes]].

   ── الحراس ──────────────────────────────────────────────────────
   ١. الفرع اختيار صريح — التقرير مافيهوش اسم الفرع، وملف فرع على
      فرع تاني بيضرب مخزون الاتنين.
   ٢. عدد الصفوف لازم ≥ ٨٠٪ من صفوف الجدول الحالي.
   ٣. قيمة المخزون ماتنزلش أكتر من ٣٠٪.
   الاتنين الأخيرين بيتخطّوا بـ`p_force` بعد تأكيد المستخدم، والمعاينة
   بتوريهم قبل أي كتابة.

   يتطبّق على: السحابة **و** السيرفر الذاتي.
   ═══════════════════════════════════════════════════════════════════ */

create table if not exists public.stock_import_stage (
  token    uuid    not null,
  branch   text    not null,
  itm_code text    not null,
  qty      numeric not null default 0,
  price    numeric not null default 0,
  unit     text,
  company  text,
  name     text,
  created_at timestamptz not null default now(),
  primary key (token, itm_code)
);

create index if not exists ix_stock_import_stage_token on public.stock_import_stage (token);

create table if not exists public.stock_import_log (
  id          bigserial primary key,
  branch      text not null,
  token       uuid,
  rows        int,
  matched     int,
  from_donor  int,
  bare        int,
  changed     int,
  val_before  numeric,
  val_after   numeric,
  forced      boolean default false,
  applied_at  timestamptz not null default now(),
  applied_by  text
);

alter table public.stock_import_stage enable row level security;
alter table public.stock_import_log   enable row level security;
revoke all on public.stock_import_stage from public, anon, authenticated;
revoke all on public.stock_import_log   from public, anon;
grant select on public.stock_import_log to authenticated;
drop policy if exists stock_import_log_read on public.stock_import_log;
create policy stock_import_log_read on public.stock_import_log
  for select to authenticated using (true);

/* ─── بدء رفعة ─────────────────────────────────────────────────── */
create or replace function public.stock_import_begin(p_branch text)
returns uuid
language plpgsql security definer set search_path to 'public' as $fn$
declare v_token uuid := gen_random_uuid();
begin
  perform require_app_role(array['admin','manager']::text[]);
  if not exists (select 1 from branch_letters() bl where bl.code = p_branch) then
    raise exception 'فرع غير معروف: %', p_branch;
  end if;
  /* رفعة اتقطعت في النص مش لازم تفضل مخزّنة — تنضيف بعد يوم */
  delete from stock_import_stage where created_at < now() - interval '1 day';
  return v_token;
end$fn$;

/* ─── دفعة صفوف ────────────────────────────────────────────────── */
create or replace function public.stock_import_push(p_token uuid, p_branch text, p_rows jsonb)
returns int
language plpgsql security definer set search_path to 'public' as $fn$
declare v_n int;
begin
  perform require_app_role(array['admin','manager']::text[]);
  if jsonb_typeof(p_rows) <> 'array' then raise exception 'p_rows لازم تكون مصفوفة'; end if;
  insert into stock_import_stage (token, branch, itm_code, qty, price, unit, company, name)
  select p_token, p_branch,
         btrim(x->>'code'),
         coalesce((x->>'qty')::numeric, 0),
         coalesce((x->>'price')::numeric, 0),
         nullif(btrim(coalesce(x->>'unit','')),''),
         nullif(btrim(coalesce(x->>'company','')),''),
         nullif(btrim(coalesce(x->>'name','')),'')
    from jsonb_array_elements(p_rows) x
   where btrim(coalesce(x->>'code','')) <> ''
  on conflict (token, itm_code) do update set
    qty = excluded.qty, price = excluded.price, unit = excluded.unit,
    company = excluded.company, name = excluded.name;
  get diagnostics v_n = row_count;
  return v_n;
end$fn$;

/* ─── بناء صفوف الدمج (مشتركة بين المعاينة والتطبيق) ───────────── */
create or replace function public.stock_import_build(p_token uuid)
returns jsonb
language plpgsql stable security definer set search_path to 'public' as $fn$
declare
  v_branch text; v_tbl text; v_store text; v_union text; v_sql text; v_out jsonb;
begin
  select branch into v_branch from stock_import_stage where token = p_token limit 1;
  if v_branch is null then raise exception 'مفيش بيانات مرفوعة للرمز ده'; end if;
  v_tbl := 'stock_' || v_branch;
  if to_regclass('public.' || quote_ident(v_tbl)) is null then
    raise exception 'الجدول % مش موجود', v_tbl;
  end if;
  select b.name into v_store
    from branch_letters() bl join branches b on b.name = bl.name where bl.code = v_branch;

  /* الفروع التانية كمصدر وصف — بتتبني من الجداول الموجودة فعلًا */
  select string_agg(format('select itm_code, to_jsonb(d) j from public.%I d', 'stock_' || bl.code),
                    ' union all ' order by bl.code)
    into v_union
    from branch_letters() bl
   where bl.code <> v_branch
     and to_regclass('public.' || quote_ident('stock_' || bl.code)) is not null;

  v_sql := format($q$
    with sheet as (select * from stock_import_stage where token = %L),
    mine as (select itm_code, to_jsonb(t) j from public.%I t),
    donor as (select itm_code, (array_agg(j))[1] j from (%s) z group by itm_code),
    merged as (
      select s.itm_code, s.qty, s.price,
             coalesce(m.j, d.j) base,
             (m.j is not null) is_mine,
             (m.j is null and d.j is not null) is_donor,
             coalesce(nullif((coalesce(m.j, d.j) ->> 'unit_big_small_coeff'),'')::numeric, 1)  cs,
             coalesce(nullif((coalesce(m.j, d.j) ->> 'unit_big_medium_coeff'),'')::numeric, 1) cm,
             coalesce(nullif((m.j ->> 'sto_qty_big'),'')::numeric, -1) old_q,
             coalesce(nullif((m.j ->> 'itm_sell_price_big'),'')::numeric, 0) old_p,
             s.unit, s.company, s.name
        from sheet s
        left join mine  m on m.itm_code = s.itm_code
        left join donor d on d.itm_code = s.itm_code
    )
    select jsonb_build_object(
      'branch', %L,
      'rows',       (select count(*) from merged),
      'matched',    (select count(*) from merged where is_mine),
      'from_donor', (select count(*) from merged where is_donor),
      'bare',       (select count(*) from merged where base is null),
      'bare_stock', (select count(*) from merged where base is null and qty > 0),
      'changed',    (select count(*) from merged where old_q is distinct from qty),
      'val_after',  (select round(coalesce(sum(qty * price),0)) from merged),
      'val_before', (select round(coalesce(sum(
                        coalesce(nullif(btrim(t.sto_qty_big::text),'')::numeric,0)
                      * coalesce(nullif(btrim(t.itm_sell_price_big::text),'')::numeric,0)),0))
                      from public.%I t),
      'tbl_rows',   (select count(*) from public.%I),
      'payload',    (select coalesce(jsonb_agg(
            (coalesce(mg.base, '{}'::jsonb) - 'updated_at')
            || jsonb_build_object(
                 'itm_code',              mg.itm_code,
                 'sto_name',              %L,
                 'sto_qty_big',           mg.qty,
                 'sto_qty_small',         round(mg.qty * mg.cs, 2),
                 'sto_qty_medium',        round(mg.qty * mg.cm, 2),
                 'itm_sell_price_big',    mg.price,
                 'itm_sell_price_small',  round(mg.price / nullif(mg.cs,0), 2),
                 'itm_sell_price_medium', round(mg.price / nullif(mg.cm,0), 2),
                 'unit_big_small_coeff',  mg.cs,
                 'unit_big_medium_coeff', mg.cm)
            || case when mg.name    is not null then jsonb_build_object('itm_name_ar', mg.name) else '{}'::jsonb end
            || case when mg.company is not null then jsonb_build_object('Company_Name_Ar', mg.company) else '{}'::jsonb end
            || case when mg.unit is not null and coalesce(mg.base ->> 'u_name_big','') = ''
                    then jsonb_build_object('u_name_big', mg.unit) else '{}'::jsonb end
            /* الصف الشحيح مالوش وحدات صغرى — نساويها بالكبرى بدل NULL
               اللي بيبوّظ عرض الوحدة في الشاشات */
            || case when coalesce(mg.base ->> 'u_name_small','') = ''
                    then jsonb_build_object('u_name_small', coalesce(nullif(mg.base ->> 'u_name_big',''), mg.unit)) else '{}'::jsonb end
            || case when coalesce(mg.base ->> 'u_name_medium','') = ''
                    then jsonb_build_object('u_name_medium', coalesce(nullif(mg.base ->> 'u_name_big',''), mg.unit)) else '{}'::jsonb end
          ), '[]'::jsonb) from merged mg)
    )
  $q$, p_token, v_tbl, coalesce(v_union, 'select null::text itm_code, null::jsonb j where false'),
       v_branch, v_tbl, v_tbl, v_store);

  execute v_sql into v_out;
  return v_out;
end$fn$;

/* ─── المعاينة: نفس الأرقام من غير الحمولة ─────────────────────── */
create or replace function public.stock_import_preview(p_token uuid)
returns jsonb
language plpgsql stable security definer set search_path to 'public' as $fn$
declare v jsonb;
begin
  perform require_app_role(array['admin','manager']::text[]);
  v := public.stock_import_build(p_token);
  return (v - 'payload')
       || jsonb_build_object('drop_pct',
            case when (v->>'val_before')::numeric > 0
                 then round(100 * (1 - (v->>'val_after')::numeric / (v->>'val_before')::numeric), 1)
                 else 0 end);
end$fn$;

/* ─── التطبيق ──────────────────────────────────────────────────── */
create or replace function public.stock_import_apply(p_token uuid, p_force boolean default false)
returns jsonb
language plpgsql security definer set search_path to 'public' as $fn$
declare
  v jsonb; v_res jsonb; v_drop numeric; v_by text;
begin
  perform require_app_role(array['admin','manager']::text[]);
  v := public.stock_import_build(p_token);

  /* ⚠️ الحراس قبل أي كتابة: ملف ناقص أو ملف فرع تاني بيبان هنا */
  if (v->>'rows')::int < ceil((v->>'tbl_rows')::numeric * 0.8) and not p_force then
    raise exception 'الملف فيه % صف والجدول فيه % — أقل من ٨٠٪. أكّد لو ده مقصود',
      (v->>'rows'), (v->>'tbl_rows');
  end if;
  v_drop := case when (v->>'val_before')::numeric > 0
                 then 100 * (1 - (v->>'val_after')::numeric / (v->>'val_before')::numeric)
                 else 0 end;
  if v_drop > 30 and not p_force then
    raise exception 'قيمة المخزون هتنزل %٪ — أكّد لو ده مقصود', round(v_drop, 1);
  end if;

  v_res := public.upsert_branch_stock(v->>'branch', v->'payload');

  v_by := coalesce(nullif(current_setting('request.jwt.claims', true),'')::jsonb->>'full_name',
                   nullif(current_setting('request.jwt.claims', true),'')::jsonb->>'name',
                   public.jwt_app_role(), 'غير معروف');
  insert into stock_import_log (branch, token, rows, matched, from_donor, bare, changed,
                                val_before, val_after, forced, applied_by)
  values (v->>'branch', p_token, (v->>'rows')::int, (v->>'matched')::int,
          (v->>'from_donor')::int, (v->>'bare')::int, (v->>'changed')::int,
          (v->>'val_before')::numeric, (v->>'val_after')::numeric, coalesce(p_force,false), v_by);

  delete from stock_import_stage where token = p_token;

  return (v - 'payload') || jsonb_build_object('written', v_res, 'by', v_by, 'forced', coalesce(p_force,false));
end$fn$;

revoke all on function public.stock_import_begin(text)          from public, anon;
revoke all on function public.stock_import_push(uuid,text,jsonb) from public, anon;
revoke all on function public.stock_import_build(uuid)           from public, anon, authenticated;
revoke all on function public.stock_import_preview(uuid)         from public, anon;
revoke all on function public.stock_import_apply(uuid,boolean)   from public, anon;
/* service_role كمان عشان السكربت القديم والباك إند يقدروا يستعملوها —
   require_app_role بيسمح لـservice_role صراحة. */
grant execute on function public.stock_import_begin(text)           to authenticated, service_role;
grant execute on function public.stock_import_push(uuid,text,jsonb) to authenticated, service_role;
grant execute on function public.stock_import_preview(uuid)         to authenticated, service_role;
grant execute on function public.stock_import_apply(uuid,boolean)   to authenticated, service_role;

notify pgrst, 'reload schema';
