-- migrate_208_pharmacist_review.sql
-- شاشة مراجعة الصيدلي (مراجعة الأصناف الخارجة للعميل ومطابقتها بالشات):
--   • review_shifts        : شيفت المراجعة (المراجع يكتب اسمه فيبدأ شيفت).
--   • order_review_tags     : تاجات على الطلب — جزء للطيار (يظهر له) وجزء للصيدلية (داخلي).
--   • orders.pharmacist_reviewed_at/by : علامة «تمت المراجعة».
--   • RPCs محروسة: review_tag_set / review_mark_done / review_followup_done.
-- التاجات اللي للطيار بتتربط بالحقول اللي التطبيق بيقراها فعلاً (payment_method/notes/staff_notes)
-- عشان توصل الطيار فورًا من غير تعديل في التطبيق.
-- مُطبّق على السحابة (برودكشن) — والذاتي (تست) محتاج يتطبّق يدويًا (جدول جديد لا يُزامَن تلقائيًا).

-- ═══ 1) شيفت المراجعة ═══
create table if not exists public.review_shifts(
  id            bigint generated always as identity primary key,
  reviewer_name text not null,
  branch_id     uuid,              -- uuid زي orders.branch_id/branches.id (مش int)
  started_at    timestamptz not null default now(),
  ended_at      timestamptz,
  started_by    text
);
-- لو الجدول اتعمل قبل كده بـint، صحّح النوع
do $$ begin
  if exists(select 1 from information_schema.columns where table_name='review_shifts' and column_name='branch_id' and data_type<>'uuid') then
    alter table public.review_shifts alter column branch_id drop default;
    alter table public.review_shifts alter column branch_id type uuid using null;
  end if;
end $$;
alter table public.review_shifts enable row level security;
grant select, insert, update on public.review_shifts to authenticated;
grant all on public.review_shifts to service_role;
drop policy if exists rs_all on public.review_shifts;
create policy rs_all on public.review_shifts for all to authenticated using (true) with check (true);
create index if not exists rs_open_idx on public.review_shifts(started_at) where ended_at is null;

-- ═══ 2) تاجات المراجعة على الطلب ═══
create table if not exists public.order_review_tags(
  id         bigint generated always as identity primary key,
  order_id   uuid not null,
  tag        text not null,                    -- visa|transfer|address_changed|urgent|driver_note|followup|pharmacy_note
  audience   text not null default 'driver',   -- driver | pharmacy
  note       text,
  created_by text,
  created_at timestamptz not null default now(),
  done_at    timestamptz,                       -- للمتابعة (الاطمئنان) فقط
  done_by    text,
  done_note  text
);
create index if not exists ort_order_idx on public.order_review_tags(order_id);
create index if not exists ort_followup_pending_idx on public.order_review_tags(created_at) where tag='followup' and done_at is null;
alter table public.order_review_tags enable row level security;
grant select, insert, update, delete on public.order_review_tags to authenticated;
grant all on public.order_review_tags to service_role;
drop policy if exists ort_all on public.order_review_tags;
create policy ort_all on public.order_review_tags for all to authenticated using (true) with check (true);

-- ═══ 3) علامة المراجعة على الطلب ═══
alter table public.orders add column if not exists pharmacist_reviewed_at timestamptz;
alter table public.orders add column if not exists pharmacist_reviewed_by text;

-- ═══ 4) RPC: ضبط/إزالة تاج + ربطه بحقول الطيار الموجودة ═══
create or replace function public.review_tag_set(
  p_order_id uuid, p_tag text, p_on boolean,
  p_note text default null, p_user text default null
) returns jsonb
language plpgsql security definer set search_path=public as $$
declare
  v_aud text;
  v_ord orders%rowtype;
begin
  if auth.role() is distinct from 'authenticated' then
    return jsonb_build_object('success',false,'error','غير مصرح');
  end if;
  select * into v_ord from orders where id=p_order_id;
  if not found then return jsonb_build_object('success',false,'error','الطلب غير موجود'); end if;

  v_aud := case when p_tag in ('followup','pharmacy_note') then 'pharmacy' else 'driver' end;

  if p_on then
    -- التاجات الجاهزة فريدة لكل (طلب, نوع)؛ الملاحظات الحرة ممكن تتكرر
    if p_tag in ('visa','transfer','address_changed','urgent','followup') then
      delete from order_review_tags where order_id=p_order_id and tag=p_tag;
    end if;
    insert into order_review_tags(order_id,tag,audience,note,created_by)
    values(p_order_id,p_tag,v_aud,nullif(p_note,''),coalesce(p_user,'مراجع'));

    -- ربط تاجات الطيار بالحقول اللي التطبيق بيقراها
    if p_tag='visa'     then update orders set payment_method='visa',     updated_at=now() where id=p_order_id; end if;
    if p_tag='transfer' then update orders set payment_method='transfer', updated_at=now() where id=p_order_id; end if;
    if p_tag='urgent'   then update orders set notes=case when coalesce(notes,'') like '%🚨%' then notes else '🚨 '||coalesce(notes,'') end, updated_at=now() where id=p_order_id; end if;
    if p_tag='address_changed' then
      update orders set staff_notes = trim(both ' ' from coalesce(staff_notes,'') ||
        case when coalesce(staff_notes,'')='' then '' else ' · ' end ||
        '📍 العنوان اتغيّر'|| case when nullif(p_note,'') is not null then ': '||p_note else '' end),
        updated_at=now() where id=p_order_id;
    end if;
    if p_tag='driver_note' and nullif(p_note,'') is not null then
      update orders set staff_notes = trim(both ' ' from coalesce(staff_notes,'') ||
        case when coalesce(staff_notes,'')='' then '' else ' · ' end || p_note),
        updated_at=now() where id=p_order_id;
    end if;
  else
    delete from order_review_tags where order_id=p_order_id and tag=p_tag;
    if p_tag='visa'     and v_ord.payment_method='visa'     then update orders set payment_method='cash', updated_at=now() where id=p_order_id; end if;
    if p_tag='transfer' and v_ord.payment_method='transfer' then update orders set payment_method='cash', updated_at=now() where id=p_order_id; end if;
    if p_tag='urgent'   then update orders set notes=trim(both ' ' from replace(replace(coalesce(notes,''),'🚨 ',''),'🚨','')), updated_at=now() where id=p_order_id; end if;
  end if;

  insert into order_logs(order_id,event,details,user_name)
  values(p_order_id,'order_edited',
    jsonb_build_object('action','review_tag','tag',p_tag,'on',p_on,'note',p_note),
    coalesce(p_user,'مراجع'));

  return jsonb_build_object('success',true);
exception when others then
  return jsonb_build_object('success',false,'error',sqlerrm);
end$$;

-- ═══ 5) RPC: تمت المراجعة ═══
create or replace function public.review_mark_done(p_order_id uuid, p_user text default null)
returns jsonb language plpgsql security definer set search_path=public as $$
begin
  if auth.role() is distinct from 'authenticated' then return jsonb_build_object('success',false,'error','غير مصرح'); end if;
  update orders set pharmacist_reviewed_at=now(), pharmacist_reviewed_by=coalesce(p_user,'مراجع'), updated_at=now()
  where id=p_order_id;
  if not found then return jsonb_build_object('success',false,'error','الطلب غير موجود'); end if;
  insert into order_logs(order_id,event,details,user_name)
  values(p_order_id,'order_edited',jsonb_build_object('action','pharmacist_reviewed'),coalesce(p_user,'مراجع'));
  return jsonb_build_object('success',true);
exception when others then return jsonb_build_object('success',false,'error',sqlerrm); end$$;

-- ═══ 6) RPC: قفل متابعة الاطمئنان ═══
create or replace function public.review_followup_done(p_tag_id bigint, p_note text default null, p_user text default null)
returns jsonb language plpgsql security definer set search_path=public as $$
begin
  if auth.role() is distinct from 'authenticated' then return jsonb_build_object('success',false,'error','غير مصرح'); end if;
  update order_review_tags set done_at=now(), done_by=coalesce(p_user,'مراجع'), done_note=nullif(p_note,'')
  where id=p_tag_id and tag='followup';
  if not found then return jsonb_build_object('success',false,'error','المتابعة غير موجودة'); end if;
  return jsonb_build_object('success',true);
exception when others then return jsonb_build_object('success',false,'error',sqlerrm); end$$;

-- الصلاحيات: امنع PUBLIC/anon (الافتراضي بيفتح الباب) وادّي authenticated بس
revoke all on function public.review_tag_set(uuid,text,boolean,text,text) from public;
revoke all on function public.review_mark_done(uuid,text) from public;
revoke all on function public.review_followup_done(bigint,text,text) from public;
grant execute on function public.review_tag_set(uuid,text,boolean,text,text) to authenticated;
grant execute on function public.review_mark_done(uuid,text) to authenticated;
grant execute on function public.review_followup_done(bigint,text,text) to authenticated;

-- ═══ 7) تسجيل الصفحة + صلاحياتها (الأدمن افتراضيًا؛ الباقي يُمنح من شاشة الصلاحيات) ═══
insert into app_pages(key,file,title,section,sort_order,is_active)
values('pharmacist_review','pharmacist_review.html','مراجعة الصيدلي','التوصيل',735,true)
on conflict (key) do update set file=excluded.file,title=excluded.title,section=excluded.section,sort_order=excluded.sort_order,is_active=true;

insert into page_permissions(role,page,page_key,can_view,can_edit)
select r,'pharmacist_review.html','pharmacist_review',(r='admin'),(r='admin')
from unnest(array['admin','manager','employee','cashier','pharmacist','reviewer','supervisor','inventory','accountant']) r
on conflict (role,page) do nothing;
