/* ═══════════════════════════════════════════════════════════════════
   قفل الجداول المكشوفة على anon
   ═══════════════════════════════════════════════════════════════════
   الـanon key منشور في ريبو عام (GitHub Pages مجاني — راجع
   public-repos-and-hosting)، يعني أي حد يقدر يناديه. والفحص
   (2026-10-04) لقى 10 جداول سياستها `true` لدور anon:

     قراءة وكتابة كاملة:
       customers            ← أسماء وتليفونات وأرصدة العملاء ⚠️ الأخطر
       claims · cash_to_wallet · trip_cash_settlement  ← سجلات مالية
       links · branches · org_settings
     قراءة فقط:
       app_control · app_pages · driver_app_version

   باقي الـ148 جدول محميين (133 عليهم RLS بسياسات مقيّدة) — فالمشكلة
   محصورة في العشرة دول.

   ── اللي بيتعمل ──────────────────────────────────────────────────
   مجموعة أ — anon يتشال خالص (authenticated بس):
     customers · claims · cash_to_wallet · trip_cash_settlement · links
     كلهم بيتنادوا من شاشات ورا تسجيل دخول، اتأكدنا واحدة واحدة.
     ⚠️ `links` في تطبيق الطيار اسم **متغيّر محلي** لصفوف trip_orders
        مش الجدول ده — اتفحص قبل القفل.

   مجموعة ب — قراءة anon تفضل، الكتابة تبقى authenticated:
     branches · org_settings
     لازم يتقروا **قبل تسجيل الدخول**: brand.js بيجيب الهوية والألوان
     في كل صفحة بما فيها صفحة الدخول، وbranches.js بيتحمّل في كل مكان.

   مابنلمسش: app_control · app_pages · driver_app_version
     قراءة anon لازمة (فحص نسخة تطبيق الطيار بيتم قبل الدخول، وقائمة
     الصفحات والمفتاح العام بيتقروا وقت الإقلاع)، ومفيش سياسة كتابة
     عليهم أصلًا.

   ── الأثر المتوقع على المستخدم ──────────────────────────────────
   `sbH()` في api.js **بترجع لمفتاح anon لو التوكن انتهى** (مقصود عشان
   العرض مايقعش). بعد الترحيل ده الشاشات دي هترجّع 401 بدل بيانات لما
   الجلسة تموت — وده السلوك الصح، والكود متوقّعه: `sbFailMsg()` بيحوّل
   401/403 لرسالة «جلستك انتهت». الشِل بيجدّد التوكن كل 5 دقايق فالحالة
   دي نادرة.

   الكتابة للأدمن بس لسه مش متعملة (org_settings/branches مفتوحين لأي
   مستخدم مسجّل) — خطوة تانية منفصلة.

   يتطبّق على: السحابة **و** السيرفر الذاتي.
   ═══════════════════════════════════════════════════════════════════ */

/* ── مجموعة أ: authenticated بس ─────────────────────────────────── */
do $$
declare t text;
begin
  foreach t in array array['customers','claims','cash_to_wallet','trip_cash_settlement','links']
  loop
    if to_regclass('public.' || quote_ident(t)) is null then
      raise notice 'مش موجود — تخطّي: %', t;  continue;
    end if;

    execute format('alter table public.%I enable row level security', t);

    /* نشيل أي سياسة بتدي anon دخول مفتوح */
    execute format('drop policy if exists %I on public.%I', t || '_all_anon', t);
    execute format('drop policy if exists %I on public.%I', t || '_all',      t);
    execute format('drop policy if exists %I on public.%I', 'c2w_all_anon',   t);
    execute format('drop policy if exists %I on public.%I', 'tcs_all',        t);

    execute format('drop policy if exists %I on public.%I', t || '_auth_all', t);
    execute format(
      'create policy %I on public.%I for all to authenticated using (true) with check (true)',
      t || '_auth_all', t);

    execute format('revoke all on public.%I from anon', t);
    raise notice 'اتقفل على anon: %', t;
  end loop;
end $$;

/* ── مجموعة ب: قراءة anon تفضل، الكتابة authenticated ───────────── */
do $$
declare t text;
begin
  foreach t in array array['branches','org_settings']
  loop
    if to_regclass('public.' || quote_ident(t)) is null then continue; end if;

    execute format('alter table public.%I enable row level security', t);

    /* السياسات المفتوحة للكتابة */
    execute format('drop policy if exists %I on public.%I', 'allow_all_branches', t);
    execute format('drop policy if exists %I on public.%I', 'anon_write_org',     t);

    /* قراءة للكل — لازمة قبل تسجيل الدخول */
    execute format('drop policy if exists %I on public.%I', t || '_read_all', t);
    execute format(
      'create policy %I on public.%I for select to anon, authenticated using (true)',
      t || '_read_all', t);

    /* الكتابة للمسجّلين بس */
    execute format('drop policy if exists %I on public.%I', t || '_auth_write', t);
    execute format(
      'create policy %I on public.%I for all to authenticated using (true) with check (true)',
      t || '_auth_write', t);

    /* anon يقرا بس — مفيش insert/update/delete حتى لو السياسة اتفكّت */
    execute format('revoke all on public.%I from anon', t);
    execute format('grant select on public.%I to anon', t);
    raise notice 'قراءة فقط لـanon: %', t;
  end loop;
end $$;

/* ── التحقق ─────────────────────────────────────────────────────── */
select c.relname as الجدول,
       count(*) filter (where exists (
         select 1 from unnest(pol.polroles) rr join pg_roles r on r.oid = rr
          where r.rolname in ('anon','public'))) as سياسات_لanon,
       has_table_privilege('anon', c.oid, 'SELECT') as anon_select,
       has_table_privilege('anon', c.oid, 'INSERT') as anon_insert
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  left join pg_policy pol on pol.polrelid = c.oid
 where n.nspname = 'public'
   and c.relname in ('customers','claims','cash_to_wallet','trip_cash_settlement',
                     'links','branches','org_settings')
 group by c.relname, c.oid
 order by c.relname;
