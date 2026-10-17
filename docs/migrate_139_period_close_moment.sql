/* ============================================================
   إقفال الفترة: لحظة بدل تاريخ — (١) العمود ودوال الحساب
   ------------------------------------------------------------
   المراجع بيقفل **الورديات اللي اتقفلت فعلًا** لحد ساعته. الوردية
   الشغّالة (اللي هتتقفل بعدين) مالهاش علاقة بالمراجعة، فمفروض ما
   تتأثرش بالإقفال.

   النظام كان بيخزّن **تاريخ** بس، والحارس بيقارن بالتاريخ — فإقفال
   «لحد 17-10» معناه «اليوم كله مجمّد»، فيمسك ورديات ماكانتش موجودة
   أصلًا وقت المراجعة. حصل 2026-10-17: الإقفال اتعمل ٣:٢٧ الفجر
   بتاريخ نفس اليوم، فكل وردية بتتقفل النهاردة اترفضت
   («الفترة مقفولة لفرع المعمورة لحد 2026-10-17»).

   الحل: نخزّن **لحظة** (upto_at) ونقارن بيها.

   ⚠️ الإقفالات القديمة بتتملي بنهاية يومها بتوقيت القاهرة — يعني
   **نفس** حكم المقارنة بالتاريخ بالظبط، فمفيش صف تاريخي بيتغيّر.

   اتأكدت بالقياس: pos_balance_at(branch, نهاية اليوم) =
   pos_balance_upto(branch, اليوم) على **كل** الإقفالات العشرة.

   الجزء التاني (الحارس ودالة الإقفال) في migrate_140.
   ============================================================ */
alter table public.pos_period_closes
  add column if not exists upto_at timestamptz;

update public.pos_period_closes
   set upto_at = ((upto + 1)::timestamp at time zone 'Africa/Cairo')
 where upto_at is null;

create or replace function public.pos_last_close_at(p_branch text)
returns timestamptz
language sql stable security definer
set search_path to 'public', 'pg_temp'
as $fn$
  select max(c.upto_at) from pos_period_closes c
   where c.reopened_at is null
     and replace(c.branch, 'ي', 'ى') = replace(btrim(coalesce(p_branch, '')), 'ي', 'ى');
$fn$;

/* الرصيد لحد لحظة — نفس منطق pos_balance_upto بالحرف، الفرق إن الحد
   الأعلى لحظة مش نهاية يوم. */
create or replace function public.pos_balance_at(p_branch text, p_at timestamptz)
returns numeric
language sql stable security definer
set search_path to 'public', 'pg_temp'
as $fn$
  with b as (select replace(btrim(coalesce(p_branch, '')), 'ي', 'ى') as k),
  opening as (
    select coalesce(max(o.opening_balance), 0) as amt,
           coalesce(max(o.as_of), date '2000-01-01') as as_of
      from pos_branch_opening o, b where replace(o.branch, 'ي', 'ى') = b.k
  ),
  bounds as (
    select (op.as_of::timestamp at time zone 'Africa/Cairo') as lo, p_at as hi, op.amt
      from opening op
  ),
  closures as (
    select coalesce(sum(s.grand_total), 0) as amt
      from pos_shifts s, b, bounds w
     where replace(s.branch, 'ي', 'ى') = b.k
       and coalesce(s.closed_at, ((s.shift_date + 1)::timestamp at time zone 'Africa/Cairo'))
             between w.lo and w.hi
  ),
  wallets as (
    select coalesce(sum(t.amount), 0) as amt
      from pos_wallet_transfers t, b, bounds w
     where replace(t.branch, 'ي', 'ى') = b.k
       and t.created_at between w.lo and w.hi
  ),
  manuals as (
    select coalesce(sum(m.amount), 0) as amt
      from pos_manual_transfers m, b, bounds w
     where replace(m.branch, 'ي', 'ى') = b.k
       and m.txn_date between w.lo and w.hi
  )
  select round((select amt from bounds) + (select amt from closures)
              - (select amt from wallets) - (select amt from manuals), 2);
$fn$;

revoke all on function public.pos_last_close_at(text) from public, anon;
revoke all on function public.pos_balance_at(text, timestamptz) from public, anon;
grant execute on function public.pos_last_close_at(text) to authenticated, service_role;
grant execute on function public.pos_balance_at(text, timestamptz) to authenticated, service_role;
