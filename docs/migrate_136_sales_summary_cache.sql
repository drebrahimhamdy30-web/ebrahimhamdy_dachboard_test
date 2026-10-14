/* ============================================================
   ملخّص المبيعات: نفس فكرة كاش المخزون
   ------------------------------------------------------------
   get_sales_summary بتجمّع كل monthly_sales (٧٣ ألف صف) بالصنف،
   وتربطها بمعدلات الاستهلاك، وترجّع ١٤,٣٦٨ صنف في JSON واحد —
   وبتبنيه من الأول في كل نداء (١.٨ ثانية في المتوسط على الإنتاج).

   المبيعات الشهرية بتتحدّث **مرة في اليوم** من المزامنة، فبناؤها
   لكل مستخدم شغل مكرر بالكامل.

   البصمة = آخر تحديث للمبيعات الشهرية + عددها + آخر حساب لمعدلات
   الاستهلاك + أكواد الفروع.

   القياس: 717 م.ث → 20 م.ث، والناتج متطابق (قارنت الـJSON كامل).

   ⚠️ بقت SECURITY DEFINER عشان تكتب الكاش (الجدول مقفول على
   المستخدمين). ده مابيغيّرش اللي المستخدم بيشوفه: سياسة
   monthly_sales و consumption_flat الاتنين using (true) فمفيش
   فلترة صفوف أصلًا. والشاشة بتنادي POST فمفيش أي تأثير عليها.
   ============================================================ */
create table if not exists public.sales_summary_cache (
  id       integer primary key,
  src_fp   text,
  payload  jsonb,
  built_at timestamptz,
  constraint sales_summary_cache_single check (id = 1)
);
revoke all on table public.sales_summary_cache from public, anon, authenticated;

create or replace function public.get_sales_summary()
returns jsonb
language plpgsql
volatile
security definer
set search_path to 'public'
as $function$
declare
  v_sel text := ''; v_rows jsonb; r record; v_fp text; v_out jsonb;
begin
  select coalesce((select max(ms.updated_at)::text from public.monthly_sales ms), '-')
      || '|' || (select count(*)::text from public.monthly_sales)
      || '|' || coalesce((select max(cf.refreshed_at)::text from public.consumption_flat cf), '-')
      || '|' || coalesce((select string_agg(bl.code, ',' order by bl.sort_order)
                            from public.branch_letters() bl), '-')
    into v_fp;

  select c.payload into v_out
    from public.sales_summary_cache c
   where c.id = 1 and c.src_fp = v_fp and c.payload is not null;
  if v_out is not null then return v_out; end if;

  for r in select * from public.branch_letters() loop
    if exists (select 1 from information_schema.columns
                where table_schema='public' and table_name='monthly_sales' and column_name = r.code) then
      v_sel := v_sel || ', sum(ms.' || quote_ident(r.code) || ') as ' || quote_ident(r.code || '_total')
                     || ', count(*) filter (where ms.' || quote_ident(r.code) || ' > 0) as '
                     || quote_ident(r.code || '_active');
    else
      v_sel := v_sel || ', 0::numeric as ' || quote_ident(r.code || '_total')
                     || ', 0::bigint as '  || quote_ident(r.code || '_active');
    end if;
    v_sel := v_sel || ', max(coalesce(cf.' || quote_ident('av_' || r.code) || ', 0)) as ' || quote_ident(r.code || '_av')
                   || ', max(coalesce(cf.' || quote_ident('sur_' || r.code) || ', 0)) as ' || quote_ident(r.code || '_sur');
  end loop;

  execute 'select coalesce(jsonb_agg(t), ''[]''::jsonb) from ('
       || ' select ms.itm_code, max(ms.itm_name) as itm_name' || v_sel
       || ' from monthly_sales ms'
       || ' left join consumption_flat cf on cf.code = ms.itm_code'
       || ' group by ms.itm_code) t' into v_rows;

  insert into public.sales_summary_cache (id, src_fp, payload, built_at)
  values (1, v_fp, v_rows, now())
  on conflict (id) do update
    set src_fp = excluded.src_fp, payload = excluded.payload, built_at = excluded.built_at;

  return v_rows;
end
$function$;

revoke all on function public.get_sales_summary() from public, anon;
grant execute on function public.get_sales_summary() to authenticated, service_role;

/* التسخين بقى بينادي الاتنين */
select cron.schedule('warm_stock_summary', '2-59/10 * * * *',
                     $$select public.get_stock_summary(), public.get_sales_summary()$$);
