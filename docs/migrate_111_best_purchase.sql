-- migrate_111_best_purchase.sql
-- «أفضل مورّد» لكل صنف من فواتير الشراء — لعرضه في طلبيات الأدوية (أعلى خصم) والكوزمو (أقل سعر شراء).
-- جدول مُجمّع best_purchase_by_code + دالة refresh_best_purchase (آخر 3 شهور، واحتياطي كل الفواتير لو مفيش).
-- يُحدَّث بـpg_cron كل ساعة. الشاشتان تقرآن منه بالكود (itm_code). يُطبّق على القاعدتين.

create table if not exists public.best_purchase_by_code (
  itm_code    text primary key,
  disc_store  text,          -- المورّد صاحب أعلى خصم (للأدوية)
  best_disc   numeric,       -- أعلى خصم %
  price_store text,          -- المورّد صاحب أقل سعر شراء (للكوزمو)
  best_price  numeric,       -- أقل سعر شراء
  src         text,          -- '3m' = من آخر 3 شهور ، 'all' = رجعنا لكل الفواتير
  updated_at  timestamptz not null default now()
);
alter table public.best_purchase_by_code enable row level security;
drop policy if exists p_read on public.best_purchase_by_code;
create policy p_read on public.best_purchase_by_code for select to anon, authenticated using (true);
grant select on public.best_purchase_by_code to anon, authenticated;
grant all on public.best_purchase_by_code to service_role;

create or replace function public.refresh_best_purchase() returns integer
language plpgsql security definer set search_path=public as $$
declare n int;
begin
  with base as (
    select pi.itm_code, h.ven_name_ar store, pi.itm_pur_price::numeric price,
           pi.itm_dis_per::numeric disc, h.ven_bill_date::date d,
           (h.ven_bill_date >= current_date - 90) in3m
    from purchase_invoice_items pi
    join purchase_invoices h on h.branch=pi.branch and h.pth_id=pi.pth_id
    where pi.itm_code is not null and coalesce(pi.itm_pur_price,0) > 0
  ),
  has3 as (select itm_code, bool_or(in3m) h3 from base group by itm_code),
  scoped as (
    select b.* from base b join has3 using(itm_code)
    where (has3.h3 and b.in3m) or (not has3.h3)
  ),
  bd as (select distinct on (itm_code) itm_code, store disc_store, disc best_disc
         from scoped where disc is not null order by itm_code, disc desc nulls last, d desc),
  bp as (select distinct on (itm_code) itm_code, store price_store, price best_price
         from scoped order by itm_code, price asc, d desc),
  sr as (select itm_code, case when bool_or(in3m) then '3m' else 'all' end src from scoped group by itm_code),
  final as (
    select coalesce(bp.itm_code, bd.itm_code) itm_code, bd.disc_store, bd.best_disc,
           bp.price_store, bp.best_price, sr.src
    from bp full join bd using(itm_code)
    left join sr on sr.itm_code = coalesce(bp.itm_code, bd.itm_code)
  )
  insert into best_purchase_by_code(itm_code, disc_store, best_disc, price_store, best_price, src, updated_at)
  select itm_code, disc_store, best_disc, price_store, best_price, src, now() from final
  on conflict (itm_code) do update set disc_store=excluded.disc_store, best_disc=excluded.best_disc,
    price_store=excluded.price_store, best_price=excluded.best_price, src=excluded.src, updated_at=now();
  get diagnostics n = row_count;
  return n;
end$$;
grant execute on function public.refresh_best_purchase() to service_role, authenticated;

-- جدولة كل ساعة (الدقيقة 7)
do $$ begin
  perform cron.unschedule('refresh_best_purchase');
exception when others then null; end $$;
select cron.schedule('refresh_best_purchase', '7 * * * *', $$select public.refresh_best_purchase()$$);

select public.refresh_best_purchase() as rows_built;
notify pgrst, 'reload schema';
