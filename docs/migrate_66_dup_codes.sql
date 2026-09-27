-- ═══════════════════════════════════════════════════════════════════
-- كشف الأكواد المكرّرة: كود واحد على أكتر من صنف في eplus
-- ═══════════════════════════════════════════════════════════════════
-- في eplus ممكن نفس الكود يتحطّ على أكتر من صنف (مثال حقيقي: 90003806
-- عليه «فيونا مناديل فاميلي ابيض» و«اسود» و«طاردة للناموس» بسعرين).
-- عندنا مخزون كل فرع مفتاحه (فرع + كود) **فريد**، والمزامنة بتعمل
-- ON CONFLICT DO UPDATE — يعني لو الكود وصل مرتين، التاني بيكتب فوق
-- الأول و**رصيد الصنف التاني بيضيع بصمت**، والشاشة بتعرض رصيد واحد
-- منهم على إنه رصيد الكود كله.
--
-- الحل هنا: نمسك التكرار **وهو داخل** — جوّه دالة الـstaging نفسها،
-- قبل ما الـupsert يلمّه:
--   ① تكرار في نفس الدفعة (نفس الكود باسمين في نفس الـpayload)
--   ② تكرار بين دفعتين في نفس جولة المزامنة (الصف موجود من دقايق باسم
--      مختلف) — وده بنفرّقه عن «إعادة تسمية» عادية بين جولتين بشرط
--      الوقت (آخر تحديث للصف خلال 20 دقيقة = نفس الجولة).
-- وبنسجّلهم في stock_dup_codes بالأسماء والكميات عشان الشاشة تعرضهم.
--
-- وكمان إصلاح مهم: الـinsert كان بيقع لو الدفعة الواحدة فيها نفس الكود
-- مرتين («ON CONFLICT DO UPDATE cannot affect row a second time») —
-- بقى بياخد صف واحد لكل كود (الأكبر رصيدًا) والباقي يتسجّل في التقرير.
-- ═══════════════════════════════════════════════════════════════════

BEGIN;

CREATE TABLE IF NOT EXISTS public.stock_dup_codes (
  branch_code text    NOT NULL,
  itm_code    text    NOT NULL,
  names       text[]  NOT NULL DEFAULT '{}',
  qtys        text[]  NOT NULL DEFAULT '{}',
  first_seen  timestamptz NOT NULL DEFAULT now(),
  last_seen   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (branch_code, itm_code)
);

COMMENT ON TABLE public.stock_dup_codes IS
  'أكواد وصلت من eplus على أكتر من صنف (اسم مختلف) — المزامنة بتسجّلها هنا قبل ما الـupsert يلمّها';

GRANT SELECT ON public.stock_dup_codes TO anon, authenticated;

CREATE OR REPLACE FUNCTION public.stage_branch_stock(p_branch text, p_rows jsonb, p_reset boolean DEFAULT false)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare n int;
begin
  if coalesce(current_setting('request.jwt.claims', true), '') <> '' then
    perform public.require_app_role(array['admin','manager']);
  end if;
  if not exists (select 1 from public.branches b where b.code = p_branch and b.is_active) then
    raise exception 'unknown_or_inactive_branch: %', p_branch;
  end if;
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' then
    raise exception 'rows_must_be_array';
  end if;

  perform public.ensure_branch_partitions();
  if p_reset then
    execute format('truncate public.%I', public.branch_part_name('branch_stock_stage', p_branch));
    -- جولة جديدة: نمسح تقرير الفرع ده عشان يتبني من أول وجديد
    delete from public.stock_dup_codes where branch_code = p_branch;
  end if;

  -- ① كود مكرر جوّه نفس الدفعة
  insert into public.stock_dup_codes (branch_code, itm_code, names, qtys)
  select p_branch, btrim(r.itm_code),
         array_agg(distinct btrim(coalesce(r.itm_name_ar,''))),
         array_agg(coalesce(r.sto_qty_big,'0'))
    from jsonb_populate_recordset(null::public.stock_row, p_rows) r
   where coalesce(btrim(r.itm_code), '') <> ''
   group by btrim(r.itm_code)
  having count(distinct btrim(coalesce(r.itm_name_ar,''))) > 1
  on conflict (branch_code, itm_code) do update
    set names = (select array_agg(distinct x) from unnest(public.stock_dup_codes.names || excluded.names) x),
        qtys  = excluded.qtys,
        last_seen = now();

  -- ② كود وصل في دفعة تانية من نفس الجولة باسم مختلف
  insert into public.stock_dup_codes (branch_code, itm_code, names, qtys)
  select p_branch, btrim(r.itm_code),
         array[btrim(coalesce(s.itm_name_ar,'')), btrim(coalesce(r.itm_name_ar,''))],
         array[coalesce(s.sto_qty_big,'0'), coalesce(r.sto_qty_big,'0')]
    from jsonb_populate_recordset(null::public.stock_row, p_rows) r
    join public.branch_stock_stage s
      on s.branch_code = p_branch and s.itm_code = btrim(r.itm_code)
   where coalesce(btrim(r.itm_code), '') <> ''
     and btrim(coalesce(r.itm_name_ar,'')) <> ''
     and btrim(coalesce(s.itm_name_ar,'')) <> ''
     and btrim(r.itm_name_ar) <> btrim(s.itm_name_ar)
     and s.updated_at > now() - interval '20 minutes'   -- نفس الجولة، مش إعادة تسمية بين جولتين
  on conflict (branch_code, itm_code) do update
    set names = (select array_agg(distinct x) from unnest(public.stock_dup_codes.names || excluded.names) x),
        qtys  = excluded.qtys,
        last_seen = now();

  /* صف واحد لكل كود في الدفعة (الأكبر رصيدًا) — من غير كده الـinsert
     بيقع كله لو الكود اتكرر في نفس الدفعة، فتضيع الدفعة بالكامل.      */
  insert into public.branch_stock_stage (branch_code, itm_code, itnl_code, itm_name_ar, itm_name_en,
    u_name_big, u_name_medium, u_name_small, sto_name, sto_qty_big, sto_qty_medium, sto_qty_small,
    itm_sell_price_big, itm_sell_price_medium, itm_sell_price_small,
    unit_big_medium_coeff, unit_big_small_coeff, itm_ismedicine, "Company_Name_Ar",
    insert_date, update_date, last_trans_date, updated_at)
  select distinct on (btrim(r.itm_code))
         p_branch, r.itm_code, r.itnl_code, r.itm_name_ar, r.itm_name_en,
         r.u_name_big, r.u_name_medium, r.u_name_small, r.sto_name,
         r.sto_qty_big, r.sto_qty_medium, r.sto_qty_small,
         r.itm_sell_price_big, r.itm_sell_price_medium, r.itm_sell_price_small,
         r.unit_big_medium_coeff, r.unit_big_small_coeff, r.itm_ismedicine, r."Company_Name_Ar",
         r.insert_date, r.update_date, r.last_trans_date, now()
  from jsonb_populate_recordset(null::public.stock_row, p_rows) r
  where coalesce(btrim(r.itm_code), '') <> ''
  order by btrim(r.itm_code),
           case when coalesce(nullif(btrim(coalesce(r.sto_qty_big,'')), ''),'0') ~ '^-?[0-9]+(\.[0-9]+)?$'
                then coalesce(nullif(btrim(coalesce(r.sto_qty_big,'')), ''),'0')::numeric else 0 end desc
  on conflict (branch_code, itm_code) do update set
    itm_name_ar        = excluded.itm_name_ar,
    sto_qty_big        = excluded.sto_qty_big,
    itm_sell_price_big = excluded.itm_sell_price_big,
    updated_at         = excluded.updated_at;

  get diagnostics n = row_count;
  return n;
end $function$;

-- قراءة التقرير للشاشة (jsonb = مش متأثر بسقف 1000)
CREATE OR REPLACE FUNCTION public.get_dup_codes(p_branch text DEFAULT NULL)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $function$
  select coalesce(jsonb_agg(jsonb_build_object(
           'branch',   b.name,
           'code',     d.itm_code,
           'names',    d.names,
           'qtys',     d.qtys,
           'count',    coalesce(array_length(d.names,1),0),
           'last_seen', to_char(d.last_seen at time zone 'Africa/Cairo','YYYY-MM-DD HH24:MI')
         ) order by coalesce(array_length(d.names,1),0) desc, d.itm_code), '[]'::jsonb)
    from stock_dup_codes d
    left join branches b on b.code = d.branch_code
   where p_branch is null or p_branch = '' or b.name = p_branch or d.branch_code = p_branch;
$function$;

GRANT EXECUTE ON FUNCTION public.get_dup_codes(text) TO anon, authenticated;

COMMIT;
