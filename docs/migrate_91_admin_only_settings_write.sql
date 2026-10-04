/* ═══════════════════════════════════════════════════════════════════
   الكتابة على الفروع وإعدادات المؤسسة للأدمن بس
   ═══════════════════════════════════════════════════════════════════
   يكمّل 89 و90. بعدهم بقت القراءة مفتوحة (لازمة قبل تسجيل الدخول:
   brand.js بيجيب الهوية في صفحة الدخول، وbranches.js بيتحمّل في كل
   شاشة) لكن **الكتابة كانت لأي حساب مسجّل** — كاشير، طيار، أي حد.

   الحماية كانت في المتصفح بس: الشاشتين مقصورتين على الأدمن في
   `page_permissions`، لكن ده إخفاء مش منع — أي مستخدم يفتح كونسول
   المتصفح ويبعت PATCH والقاعدة تقبله.

   خطر حذف صف من `branches` أكبر من تغيير اسم: الشاشات اللي بتفلتر
   بالفرع بترجّع صفر صف، وده بيبان «النظام باظ» مش «حد عدّل حاجة».

   ── اتفحص قبل التطبيق ────────────────────────────────────────────
   • مين بيكتب فعليًا: `org_settings.html` و`delivery/pages/branches.html`
     وبس — والاتنين صلاحيتهم `admin ✏️` في page_permissions. فمفيش
     دور تاني هيتكسر.
   • `jwt_app_role()` بتقرا `user_role` من التوكن (top-level لدخول n8n،
     أو جوّه `app_metadata` لدخول سوبابيز).
   • كل الـ96 حساب عندهم `user_role` متكتب — **مفيش حساب فاضي** يتقفل
     بالغلط. وحساب الأدمن واحد ودوره `admin` بالحرف.

   ── اتجرّب بعد التطبيق ───────────────────────────────────────────
   بتقمّص الدور داخل القاعدة:
     كاشير → org_settings و branches:  0 صف  (اترفض) ✅
     أدمن  → org_settings و branches:  1 و 4 صف (عدّى) ✅

   ⚠️ لو اتقفل غلط يومًا ما: `service_role` بيتخطى RLS، فالإصلاح من
      SQL Editor مباشرةً. وفيه حساب أدمن **واحد** بس — لو ضاع، ده
      الطريق الوحيد.

   يتطبّق على: السحابة **و** السيرفر الذاتي.
   ═══════════════════════════════════════════════════════════════════ */

do $$
declare t text;
begin
  foreach t in array array['branches','org_settings']
  loop
    execute format('drop policy if exists %I on public.%I', t || '_auth_write',  t);
    execute format('drop policy if exists %I on public.%I', t || '_admin_write', t);
    execute format(
      'create policy %I on public.%I for all to authenticated '
      || 'using (public.jwt_app_role() = ''admin'') '
      || 'with check (public.jwt_app_role() = ''admin'')',
      t || '_admin_write', t);
  end loop;
end $$;

select c.relname as الجدول, pol.polname as السياسة,
       case pol.polcmd when 'r' then 'قراءة' else 'الكل' end as الأمر,
       pg_get_expr(pol.polqual, pol.polrelid) as الشرط
  from pg_policy pol
  join pg_class c on c.oid = pol.polrelid
  join pg_namespace n on n.oid = c.relnamespace
 where n.nspname = 'public' and c.relname in ('branches','org_settings')
 order by c.relname, pol.polname;
