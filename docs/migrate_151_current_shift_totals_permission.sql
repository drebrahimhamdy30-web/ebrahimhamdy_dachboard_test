/* ============================================================
   «تفاصيل الشيفت الحالي»: الإجماليات ونسخ الحركات بصلاحية
   ------------------------------------------------------------
   المطلوب: غير الأدمن يشوف الشيفت وحركاته **من غير إجماليات**،
   وما يقدرش ينسخ الحركات عشان ما يجمّعهاش في إكسل.

   ⚠️ الصلاحية مش هاردكود بالدور — نفس قاعدة migrate_123 للشاشة دي:
   بند في `app_page_tabs` فيظهر في شاشة الصلاحيات ويتفتح/يتقفل لأي
   دور من غير تعديل كود. البذرة: منع كل الأدوار ما عدا الأدمن
   (الأدمن دايمًا مسموح في tab_permissions).

   ⚠️ وحدود الحماية بصراحة: الحركات نفسها **لازم** تتبعت عشان تتعرض،
   فاللي عنده devtools يقدر يجمّعها. اللي بيتمنع هنا:
     • الإجماليات المحسوبة ما بتوصلش المتصفح أصلًا (مش إخفاء CSS).
     • النسخ/التحديد في الواجهة = مانع الطريق السهل لإكسل.
   يعني ده احتكاك مقصود، مش جدار.
   ============================================================ */

/* ١) بند الصلاحية في كتالوج التبويبات */
insert into public.app_page_tabs (page_key, tab_key, title, selector, sort_order)
/* sort_order عالي: guardTabs بتعتبر أول بند هو التبويب الافتراضي،
   والبند ده مش تبويب أصلًا فمالوش يبقى الأول. */
values ('current_shift','totals','الإجماليات ونسخ الحركات','.sumcard, .chips', 9)
on conflict (page_key, tab_key) do update
  set title = excluded.title, selector = excluded.selector, sort_order = excluded.sort_order;

/* ٢) البذرة: منع لكل دور غير الأدمن.
   ⚠️ الأدوار **تتقري من القاعدة** مش من قائمة مكتوبة بالإيد: أول
   محاولة كتبتها يدوي ونسيت `driver` و`preparer` — ومفيش صف منع معناه
   **مسموح**، يعني الدور المنسي كان هيشوف الإجماليات بصمت.
   do nothing مش do update — لو المالك فتحها لدور بعدين، إعادة تشغيل
   الترحيل ما تقفلهاش تاني. */
insert into public.tab_permissions (role, page_key, tab_key, allowed)
select r, 'current_shift', 'totals', false from (
  select distinct lower(btrim(role)) r from (
    select role from branch_users where role is not null
    union all select role from page_permissions
    union all select role from tab_permissions
  ) z where coalesce(btrim(role),'') <> '' and lower(btrim(role)) <> 'admin'
) q
on conflict (role, page_key, tab_key) do nothing;

/* ٣) الحارس — نفس منطق Session.tabAllowed بالظبط (مفيش صف منع = مسموح) */
create or replace function public.shift_totals_allowed()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select case when coalesce(jwt_app_role(),'') = 'admin' then true
              else not exists (select 1 from tab_permissions tp
                                where tp.role     = jwt_app_role()
                                  and tp.page_key = 'current_shift'
                                  and tp.tab_key  = 'totals'
                                  and tp.allowed  = false)
         end;
$$;

revoke all on function public.shift_totals_allowed() from public, anon;
grant execute on function public.shift_totals_allowed() to authenticated;

/* ٤) تعديل get_current_shift ليشيل الإجماليات من الرد نفسه.
   ------------------------------------------------------------
   الترحيل **بيرقّع النسخة الموجودة في القاعدة دي** بدل ما يحمل نسخة
   كاملة: القاعدتين مش على نفس الإصدار من الدالة، ونسخة كاملة هنا
   ممكن ترجّع واحدة منهم لورا بصمت. */
do $$
declare v_src text;
begin
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'get_current_shift';

  if v_src is null then
    raise notice 'get_current_shift غير موجودة — تخطّي الترقيع (طبّق migrate_118 أولًا).';
    return;
  end if;
  if position('shift_totals_allowed' in v_src) > 0 then
    raise notice 'الحارس مطبَّق بالفعل — لا تغيير.';
    return;
  end if;
  if position('  ) into v_out;' in v_src) = 0 then
    raise exception 'لم يُعثر على نقطة الإدراج في get_current_shift — راجع الدالة يدويًا.';
  end if;

  v_src := replace(v_src, '  ) into v_out;',
    '  ) into v_out;' || E'\n' ||
    '  /* ⚠️ مَن لا يملك «الإجماليات» لا تصله الأرقام المجمَّعة أصلًا —' || E'\n' ||
    '     إخفاء في الواجهة وحده يتركها في رد الشبكة. */' || E'\n' ||
    '  if not public.shift_totals_allowed() then' || E'\n' ||
    '    v_out := v_out - ''opening'' - ''cash_in'' - ''visa_in'' - ''sarf''' || E'\n' ||
    '                   - ''transfer_in'' - ''net_cash'' - ''account_net''' || E'\n' ||
    '                   - ''visa_by_channel'';' || E'\n' ||
    '  end if;');

  execute v_src;
  raise notice 'تم ترقيع get_current_shift بحارس الإجماليات.';
end $$;

/* ٥) قفل دوال الشيفت على المستخدم المسجَّل بدل anon.
   ------------------------------------------------------------
   ⚠️ من غير الخطوة دي الحارس بلا معنى: بمفتاح anon الدور بيبقى فاضي
   فالدالة بترجّع الإجماليات كاملة لأي حد معاه المفتاح. والشاشة نفسها
   كانت بتنادي بمفتاح anon — اتغيّرت لتوكن المستخدم في نفس الدفعة.
   الدوال دي مالهاش أي منادي تاني في الريبوهين. */
do $$
declare r record;
begin
  for r in select p.oid::regprocedure sig
             from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public'
              and p.proname in ('get_current_shift','get_shift_points','get_shift_log','get_shift_detail')
  loop
    execute format('revoke all on function %s from public, anon', r.sig);
    execute format('grant execute on function %s to authenticated', r.sig);
  end loop;
end $$;
