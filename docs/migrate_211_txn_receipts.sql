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
  /* قائمة لكل حركة — تحويل واحد ممكن يبقى له إيصال وسكرين شوت
     للرصيد بعده، والاتنين دليل. */
  select coalesce(jsonb_object_agg(ref_id, imgs), '{}'::jsonb)
  from (
    select ref_id,
           jsonb_agg(jsonb_build_object(
             'id', id, 'path', path, 'mime', mime, 'by', uploaded_by,
             'at', to_char(uploaded_at at time zone 'Africa/Cairo', 'YYYY-MM-DD HH24:MI')
           ) order by uploaded_at) as imgs
    from public.txn_receipts
    where kind = p_kind and branch = p_branch and ref_id = any(p_ref_ids)
    group by ref_id
  ) t;
$$;

/* ═══ شيل صورة اترفعت بالغلط ═══════════════════════════════════════
   «مفيش حذف خالص» كان تشدّد في غير محلّه: الموظف يختار صورة غلط من
   المعرض فتفضل قدام المراجع للأبد. لكن الحذف المفتوح بيلغي معنى
   الدليل أصلًا. فالوسط:
     · قبل المراجعة  →  صاحب الصورة (أو الأدمن) يقدر يشيلها.
     · بعد المراجعة  →  الدليل يتجمّد؛ الأدمن يفكّ المراجعة الأول
                        لو فيه سبب، والفكّ نفسه متسجّل.
   ⚠️ سوبابيز بترفض `delete from storage.objects` من SQL («Direct
      deletion from storage tables is not allowed») — فالدالة بتشيل
      **السجل** بس، والمتصفح بيشيل **الملف** بعدها بالـStorage API.
      ومش ثغرة: سياسة الحذف تحت بتسمح بالملف **بس لو مفيش سجل بيشاور
      عليه**، والسجل مابيتشالش غير من الدالة دي بحارسها. */
create or replace function public.delete_txn_receipt(p_id bigint)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare rec public.txn_receipts; v_actor text; v_admin boolean; v_reviewed boolean;
begin
  if not public.shift_can_review() then
    raise exception 'غير مصرّح';
  end if;

  select * into rec from public.txn_receipts where id = p_id;
  if not found then
    return jsonb_build_object('success', true);   -- اتشالت قبل كده
  end if;

  v_actor := public.bank_actor();
  v_admin := coalesce(public.jwt_app_role(),'') = 'admin';
  if rec.uploaded_by is distinct from v_actor and not v_admin then
    raise exception 'الصورة دي مرفوعة من %، ومش من حقك تشيلها', rec.uploaded_by;
  end if;

  if rec.kind = 'card' then
    select exists (select 1 from public.shift_txn_reviews r
                    where r.branch = rec.branch
                      and r.fh_id::text = rec.ref_id) into v_reviewed;
  else
    /* مفتاح المحافظ في الشاشة هو src:row_id */
    select exists (select 1 from public.wallet_txn_reviews r
                    where r.src || ':' || r.row_id::text = rec.ref_id) into v_reviewed;
  end if;

  if v_reviewed then
    raise exception 'الحركة دي اتراجعت خلاص — الدليل بيتجمّد بعد المراجعة';
  end if;

  delete from public.txn_receipts where id = rec.id;
  /* الملف نفسه بيتشال من المتصفح بالـStorage API — السطر ده مرجعه */
  return jsonb_build_object('success', true, 'id', rec.id, 'path', rec.path);
end $$;

comment on function public.delete_txn_receipt is
  'شيل صورة تحويل اترفعت بالغلط — قبل المراجعة بس، ولصاحبها أو للأدمن.';

revoke all on function public.delete_txn_receipt(bigint) from public;
grant execute on function public.delete_txn_receipt(bigint) to authenticated;

/* الملف اليتيم بس — اللي مفيش سجل بيشاور عليه */
drop policy if exists receipts_delete on storage.objects;
create policy receipts_delete on storage.objects
  for delete to authenticated
  using (bucket_id = 'receipts'
         and not exists (select 1 from public.txn_receipts t
                          where t.path = storage.objects.name));

revoke all on function public.attach_txn_receipt(text,text,text,text,text,integer) from public;
revoke all on function public.txn_receipts_for(text,text,text[]) from public;
grant execute on function public.attach_txn_receipt(text,text,text,text,text,integer) to authenticated;
grant execute on function public.txn_receipts_for(text,text,text[]) to authenticated;

notify pgrst, 'reload schema';
