-- ═══════════════════════════════════════════════════════════════════
--  جرد السحابة الكامل: كل كائن، تصنيفه، ودوره
-- ═══════════════════════════════════════════════════════════════════
--  بيطلّع تقرير Markdown فيه كل حاجة على قاعدة السحابة: الجداول
--  والدوال والفيوهات والتريجرات والسياسات والكرونات والإضافات —
--  مصنّفة بالمجال، ومعاها دليل على دورها (مين بيلمسها، بتلمس إيه،
--  شغّالة بكرون، SECURITY DEFINER، مين له صلاحية).
--
--  ═══ ليه مولّد مش ملف ثابت ═══
--  التقرير الثابت بيقدم في أيام. في ٣ أيام بس (14→17 أكتوبر) زادت
--  ٢ كرون وجداول ودوال. وعندنا سابقة: الدليل كان مكتوب فيه «١٢ كرون»
--  وبقوا ١٩ — ورقم مكتوب بيقدم ومحدش بيحدّثه بيضلّل أكتر من إنه
--  مايكونش موجود.
--  فالتقرير بيتولّد من الكتالوج الحي كل مرة، وبيكتب تاريخه في أوله.
--
--  ═══ التصنيف مستنتج مش موصوف ═══
--  المجال بيتحدد من نمط الاسم (orders/stock/purchase/...)، والدور من
--  أدلة من القاعدة نفسها: الجدول بتلمسه كام دالة · الدالة بتلمس أنهي
--  جداول · شغّالة بكرون (⏱) · متعلّقة بتريجر (⚡) · مين له صلاحية.
--  يعني مفيش وصف من ذاكرتي — كله مقروء من القاعدة.
--
--  🔒 قراءة بس من السحابة عبر dblink. مابيعدّلش أي حاجة.
--
--  التشغيل (على السيرفر):
--    cd /root/supabase-project && docker exec -i $(docker compose ps -q db) \
--      psql -U supabase_admin -d postgres -At \
--      < /root/phalix-repo/docs/cloud_inventory.sql > /root/cloud_inventory.md
--    # وبعدها انسخه للريبو لو عايز تحفظه:
--    cp /root/cloud_inventory.md /root/phalix-repo/docs/
-- ═══════════════════════════════════════════════════════════════════

\set ON_ERROR_STOP on
\pset format unaligned
\pset tuples_only on
\pset pager off

select '# جرد قاعدة السحابة — كل كائن وتصنيفه ودوره' || chr(10) || chr(10)
    || '**اتولّد:** ' || to_char(now() at time zone 'Africa/Cairo', 'YYYY-MM-DD HH24:MI')
    || ' (توقيت القاهرة) · **المصدر:** `' ||
       coalesce((select current_setting('server_version')), '?') || '`' || chr(10) || chr(10)
    || '> التقرير ده **مولَّد من الكتالوج الحي** مش مكتوب بالإيد. أي رقم فيه'
    || ' بيعبّر عن اللحظة اللي اتولّد فيها بس — شغّله تاني بدل ما تعتمد عليه بعد أيام.'
    || chr(10) || chr(10) || '**إعادة التوليد:** `docs/cloud_inventory.sql`' || chr(10);

-- ═══ ١) الملخص ═════════════════════════════════════════════════════
select chr(10) || '## ١) الملخص' || chr(10) || chr(10)
    || '| النوع | العدد |' || chr(10) || '|---|---:|' || chr(10) || s
from dblink('cloud', $Q0$
  select string_agg(l, chr(10)) from (
    select '| جداول | ' || (select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace
            where n.nspname='public' and c.relkind in ('r','p'))::text || ' |' as l
    union all select '| أعمدة | ' || (select count(*) from pg_attribute a join pg_class c on c.oid=a.attrelid
            join pg_namespace n on n.oid=c.relnamespace where n.nspname='public'
            and c.relkind in ('r','p') and a.attnum>0 and not a.attisdropped)::text || ' |'
    union all select '| دوال (غير الإضافات) | ' || (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
            where n.nspname='public' and p.prokind in ('f','p')
            and not exists (select 1 from pg_depend d where d.objid=p.oid and d.deptype='e'))::text || ' |'
    union all select '| منها SECURITY DEFINER | ' || (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
            where n.nspname='public' and p.prosecdef
            and not exists (select 1 from pg_depend d where d.objid=p.oid and d.deptype='e'))::text || ' |'
    union all select '| فيوهات | ' || (select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace
            where n.nspname='public' and c.relkind in ('v','m'))::text || ' |'
    union all select '| تريجرات | ' || (select count(*) from pg_trigger t join pg_class c on c.oid=t.tgrelid
            join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and not t.tgisinternal)::text || ' |'
    union all select '| سياسات RLS | ' || (select count(*) from pg_policies where schemaname='public')::text || ' |'
    union all select '| جداول بلا RLS | ' || (select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace
            where n.nspname='public' and c.relkind in ('r','p') and not c.relrowsecurity)::text || ' |'
    union all select '| سيكوينسات | ' || (select count(*) from pg_sequences where schemaname='public')::text || ' |'
    union all select '| مهام cron | ' || (select count(*) from cron.job)::text ||
            ' (شغّالة: ' || (select count(*) from cron.job where active)::text || ') |'
    union all select '| إضافات | ' || (select count(*) from pg_extension)::text || ' |'
  ) x
$Q0$) as t(s);

-- ═══ ٢) الجداول ════════════════════════════════════════════════════
select chr(10) || '## ٢) الجداول — ' || chr(10) || chr(10)
    || '**الأعمدة:** `دوال بتلمسه` = كم دالة فيها اسم الجدول (مؤشّر على أهميته).'
    || ' `صلاحية` = مين غير service_role (و`anon` مفتاح عام في الشاشات).'
    || ' `RLS off` = الجدول مكشوف لو فيه صلاحية.' || chr(10) || chr(10)
    || '| المجال | الجدول | صفوف | أعمدة | يعتمد على | تريجرات | RLS | صلاحية | دوال بتلمسه |' || chr(10)
    || '|---|---|---:|---:|---|---:|---|---|---:|' || chr(10) || s
from dblink('cloud', $Q1$
with t as (
  select c.oid, c.relname as nm, c.relrowsecurity as rls,
    case
      when c.relname ~ '^(orders|trips|trip_|driver|dispatch|regions|order_|routes|route_)' then 'توصيل وطلبات'
      when c.relname ~ '^(stock|branch_stock|item|known_item|jard|sip_|store|archived|ex_arch|overstock)' then 'مخزون وجرد'
      when c.relname ~ '^(purchase|pur_|consumption|best_purchase|medicine|vendor|supplier|pharma|ibnsina|new_branch|claim_|demand|category_rate|branch_calc|branch_goods|branch_transfers|pinned|code_)' then 'مشتريات وموردين'
      when c.relname ~ '^(customer|gift|problem)' then 'عملاء'
      when c.relname ~ '^(sales|monthly_sales|returns_log|contract|crm_|claims|imported_sales|price_changes|offers|material)' then 'مبيعات ومرتجعات وتعاقدات'
      when c.relname ~ '^(pos_|wallet|bank_|cash_|links|machine|shift|cashier|paymob|eplus_pos)' then 'نقاط بيع ومالية'
      when c.relname ~ '^(app_|page_|tab_|branch_users|branch_sessions|branch_scope|org_|role_|branches|notification|password_|instructions)' then 'نظام وصلاحيات'
      when c.relname ~ '(_log$|^sync_|^migration_|^cloud_sync|backup|_staging$|needs_review|_runs$|integration)' then 'مزامنة وسجلات وأدوات'
      when c.relname ~ '^(task|transfer|expen|shortage|erp_|missing)' then 'مهام ومصروفات'
      else 'غير مصنّف'
    end as dom
  from pg_class c join pg_namespace n on n.oid=c.relnamespace
  where n.nspname='public' and c.relkind in ('r','p')
)
select string_agg(line, chr(10) order by dom, nm) from (
  select t.dom, t.nm,
    '| ' || t.dom || ' | `' || t.nm || '` | ' ||
    coalesce((select s.n_live_tup from pg_stat_user_tables s where s.relid=t.oid),0)::text || ' | ' ||
    (select count(*) from pg_attribute a where a.attrelid=t.oid and a.attnum>0 and not a.attisdropped)::text || ' | ' ||
    coalesce(nullif((select string_agg(distinct cl.relname, ', ')
       from pg_constraint k join pg_class cl on cl.oid=k.confrelid
       where k.conrelid=t.oid and k.contype='f'),''),'—') || ' | ' ||
    (select count(*) from pg_trigger g where g.tgrelid=t.oid and not g.tgisinternal)::text || ' | ' ||
    case when t.rls then 'on' else '**off**' end || ' | ' ||
    coalesce(nullif((select string_agg(distinct
        case when a.grantee=0 then 'PUBLIC' else pg_get_userbyid(a.grantee) end, '+')
       from pg_class c2, aclexplode(c2.relacl) a
       where c2.oid=t.oid and (a.grantee=0 or pg_get_userbyid(a.grantee) in ('anon','authenticated'))),''),'—') || ' | ' ||
    (select count(*) from pg_proc p join pg_namespace pn on pn.oid=p.pronamespace
       where pn.nspname='public' and p.prosrc ~ ('\m'||t.nm||'\M'))::text || ' |' as line
  from t
) x
$Q1$) as t(s);

-- ═══ ٣) الدوال ═════════════════════════════════════════════════════
select chr(10) || '## ٣) الدوال' || chr(10) || chr(10)
    || '**الرموز:** ⏱ = بتتنادى من cron · ⚡ = متعلّقة بتريجر ·'
    || ' `DEFINER` = بتشتغل بصلاحيات مالكها (تغييرها تغيير أمان مش منطق).'
    || chr(10) || chr(10)
    || '| التصنيف | الدالة | بترجّع | امتياز | بتلمس | |' || chr(10)
    || '|---|---|---|---|---|---|' || chr(10) || s
from dblink('cloud', $Q2$
with f as (
  select p.oid, p.proname nm, pg_get_function_identity_arguments(p.oid) args,
         p.prosecdef sd, p.prosrc src, pg_get_function_result(p.oid) ret,
         case
           when p.proname ~ '^(trg_|notify_|prevent_|check_|propagate_|protect_|stamp_|enrich_|touch_|update_last|ci_freeze|item_expiry_stamp|set_.*updated_at|set_return_value|set_task_updated|sync_(driver_is_online|page_permission_key|branch_user_to_auth|collection_returns)|invalidate_trip_cash)' then 'تريجر'
           when p.proname ~ '^(get_|list_|report_|sales_|delivery_|jard_counted|jard_uncounted|item_|price_check|best_store|lookup_|suggest_|compare_|quick_search|search_|expiry_source)' then 'قراءة وتقارير'
           when p.proname ~ '^(refresh_|topup_|compute_|sweep_|cleanup_|close_stale|recover_|shadow_|ensure_|rebind_|stage_|commit_|apply_|build_|purchase_(map_build|stage))' then 'صيانة وإعادة بناء'
           when p.proname ~ '^(admin_|manager_|require_|jwt_|change_|reset_|verify_|resolve_login|create_password|save_|set_driver|.*_branch_scope|bank_can_use|bank_actor)' then 'صلاحيات ودخول'
           when p.proname ~ '^(submit_|insert_|update_|delete_|upload_|add_|match_|merge_|unmerge_|unmatch_|move_|transfer_|manual_|web_driver|mark_|resolve_jard|bank_|pos_|store_|restore_|close_supplier|reopen_supplier|supplier_link|prep_|wallet_set|set_(order_region|stock_limit|expense|expiry|pinned|vendor))' then 'كتابة وإجراءات'
           else 'أدوات ومساعدات'
         end dom
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.prokind in ('f','p')
    and not exists (select 1 from pg_depend d where d.objid=p.oid and d.deptype='e')
)
select string_agg(line, chr(10) order by dom, nm) from (
  select f.dom, f.nm,
    '| ' || f.dom || ' | `' || f.nm || '(' || left(f.args,46) || ')` | ' ||
    left(replace(f.ret,'TABLE','جدول'),26) || ' | ' ||
    case when f.sd then '**DEFINER**' else 'invoker' end || ' | ' ||
    coalesce(nullif((select string_agg(x.rel, ', ') from (
       select c.relname rel from pg_class c join pg_namespace cn on cn.oid=c.relnamespace
       where cn.nspname='public' and c.relkind in ('r','p','v')
         and f.src ~ ('\m'||c.relname||'\M') order by length(c.relname) desc limit 4
     ) x),''),'—') || ' | ' ||
    case when exists (select 1 from cron.job j where j.command ~ ('\m'||f.nm||'\M')) then '⏱' else '' end ||
    case when exists (select 1 from pg_trigger g where not g.tgisinternal and g.tgfoid=f.oid) then '⚡' else '' end || ' |' as line
  from f
) y
$Q2$) as t(s);

-- ═══ ٤) الفيوهات · ٥) التريجرات · ٦) الكرونات · ٧) الإضافات ═══════
select chr(10) || '## ٤) الفيوهات' || chr(10) || chr(10)
    || '| الفيو | أعمدة | التعريف (مقتطف) |' || chr(10) || '|---|---:|---|' || chr(10) || v
    || chr(10) || chr(10) || '## ٥) التريجرات' || chr(10) || chr(10)
    || '> ⚠️ على **السيرفر** لازم تريجرات الإشعارات وتقييم الأداء تفضل **معطّلة**'
    || ' لحد لحظة التحويل — وإلا الطيار ياخد الإشعار مرتين والنداءات الخارجية تتكلف مرتين.'
    || chr(10) || chr(10)
    || '| الجدول | التريجر | الحالة | الدالة | وقت التنفيذ |' || chr(10)
    || '|---|---|---|---|---|' || chr(10) || g
    || chr(10) || chr(10) || '## ٦) مهام cron' || chr(10) || chr(10)
    || '> `cutover.sh go` بيجدولهم **كلهم** من `v_migration_post` (فيو حي) بعنوان السيرفر.'
    || ' العدد بيزيد — ماتعتمدش على رقم مكتوب.' || chr(10) || chr(10)
    || '| المهمة | الجدولة | الحالة | الأمر |' || chr(10) || '|---|---|---|---|' || chr(10) || c
    || chr(10) || chr(10) || '## ٧) الإضافات' || chr(10) || chr(10) || e || chr(10)
from dblink('cloud', $Q3$
select
 (select string_agg('| `'||c.relname||'` | '||
    (select count(*) from pg_attribute a where a.attrelid=c.oid and a.attnum>0 and not a.attisdropped)::text||' | '||
    left(regexp_replace(pg_get_viewdef(c.oid,true),'\s+',' ','g'),130)||' |', chr(10) order by c.relname)
  from pg_class c join pg_namespace n on n.oid=c.relnamespace
  where n.nspname='public' and c.relkind in ('v','m')),
 (select string_agg('| `'||cl.relname||'` | `'||t.tgname||'` | '||
    case t.tgenabled when 'D' then '**معطّل**' else 'شغّال' end||' | `'||p.proname||'` | '||
    case when (t.tgtype & 2)>0 then 'BEFORE' else 'AFTER' end||' '||
    concat_ws('/', case when (t.tgtype & 4)>0 then 'INSERT' end,
                   case when (t.tgtype & 8)>0 then 'DELETE' end,
                   case when (t.tgtype & 16)>0 then 'UPDATE' end)||' |', chr(10) order by cl.relname, t.tgname)
  from pg_trigger t join pg_class cl on cl.oid=t.tgrelid
  join pg_namespace n on n.oid=cl.relnamespace join pg_proc p on p.oid=t.tgfoid
  where n.nspname='public' and not t.tgisinternal),
 (select string_agg('| `'||coalesce(j.jobname,j.jobid::text)||'` | `'||j.schedule||'` | '||
    case when j.active then 'شغّال' else '**موقوف**' end||' | '||
    left(regexp_replace(j.command,'\s+',' ','g'),85)||' |', chr(10) order by j.jobid)
  from cron.job j),
 (select string_agg('`'||e.extname||'` '||e.extversion, ' · ' order by e.extname) from pg_extension e)
$Q3$) as t(v text, g text, c text, e text);

select chr(10) || '---' || chr(10)
    || '**تنبيه:** الأرقام أعلاه لحظة التوليد. شغّل `docs/cloud_inventory.sql` تاني'
    || ' قبل أي قرار مبني عليها.' || chr(10);
