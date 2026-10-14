/* ============================================================
   اقتراح أكواد بالأسماء: يستعمل نفس كاش المطابقة
   ------------------------------------------------------------
   suggest_codes_for_names بتلفّ على الأسماء وتنادي
   suggest_stock_codes لكل اسم — **نفس** المطابقة التقريبية الغالية
   اللي خزّناها لشاشة المشتريات في migrate_129 (٥٨ م.ث للاسم).

   فبدل كاش تاني، بتقرا من نفس الجدول purchase_name_code_cache —
   المفتاح هو الاسم الخام والناتج هو ناتج نفس الدالة بالظبط، فالشاشتين
   بيسخّنوا لبعض. (اسم الجدول تاريخي من أول استعمال.)

   ⚠️ منطق المطابقة ما اتلمسش — تخزين الناتج بس.

   القياس على ١٠ أسماء حقيقية:
     كاش فاضي: 1,740 م.ث · من الكاش: 5 م.ث  → أسرع ٣٤٨ مرة
     صفوف مختلفة بين الاتنين: صفر (قارنت الناتج كامل بـEXCEPT)

   بقت VOLATILE عشان تكتب الكاش؛ الشاشة بتناديها POST فمفيش تأثير.
   ============================================================ */
create or replace function public.suggest_codes_for_names(p_names text[])
returns table(item_name text, best_code text, best_name text, sim real)
language plpgsql
volatile
security definer
set search_path to 'public'
as $function$
declare
  nm text; r record; v_key text; v_hit boolean;
  v_stock_n integer := (select count(*) from public.stock_flat);
begin
  foreach nm in array coalesce(p_names, '{}') loop
    item_name := nm; best_code := null; best_name := null; sim := null;
    v_key := btrim(coalesce(nm,'')); v_hit := false;

    if v_key <> '' then
      select c.itm_code, c.matched_name, c.sim, true
        into best_code, best_name, sim, v_hit
        from public.purchase_name_code_cache c
       where c.name_key = v_key
         and c.stock_n = v_stock_n
         and c.computed_at > now() - interval '7 days';
    end if;

    if not coalesce(v_hit,false) then
      select s.itm_code, s.name, s.sim into r from public.suggest_stock_codes(nm, 1) s;
      best_code := r.itm_code; best_name := r.name; sim := r.sim;
      if v_key <> '' then
        insert into public.purchase_name_code_cache(name_key, itm_code, matched_name, sim, stock_n, computed_at)
        values (v_key, best_code, best_name, sim, v_stock_n, now())
        on conflict (name_key) do update
          set itm_code = excluded.itm_code, matched_name = excluded.matched_name,
              sim = excluded.sim, stock_n = excluded.stock_n, computed_at = excluded.computed_at;
      end if;
    end if;

    return next;
  end loop;
end
$function$;

revoke all on function public.suggest_codes_for_names(text[]) from public, anon;
grant execute on function public.suggest_codes_for_names(text[]) to authenticated, service_role;
