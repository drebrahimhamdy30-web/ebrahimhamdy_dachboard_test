/* ════════════════════════════════════════════════════════════════
   إلغاء «لم يصل من الشركات»  (2026-10-28)
   ----------------------------------------------------------------
   قرار المالك: الميزة مالهاش لازمة — تتشال من الشاشات ويتحذف
   جدولها. اللي اتشال من الكود: زرار النوع وقسم حقوله في
   `main.html` · شاشة `missing_items.html` كاملة · دوال
   `sbMissingInsert/Update/List` و`fetchMissing` في `api.js` ·
   الأيقونة في قايمة التوصيل · مؤشر «أصناف لم تصل من الشركات» في
   لوحة المؤشرات.

   ⚠️ الجدول كان فيه **١٣٦ صف** (٥ مايو ← ١٣ أكتوبر ٢٠٢٦، منهم ٦٧
   لسه مفتوحين)، فالحذف بيتعمل بعد نسختين: ملف CSV عند المالك،
   وجدول `zz_archive_missing_items_20261028` جوّه القاعدة (محجوب
   عن anon و authenticated). امسح جدول الأرشيف لما تطمن.

   ⚠️ `get_kpi_dashboard` كانت بتقرا من `missing_items`، فالحذف من
   غير تعديلها كان هيوقّع لوحة المؤشرات كلها مش المؤشر ده بس.
   التعديل بيتعمل على تعريف الدالة نفسه بـreplace عشان ما نعيدش
   كتابة ١٩٠ سطر بإيدينا ونغلط في سطر منهم.

   يتطبّق على: السحابة (اتعمل 2026-10-28) **و** السيرفر الذاتي.
   ════════════════════════════════════════════════════════════════ */

begin;

/* ── 1) الأرشيف قبل أي حذف ─────────────────────────────────── */
create table if not exists public.zz_archive_missing_items_20261028 as
  select * from public.missing_items;
revoke all on public.zz_archive_missing_items_20261028 from public, anon, authenticated;

/* ── 2) شيل المؤشر من get_kpi_dashboard قبل حذف الجدول ─────── */
do $out$
declare def text;
begin
  select pg_get_functiondef('public.get_kpi_dashboard'::regproc) into def;

  def := replace(def,
E'  miss AS (\n    SELECT bk.name AS branch, (m.created_at AT TIME ZONE \'Africa/Cairo\')::date AS day,\n           count(*) AS missing_items\n      FROM missing_items m JOIN bk ON bk.k = replace(m.branch, \'ي\', \'ى\')\n     WHERE m.created_at >= t0 AND m.created_at < t1\n     GROUP BY 1, 2\n  ),\n', '');

  def := replace(def,
    'UNION SELECT branch, day FROM ci UNION SELECT branch, day FROM miss UNION SELECT branch, day FROM tdone',
    'UNION SELECT branch, day FROM ci UNION SELECT branch, day FROM tdone');

  def := replace(def,
    E'           \'missing_items\', m.missing_items, \'tasks_done\', d.tasks_done,',
    E'           \'tasks_done\', d.tasks_done,');

  def := replace(def,
    E'    LEFT JOIN miss  m ON m.branch = k.branch AND m.day = k.day\n', '');

  /* حارس: لو نسخة الدالة هنا مختلفة ومافيش replace اشتغل، نوقف
     بدل ما نسيب الدالة بتشاور على جدول هيتحذف بعد سطرين */
  if position('missing_items' in def) > 0 then
    raise exception 'تعريف get_kpi_dashboard مختلف — عدّله يدويًا وبعدين كمّل';
  end if;

  execute def;
end $out$;

/* ── 3) الحذف ──────────────────────────────────────────────── */
drop table public.missing_items;

delete from public.page_permissions where page_key = 'missing_items';
delete from public.app_pages        where key      = 'missing_items';

commit;
