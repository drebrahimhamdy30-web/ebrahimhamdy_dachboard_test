-- migrate_104_item_code_map.sql
-- قاموس ترجمة: id الصنف الداخلي بتاع eplus (مختلف لكل فرع) → كودنا الموحّد + الاسم.
-- المصدر: تصدير «مشتريات تفصيلي» Excel من eplus (البرنامج بيفك التشفير ويطلّع الكود+الاسم)،
-- بيتطابق ببنود المشتريات المزامنة على (الفرع + pth_id + سعر الشراء + الكمية + الصلاحية) → itm_id ↔ كودنا.
-- المفتاح (branch, itm_id) لأن itm_id مساحة أرقام مستقلة لكل فرع، بينما الكود موحّد عبر الفروع.
-- يُطبّق على القاعدتين (الذاتي + السحابة).

create table if not exists public.item_code_map (
  branch      text not null,
  itm_id      bigint not null,
  itm_code    text not null,
  itm_name    text,
  source      text not null default 'purchase_xlsx',
  confidence  integer not null default 1,   -- عدد مرات التأييد
  updated_at  timestamptz not null default now(),
  primary key (branch, itm_id)
);
create index if not exists ix_item_code_map_code on public.item_code_map (itm_code);

alter table public.item_code_map enable row level security;
drop policy if exists p_read on public.item_code_map;
create policy p_read on public.item_code_map for select to anon, authenticated using (true);
grant select on public.item_code_map to anon, authenticated;
grant all on public.item_code_map to service_role;

-- عمود الكود الموحّد على بنود المشتريات (الاسم موجود أصلاً itm_name)
alter table public.purchase_invoice_items add column if not exists itm_code text;
create index if not exists ix_pii_itm_code on public.purchase_invoice_items (itm_code);

-- جدول staging لرفع بنود «مشتريات تفصيلي» Excel قبل المطابقة
create table if not exists public.purchase_xlsx_stage(
  branch text, pth_id bigint, code text, name text, qty numeric, pur numeric
);
grant all on public.purchase_xlsx_stage to service_role;
alter table public.purchase_xlsx_stage enable row level security;

-- بناء القاموس من الـstaging: مطابقة ببنود المشتريات المزامنة على (الفرع+pth_id+سعر الشراء+الكمية)
-- يتجاهل الملتبس (itm_id طابق أكتر من كود)، يطبّق القاموس، ويفرّغ الـstaging. للخدمة فقط.
create or replace function public.build_purchase_code_map()
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_mapped int; v_applied int;
begin
  with j as (
    select distinct pi.branch, pi.itm_id, s.code, s.name
    from purchase_xlsx_stage s
    join purchase_invoice_items pi
      on pi.branch=s.branch and pi.pth_id=s.pth_id
     and round(pi.itm_pur_price::numeric,2)=round(s.pur::numeric,2)
     and round(pi.qnty::numeric)=round(s.qty::numeric)
  ),
  good as (select branch,itm_id from j group by branch,itm_id having count(distinct code)=1)
  insert into item_code_map(branch,itm_id,itm_code,itm_name,source)
  select j.branch, j.itm_id, max(j.code), max(j.name), 'purchase_xlsx'
  from j join good g on g.branch=j.branch and g.itm_id=j.itm_id
  group by j.branch, j.itm_id
  on conflict (branch,itm_id) do update set itm_code=excluded.itm_code, itm_name=excluded.itm_name, updated_at=now();
  get diagnostics v_mapped = row_count;
  v_applied := apply_item_code_map();
  truncate public.purchase_xlsx_stage;
  return jsonb_build_object('mapped', v_mapped, 'applied', v_applied);
end$$;
grant execute on function public.build_purchase_code_map() to service_role;

-- تطبيق القاموس على بنود المشتريات (كود + اسم) — تُستدعى بعد كل تحديث للقاموس
create or replace function public.apply_item_code_map()
returns integer language plpgsql security definer set search_path=public as $$
declare n integer;
begin
  update public.purchase_invoice_items pi
     set itm_code = m.itm_code,
         itm_name = coalesce(m.itm_name, pi.itm_name)
  from public.item_code_map m
  where m.branch = pi.branch and m.itm_id = pi.itm_id
    and (pi.itm_code is distinct from m.itm_code
         or (m.itm_name is not null and pi.itm_name is distinct from m.itm_name));
  get diagnostics n = row_count;
  return n;
end$$;
grant execute on function public.apply_item_code_map() to service_role;

notify pgrst, 'reload schema';
