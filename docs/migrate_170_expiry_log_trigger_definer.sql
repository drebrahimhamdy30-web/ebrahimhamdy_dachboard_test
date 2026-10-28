/* ═══════════════════════════════════════════════════════════════════
   إصلاح عاجل: تريجر سجل الصلاحيات كان بيوقف المزامنة (403)
   ═══════════════════════════════════════════════════════════════════
   ── العطل ────────────────────────────────────────────────────────
   `migrate_165` ضاف تريجر على `item_expiry` بيكتب كل تغيّر كمية في
   `item_expiry_log`. الجدول اتعمل بترحيل، و**الجداول اللي بتتعمل
   بترحيل مابتاخدش صلاحيات كتابة تلقائيًا** لـ`service_role` —
   `SELECT` بس. والتريجر `SECURITY INVOKER`، يعني بينفّذ بصلاحية
   اللي بيكتب.

   النتيجة: محرّك المزامنة (بمفتاح `service_role`) كل ما يحاول
   `UPSERT` على `item_expiry`، التريجر يحاول يكتب في السجل، فيترفض،
   والـUPSERT كله يفشل:

     UPSERT .../rest/v1/item_expiry?on_conflict=... -> (403) Forbidden

   **كل الفروع الأربعة وقفت.** آخر مزامنة ناجحة 27/10 الساعة 5:51م،
   وكل محاولة بعدها فشلت (8 محاولات). يعني تواريخ الصلاحية كانت
   هتفضل مجمّدة من غير ما حد ياخد باله — المزامنة بتسجّل الخطأ في
   `sync_runs` بس الشاشة ماكانتش هتقول حاجة.

   ── الإصلاح ─────────────────────────────────────────────────────
   التريجر بقى **`SECURITY DEFINER`** — الكتابة في سجل التدقيق
   مالهاش علاقة بصلاحيات اللي بيكتب في الجدول الأصلي. وده أنضف من
   إننا ندّي `service_role` كتابة مباشرة على السجل، لأن السجل
   **يُلحق بالتريجر بس** ومحدش يكتب فيه مباشرة.

   `set search_path` إلزامي مع DEFINER عشان مايتخطفش بـschema تاني.

   ── الدرس ───────────────────────────────────────────────────────
   أي تريجر بيكتب في جدول تاني لازم يبقى DEFINER، وإلا بيورّث
   متطلبات صلاحيات مخفية لكل من يكتب في الجدول الأصلي.
   راجع [[grant-vs-rls-403]] و[[n8n-inventory-webhook-migration]].

   يتطبّق على: السحابة **و** السيرفر الذاتي.
   ═══════════════════════════════════════════════════════════════════ */

create or replace function public.item_expiry_stamp()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare v_day date := (now() at time zone 'Africa/Cairo')::date;
begin
  new.synced_at := now();
  new.last_seen := v_day;

  if tg_op = 'INSERT' then
    new.first_seen := coalesce(new.first_seen, v_day);
    insert into public.item_expiry_log(branch, itm_code, exp_date, day, qty_before, qty_after, diff, kind)
    values (new.branch, new.itm_code, new.exp_date, v_day, null, new.qty, new.qty, 'new');

  else
    new.first_seen := coalesce(old.first_seen, v_day);
    /* الكمية بس هي اللي تستاهل سطر — إعادة مزامنة بنفس الرقم مش حدث */
    if new.qty is distinct from old.qty then
      insert into public.item_expiry_log(branch, itm_code, exp_date, day, qty_before, qty_after, diff, kind)
      values (new.branch, new.itm_code, new.exp_date, v_day, old.qty, new.qty, new.qty - old.qty, 'change');
    end if;
  end if;

  return new;
end$fn$;

/* السجل يُكتب بالتريجر فقط — مفيش كتابة مباشرة لأي دور */
revoke insert, update, delete on public.item_expiry_log from anon, authenticated, service_role;
grant select on public.item_expiry_log to authenticated, service_role;

notify pgrst, 'reload schema';
