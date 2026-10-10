-- migrate_106_import_sheet_rpc.sql
-- زر «استيراد شيت المشتريات» من المتصفح: يحدّث الكود والاسم بس على نفس جدول
-- المشتريات (purchase_invoice_items) عبر item_code_map — مايضيفش فواتير.
-- الصلاحية تتبع شاشة الصلاحيات: محتاج «تعديل» (can_edit) على صفحة purchase_invoices.
-- التدفّق من الشاشة: purchase_stage_clear() → purchase_stage_add(دفعات) → purchase_map_build().
-- يعتمد على migrate_104 (staging + item_code_map + apply). يُطبّق على القاعدتين.

-- حارس عام: يتحقق إن دور المستخدم له can_edit على صفحة من page_permissions
create or replace function public.require_page_edit(p_page_key text)
returns void language plpgsql stable security definer set search_path=public as $$
declare r text := jwt_app_role();
begin
  if r = 'admin' then return; end if;
  if not exists (select 1 from page_permissions where page_key=p_page_key and role=r and can_edit) then
    raise exception 'غير مصرّح بالتعديل على %', p_page_key using errcode='42501';
  end if;
end$$;
revoke all on function public.require_page_edit(text) from public, anon;
grant execute on function public.require_page_edit(text) to authenticated;

create or replace function public.purchase_stage_clear()
returns void language plpgsql security definer set search_path=public as $$
begin perform require_page_edit('purchase_invoices'); delete from public.purchase_xlsx_stage where true; end$$;

create or replace function public.purchase_stage_add(p_rows jsonb)
returns integer language plpgsql security definer set search_path=public as $$
declare n int;
begin
  perform require_page_edit('purchase_invoices');
  insert into public.purchase_xlsx_stage(branch,pth_id,code,name,qty,pur)
  select x.branch,x.pth_id,x.code,x.name,x.qty,x.pur
  from jsonb_to_recordset(p_rows) as x(branch text,pth_id bigint,code text,name text,qty numeric,pur numeric);
  get diagnostics n=row_count; return n;
end$$;

create or replace function public.purchase_map_build()
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_mapped int; v_applied int; v_stage int;
begin
  perform require_page_edit('purchase_invoices');
  select count(*) into v_stage from public.purchase_xlsx_stage;
  with j as (
    select distinct pi.branch, pi.itm_id, s.code, s.name
    from public.purchase_xlsx_stage s
    join public.purchase_invoice_items pi
      on pi.branch=s.branch and pi.pth_id=s.pth_id
     and round(pi.itm_pur_price::numeric,2)=round(s.pur::numeric,2)
     and round(pi.qnty::numeric)=round(s.qty::numeric)
  ),
  good as (select branch,itm_id from j group by branch,itm_id having count(distinct code)=1)
  insert into public.item_code_map(branch,itm_id,itm_code,itm_name,source)
  select j.branch,j.itm_id,max(j.code),max(j.name),'purchase_xlsx'
  from j join good g on g.branch=j.branch and g.itm_id=j.itm_id
  group by j.branch,j.itm_id
  on conflict (branch,itm_id) do update set itm_code=excluded.itm_code,itm_name=excluded.itm_name,updated_at=now();
  get diagnostics v_mapped=row_count;
  v_applied := public.apply_item_code_map();
  delete from public.purchase_xlsx_stage where true;
  return jsonb_build_object('stage',v_stage,'mapped',v_mapped,'applied',v_applied);
end$$;

revoke all on function public.purchase_stage_clear() from public, anon;
revoke all on function public.purchase_stage_add(jsonb) from public, anon;
revoke all on function public.purchase_map_build() from public, anon;
grant execute on function public.purchase_stage_clear() to authenticated;
grant execute on function public.purchase_stage_add(jsonb) to authenticated;
grant execute on function public.purchase_map_build() to authenticated;
notify pgrst,'reload schema';
