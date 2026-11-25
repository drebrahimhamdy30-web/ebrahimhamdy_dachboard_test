-- migrate_234 — تصدير بيانات المشتريات لنظام HR (قراية بس)
-- ─────────────────────────────────────────────────────────────────────────────
-- قرار المالك 2026-11-25: أسعار المخازن وتكويدها هتتنقل لـHR «مرة واحدة يوم ما نقرر»،
-- ولازم أداة النقل تبقى متجرّبة قبلها. جداول فاليكس مقفولة على authenticated، والاختيار
-- الآمن (موافقة المالك): دالة قراية بس بمفتاح سري خاص بيها في الخزنة — نفس طريقة سكربت ابن سينا —
-- بدل ما مفتاح الخدمة (اللي بيفتح القاعدة كلها) يتحط على سيرفر HR.
--
-- بترجّع: المخازن، وشكل شيت كل مخزن، وأصناف المخازن (بالصفحات بالـid)، وخريطة ضريبة ابن سينا.
-- مابتكتبش ولا بتمسح أي حاجة. المفتاح بيتقري من الخزنة (vault) وبيتلغي بحذفه منها.
--
-- المفتاح: select decrypted_secret from vault.decrypted_secrets where name = 'hr_export_key';
--   (المالك بيقراه من SQL Editor ويحطه في .env بتاع سيرفر HR بأمر إدخال مخفي — مايتكتبش في شات ولا ريبو)

do $$
begin
  if not exists (select 1 from vault.secrets where name = 'hr_export_key') then
    perform vault.create_secret(encode(extensions.gen_random_bytes(24), 'hex'), 'hr_export_key', 'مفتاح تصدير بيانات المشتريات لـHR (قراية بس) — migrate_234');
  end if;
end $$;

create or replace function public.is_hr_export_key(p_key text)
returns boolean
language sql
security definer
set search_path to 'public', 'vault'
as $$
  select coalesce(p_key <> '' and exists (
    select 1 from vault.decrypted_secrets where name = 'hr_export_key' and decrypted_secret = p_key
  ), false)
$$;
revoke all on function public.is_hr_export_key(text) from public, anon, authenticated;

create or replace function public.hr_export(p_key text, p_what text, p_after bigint default 0, p_limit integer default 2000)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  v_limit int := greatest(1, least(coalesce(p_limit, 2000), 5000));
  v_rows jsonb;
begin
  if not public.is_hr_export_key(p_key) then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  if p_what = 'stores' then
    select coalesce(jsonb_agg(to_jsonb(s) order by s.id), '[]') into v_rows
      from (select id, name, order_by, active, link_per_branch from stores) s;
  elsif p_what = 'mappings' then
    select coalesce(jsonb_agg(to_jsonb(m)), '[]') into v_rows
      from (select store, name_header, price_header, discount_header, updated_at from store_sheet_mappings) m;
  elsif p_what = 'items' then
    select coalesce(jsonb_agg(to_jsonb(i) order by i.id), '[]') into v_rows
      from (select id, item_name, store, code, discount_perc, price, notes, available, supplier_code, max_qty, updated_at
              from store_item_prices where id > coalesce(p_after, 0) order by id limit v_limit) i;
  elsif p_what = 'ibnsina_tax' then
    select coalesce(jsonb_agg(to_jsonb(t)), '[]') into v_rows
      from (select supplier_code, taxed, item_name, invoices_seen, updated_at from ibnsina_tax) t;
  else
    raise exception 'unknown: %', p_what;
  end if;

  return jsonb_build_object('rows', v_rows, 'count', jsonb_array_length(v_rows));
end
$$;
revoke all on function public.hr_export(text, text, bigint, integer) from public;
grant execute on function public.hr_export(text, text, bigint, integer) to anon, authenticated;
