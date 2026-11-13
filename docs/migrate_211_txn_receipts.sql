-- ═══════════════════════════════════════════════════════════════════
--  عمود «صورة التحويل» في تبويبي البطاقات والمحافظ
-- ═══════════════════════════════════════════════════════════════════
--  الموظف اللي عمل التحويل بيرفق صورته ساعتها، والمراجع بيشوفها بعدين
--  جنب «الدليل» المكتوب — فالإقفال بيبقى وراه إثبات مش كلام.
--
--  ⚠️ الصورة **مش** على صف المراجعة (`shift_txn_reviews` /
--     `wallet_txn_reviews`): الموظف بيرفق **قبل** ما المراجعة تحصل،
--     وساعتها صف المراجعة لسه مش موجود أصلًا. فجدول مستقل مربوط
--     بالحركة نفسها.
--
--  ⚠️ الـbucket **خاص مش عام**: الإيصالات فيها مبالغ وأسماء عملاء،
--     والرابط العام بيفضل شغّال للأبد ولأي حد يوصله. العرض من الشاشة
--     برابط موقّع بيعيش ١٠ دقايق.
--
--  ومفيش حذف من المتصفح — الصورة دليل. لو اترفعت صورة غلط بترفع
--  غيرها والشاشة بتعرض الأحدث، والقديمة بتفضل محفوظة.
--
--  الحارس هو `shift_can_review()` نفسه (أدمن أو صلاحية شاشة
--  `current_shift`) — مش حارس أوسع: اللي بيقدر يراجع هو اللي بيقدر
--  يرفق.
--
--  ⚠️ اتطبّق على السحابة 2026-11-13 تحت أسماء migrate_209*
--     (الرقم ٢٠٩ كان محجوز في `docs/` واتكشف بعدها) — الملف ده هو
--     المرجع، ولازم يتطبّق على **الذاتي** كمان:
--       cd /root/supabase-project && docker exec -i $(docker compose ps -q db) \
--         psql -U supabase_admin -d postgres -f - \
--         < /root/phalix-repo/docs/migrate_211_txn_receipts.sql
-- ═══════════════════════════════════════════════════════════════════

create table if not exists public.txn_receipts (
  id          bigint generated always as identity primary key,
  kind        text        not null check (kind in ('card','wallet')),
  branch      text        not null,
  ref_id      text        not null,   -- fh_id للبطاقات · src:id للمحافظ
  path        text        not null,   -- المسار جوّه bucket «receipts»
  mime        text,
  bytes       integer,
  uploaded_by text        not null,
  uploaded_at timestamptz not null default now()
);

comment on table public.txn_receipts is
  'صور تحويلات مرفقة على حركات البطاقات/المحافظ. الموظف يرفق والمراجع يشوف. الملف نفسه في bucket «receipts» الخاص.';

create index if not exists txn_receipts_lookup
  on public.txn_receipts (kind, branch, ref_id, uploaded_at desc);

alter table public.txn_receipts enable row level security;
drop policy if exists txn_receipts_read on public.txn_receipts;
create policy txn_receipts_read on public.txn_receipts
  for select to authenticated using (true);

grant select on public.txn_receipts to authenticated;

-- ── الـbucket ──────────────────────────────────────────────────────
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('receipts', 'receipts', false, 5242880,
        array['image/jpeg','image/png','image/webp','image/heic','application/pdf'])
on conflict (id) do update
  set public = false,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

/* رفع وقراءة للمستخدم المسجّل. مفيش update ولا delete — الدليل
   مايتمسحش من المتصفح. */
drop policy if exists receipts_insert on storage.objects;
create policy receipts_insert on storage.objects
  for insert to authenticated with check (bucket_id = 'receipts');

drop policy if exists receipts_select on storage.objects;
create policy receipts_select on storage.objects
  for select to authenticated using (bucket_id = 'receipts');

-- ── الدوال ────────────────────────────────────────────────────────
create or replace function public.attach_txn_receipt(
  p_kind   text,
  p_branch text,
  p_ref_id text,
  p_path   text,
  p_mime   text default null,
  p_bytes  integer default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_actor text; v_id bigint;
begin
  if not public.shift_can_review() then
    raise exception 'غير مصرّح بإرفاق صور التحويل';
  end if;
  if p_kind not in ('card','wallet') then
    raise exception 'نوع غير معروف: %', p_kind;
  end if;
  v_actor := public.bank_actor();

  insert into public.txn_receipts(kind, branch, ref_id, path, mime, bytes, uploaded_by)
  values (p_kind, p_branch, p_ref_id::text, p_path, p_mime, p_bytes, v_actor)
  returning id into v_id;

  /* `success` مطلوبة — rpcWrite في الشاشة بترفض أي رد من غيرها */
  return jsonb_build_object('success', true, 'id', v_id, 'path', p_path,
           'uploaded_by', v_actor,
           'uploaded_at', to_char(now() at time zone 'Africa/Cairo', 'YYYY-MM-DD HH24:MI'));
end $$;

comment on function public.attach_txn_receipt is
  'يسجّل صورة تحويل مرفوعة على حركة بطاقة/محفظة. الرفع نفسه للـstorage من المتصفح، ودي بتسجّل المسار ومين رفعه.';

create or replace function public.txn_receipts_for(
  p_kind    text,
  p_branch  text,
  p_ref_ids text[]
) returns jsonb
language sql stable security definer set search_path = public as $$
  /* الأحدث لكل حركة — لو اترفعت صورة تانية بتحلّ محل اللي قبلها في
     العرض، والقديمة بتفضل محفوظة. */
  select coalesce(jsonb_object_agg(ref_id, jsonb_build_object(
           'id', id, 'path', path, 'mime', mime,
           'by', uploaded_by,
           'at', to_char(uploaded_at at time zone 'Africa/Cairo', 'YYYY-MM-DD HH24:MI')
         )), '{}'::jsonb)
  from (
    select distinct on (ref_id) ref_id, id, path, mime, uploaded_by, uploaded_at
    from public.txn_receipts
    where kind = p_kind and branch = p_branch and ref_id = any(p_ref_ids)
    order by ref_id, uploaded_at desc
  ) t;
$$;

revoke all on function public.attach_txn_receipt(text,text,text,text,text,integer) from public;
revoke all on function public.txn_receipts_for(text,text,text[]) from public;
grant execute on function public.attach_txn_receipt(text,text,text,text,text,integer) to authenticated;
grant execute on function public.txn_receipts_for(text,text,text[]) to authenticated;

notify pgrst, 'reload schema';
