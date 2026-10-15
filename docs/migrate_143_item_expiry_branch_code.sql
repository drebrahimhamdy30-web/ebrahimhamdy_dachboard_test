/* ═══════════════════════════════════════════════════════════════════
   مزامنة الصلاحية: الفرع بكوده الإنجليزي مش باسمه العربي
   ═══════════════════════════════════════════════════════════════════
   أول تشغيل للمهمة فشل في الفروع الأربعة:
     «لا يوجد إعداد اتصال للفرع المعمورة»

   المحرّك بيدوّر على إعداد الاتصال بـ`$cfg.branches.$branch`، ومفاتيح
   ملف الأسرار **أكواد إنجليزية** (`mamora`, `san`, `bishr`, `seyouf`).
   وعشان كده كل جداول المزامنة القديمة (`purchase_invoices` وغيرها)
   بتخزّن الكود مش الاسم. أنا حطيت الاسم العربي في
   `sync_branch_state` فمالقاش إعداد.

   ⚠️ **الدرس**: أي مهمة جديدة في `sync_jobs` لازم فروعها بالكود.
      والفشل ظهر في `sync_runs` بس — `item_expiry` فضلت فيها بيانات
      التحميل اليدوي، فالشاشة كانت شغّالة وكأن كل حاجة تمام.

   فبقى `item_expiry.branch` = الكود (ASCII)، والترجمة للعربي في
   `expiry_source_for` من `branch_letters()` — المصدر الموحّد للمقابلة
   بين الكود والاسم. ومكسب تاني: نص الـSQL بقى إنجليزي بالكامل،
   فمابقاش يعتمد على ترتيب المقارنة العربي في SQL Server 2000.

   يتطبّق على: السحابة **و** السيرفر الذاتي.
   ═══════════════════════════════════════════════════════════════════ */

/* ── 1) تحويل الصفوف الموجودة للكود ────────────────────────────── */
delete from public.item_expiry e
 where exists (select 1 from public.branch_letters() b
                where b.name = e.branch
                  and exists (select 1 from public.item_expiry x
                               where x.branch = b.code and x.itm_code = e.itm_code
                                 and x.exp_date = e.exp_date));

update public.item_expiry e
   set branch = b.code
  from public.branch_letters() b
 where e.branch = b.name;

/* ── 2) حالة الفروع للمهمة بالكود ──────────────────────────────── */
delete from public.sync_branch_state
 where job_id = 'item_expiry'
   and branch in (select name from public.branch_letters());

insert into public.sync_branch_state (job_id, branch, enabled)
select 'item_expiry', b.code, true from public.branch_letters() b
on conflict (job_id, branch) do nothing;

/* ── 3) نص الاستعلام بالإنجليزي بالكامل ────────────────────────── */
update public.sync_jobs
   set steps = jsonb_build_array(jsonb_build_object(
         'select',
           'SELECT ''{branch}'' AS branch, t.itm_code, t.exp_date, t.qty FROM ('
           || 'SELECT itm_id AS itm_code, CONVERT(varchar(10), itm_expiry_date, 23) AS exp_date, SUM(itm_qty) AS qty '
           || 'FROM Item_Class_Store '
           || 'WHERE itm_qty > 0 AND itm_expiry_date IS NOT NULL '
           ||   'AND itm_expiry_date >= GETDATE() '
           ||   'AND itm_expiry_date < DATEADD(month, 36, GETDATE()) '
           ||   'AND sto_id = CASE ''{branch}'' '
           ||        'WHEN ''mamora'' THEN 1 '
           ||        'WHEN ''san''    THEN 26 '
           ||        'WHEN ''bishr''  THEN 28 '
           ||        'WHEN ''seyouf'' THEN 29 END '
           || 'GROUP BY itm_id, itm_expiry_date) t',
         'target',   'item_expiry',
         'conflict', 'branch,itm_code,exp_date')),
       updated_at = now()
 where id = 'item_expiry';

/* ── 4) الدالة بتترجم الكود لاسم ───────────────────────────────── */
create or replace function public.expiry_source_for(p_branch text, p_code text)
returns table (branch text, qty numeric, exp_date date)
language sql
stable
as $fn$
  select bl.name, e.qty, e.exp_date
    from public.item_expiry e
    join public.branch_letters() bl on bl.code = e.branch
    left join public.consumption_flat cf on cf.code = e.itm_code
   where e.itm_code = p_code
     and bl.name <> p_branch
     and e.synced_at > now() - interval '3 days'
     and e.exp_date >= current_date
     and e.exp_date <  current_date
         + ((select ps.expiry_months from public.purchase_settings ps where ps.id = 1)
            || ' months')::interval
     and e.qty > coalesce(
           case bl.code
             when 'mamora' then cf.av_mamora
             when 'san'    then cf.av_san
             when 'bishr'  then cf.av_bishr
             when 'seyouf' then cf.av_seyouf
           end, 0) * greatest(0.5, (e.exp_date - current_date) / 30.0)
   order by e.exp_date asc, e.qty desc
   limit 1
$fn$;

revoke all on function public.expiry_source_for(text, text) from public, anon;
grant execute on function public.expiry_source_for(text, text) to authenticated, service_role;
