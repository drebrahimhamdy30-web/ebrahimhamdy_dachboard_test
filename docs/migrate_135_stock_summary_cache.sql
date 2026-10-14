/* ============================================================
   ملخّص المخزون: يتبني مرة بعد كل مزامنة بدل كل فتحة شاشة
   ------------------------------------------------------------
   get_stock_summary بترجّع **كل** أصناف المخزون (٢٨,٩٧٤ صنف) في
   JSON واحد، بكمية وسعر لكل فرع — وبتبنيه من الأول في كل نداء.
   ده كان بياخد ٢.٥ ثانية في المتوسط على الإنتاج، والمستخدم قاعد
   مستني قدام شاشة «إدارة المخزون» و«طلبيات كوزمو».

   البيانات دي مابتتغيّرش إلا لما stock_flat يتبني (كل ١٠ دقايق،
   ونص المرات مفيش جديد أصلًا) — فبناؤها لكل مستخدم شغل مكرر.

   الحل: الناتج بيتخزّن مع بصمة مصدره. النداء بيقارن البصمة:
   زي ما هي → يرجّع المخزّن فورًا؛ اتغيّرت → يبني ويخزّن.

   البصمة = نسخة المخزون (stock_flat_meta.src_max) + عدد الأصناف +
   حروف الفروع (لو اتزاد فرع شكل الـJSON نفسه بيتغيّر).

   + مهمة تسخين كل ١٠ دقايق (warm_stock_summary) بعد مزامنة المخزون
     بدقيقتين: بتبني الكاش في الخلفية فالمستخدم مايستناش أبدًا.
     ولو المخزون ماتغيّرش بترجع فورًا من غير شغل.

   القياس:
     أول نداء (كاش فاضي): 1,146 م.ث
     تاني نداء (من الكاش):     4 م.ث      → أسرع ٢٨٦ مرة
     الناتج متطابق تمامًا (قارنت الـJSON كامل)
     ٢٨,٩٧٤ صنف · 1.6 ميجا

   ⚠️ الدالة بقت VOLATILE عشان تكتب الكاش. الشاشتين بينادوها POST
   أصلًا فمفيش أي تأثير عليهم.
   ============================================================ */
create table if not exists public.stock_summary_cache (
  id       integer primary key,
  src_fp   text,
  payload  jsonb,
  built_at timestamptz,
  constraint stock_summary_cache_single check (id = 1)
);
revoke all on table public.stock_summary_cache from public, anon, authenticated;

create or replace function public.get_stock_summary()
returns jsonb
language plpgsql
volatile
security definer
set search_path to 'public'
as $function$
declare
  v_meta jsonb := '{}'::jsonb; v_brs jsonb := '[]'::jsonb; v_items jsonb;
  v_sel text := ''; v_cnt bigint; v_upd timestamptz; v_tbl text; r record;
  v_fp text; v_out jsonb;
begin
  select coalesce((select m.src_max::text from public.stock_flat_meta m where m.id = 1), '-')
      || '|' || (select count(*)::text from public.stock_flat)
      || '|' || coalesce((select string_agg(bl.letter, ',' order by bl.sort_order)
                            from public.branch_letters() bl), '-')
    into v_fp;

  select c.payload into v_out
    from public.stock_summary_cache c
   where c.id = 1 and c.src_fp = v_fp and c.payload is not null;
  if v_out is not null then return v_out; end if;

  for r in select * from public.branch_letters() loop
    v_tbl := 'stock_' || r.code;
    if to_regclass('public.' || quote_ident(v_tbl)) is not null then
      execute format('select count(*), max(updated_at) from public.%I', v_tbl) into v_cnt, v_upd;
    else
      v_cnt := 0; v_upd := null;
    end if;
    v_meta := v_meta || jsonb_build_object(r.code, jsonb_build_object('count', v_cnt, 'updated', v_upd));
    v_brs  := v_brs  || jsonb_build_object('code', r.code, 'name', r.name,
                                           'letter', r.letter, 'sort', r.sort_order);
    if exists (select 1 from information_schema.columns
                where table_schema = 'public' and table_name = 'stock_flat'
                  and column_name = r.letter || '_q') then
      v_sel := v_sel || format(', %L, jsonb_build_object(%L, %I, %L, %I, %L, %I)',
                 r.letter, 'h', r.letter || '_h', 'q', r.letter || '_q', 'p', r.letter || '_p');
    else
      v_sel := v_sel || format(', %L, jsonb_build_object(%L, false, %L, 0, %L, 0)',
                 r.letter, 'h', 'q', 'p');
      raise notice '⚠️ فرع % (حرف %) مالوش أعمدة في stock_flat — بيرجع بأصفار', r.code, r.letter;
    end if;
  end loop;
  v_meta := v_meta || jsonb_build_object('branches', v_brs);

  execute 'select coalesce(jsonb_agg(jsonb_build_object('
       || '''c'', itm_code, ''n'', n, ''co'', co, ''u'', u, ''med'', med'
       || v_sel || ')), ''[]''::jsonb) from public.stock_flat' into v_items;

  v_out := jsonb_build_object('meta', v_meta, 'items', v_items);

  insert into public.stock_summary_cache (id, src_fp, payload, built_at)
  values (1, v_fp, v_out, now())
  on conflict (id) do update
    set src_fp = excluded.src_fp, payload = excluded.payload, built_at = excluded.built_at;

  return v_out;
end
$function$;

revoke all on function public.get_stock_summary() from public, anon;
grant execute on function public.get_stock_summary() to authenticated, service_role;

/* التسخين — بعد مزامنة المخزون (:00) بدقيقتين */
select cron.schedule('warm_stock_summary', '2-59/10 * * * *', $$select public.get_stock_summary()$$);
