/* ═══════════════════════════════════════════════════════════════════
   تقفيل المطالبة: الخصم بقى ٣ حالات بدل حالة واحدة
   ═══════════════════════════════════════════════════════════════════
   كان فيه خصم واحد مش أكتر: **نسبة × قيمة المحلي**. وده بيغطّي حالة
   واحدة بس من اللي بيحصل فعلًا مع الموردين. المطلوب:

     ١. خصم من المحلي       — نسبة × قيمة المحلي        (زي ما هو)
     ٢. خصم نسبة من التوتال — نسبة × **قيمة الفواتير**
     ٣. خصم قيمة من التوتال — مبلغ ثابت

   وواحد بس بيشتغل في المرة — مش الاتنين مع بعض. فالشاشة بقى فيها
   «نوع الخصم» يقلّب بين التلاتة، والقاعدة بتتغيّر معاه.

   «التوتال» هنا = **قيمة الفواتير قبل أي خصم**، يعني بند
   `invoices_total` اللي على الشاشة نفسها — قبل المرتجعات وقبل
   «لم يصل» وقبل الخصم ده. لو النسبة اتحسبت على الصافي كان الرقم
   هيطلع أقل والمورّد يعترض.

   ── ليه القيمة بتتحسب على السيرفر ─────────────────────────────────
   الواجهة بتبعت **الاختيار** (النوع، والنسبة أو المبلغ) والسيرفر
   بيحسب `disc_value` بنفسه من `invoices_total` اللي هو حسبه هو. لو
   استقبلنا القيمة جاهزة من المتصفح كان ممكن تُقفل مطالبة بخصم مش
   مطابق لأرقامها.

   ⚠️ الدالة اتعمل لها DROP مش REPLACE — زيادة بارامتر = توقيع جديد،
      والقديم كان هيفضل موجود جنبه وPostgREST تحتار بينهم. والصلاحيات
      بتتمسح مع الـDROP فلازم تترجع تحت (authenticated بس، وPUBLIC
      يُسحب لأن EXECUTE بياخده افتراضيًا).

   يتطبّق على: السحابة **و** السيرفر الذاتي.
   ═══════════════════════════════════════════════════════════════════ */

/* الصفوف القديمة كلها كانت «خصم من المحلي» — الافتراضي بيوصّفها صح */
alter table public.supplier_claims
  add column if not exists disc_mode text not null default 'local';

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'supplier_claims_disc_mode_ck') then
    alter table public.supplier_claims
      add constraint supplier_claims_disc_mode_ck
      check (disc_mode in ('local','pct_total','val_total'));
  end if;
end $$;

comment on column public.supplier_claims.disc_mode is
  'قاعدة الخصم: local = نسبة من قيمة المحلي · pct_total = نسبة من قيمة الفواتير · val_total = مبلغ ثابت';

drop function if exists public.close_supplier_claim(text,text,jsonb,jsonb,numeric,numeric,text,date,date);
drop function if exists public.close_supplier_claim_impl(text,text,jsonb,jsonb,numeric,numeric,text,date,date);

create or replace function public.close_supplier_claim_impl(
  p_branch text, p_vendor text, p_inv jsonb, p_ret jsonb,
  p_local numeric, p_pct numeric, p_note text, p_from date, p_to date,
  p_mode text default 'local', p_val numeric default 0)
returns jsonb
language plpgsql security definer set search_path to 'public' as $fn$
declare
  v_by text; v_id bigint;
  v_inv numeric := 0; v_ret numeric := 0; v_notarr numeric := 0; v_disc numeric; v_net numeric;
  v_mode text := coalesce(nullif(btrim(p_mode),''), 'local');
  v_local numeric; v_pct numeric;
  r jsonb;
begin
  perform public.require_page_edit('supplier_claims');
  if v_mode not in ('local','pct_total','val_total') then
    raise exception 'نوع خصم غير معروف: %', v_mode;
  end if;
  v_by := coalesce(nullif(current_setting('request.jwt.claims', true),'')::jsonb->>'full_name',
                   nullif(current_setting('request.jwt.claims', true),'')::jsonb->>'name',
                   public.jwt_app_role(), 'غير معروف');
  /* بعد الخصم — زي ما الشاشة بتعرض (migrate_148) وزي ما كشف
     المورّد بيحاسب. total_bill لوحده كان بيسجّل في المطالبة رقم
     أعلى من اللي على الشاشة وأعلى من كشف المورّد. */
  select coalesce(sum(h.total_bill - coalesce(h.total_des_mon,0)),0) into v_inv
    from purchase_invoices h
   where h.branch=p_branch and h.ven_name_ar=p_vendor
     and h.pth_id in (select (jsonb_array_elements_text(coalesce(p_inv,'[]'::jsonb)))::bigint);
  for r in select * from jsonb_array_elements(coalesce(p_ret,'[]'::jsonb)) loop
    declare v numeric := 0; k text := r->>'kind'; reason text := coalesce(r->>'reason','غير مطلوب');
    begin
      if k='bill' then
        select round((i.itm_back_qty*coalesce(i.itm_back_pharm,i.itm_pur_price))::numeric,2) into v
          from purchase_invoice_items i where i.branch=p_branch and i.pth_id=(r->>'r1')::bigint and i.ptd_id=(r->>'r2')::bigint;
      else
        select round((x.qty*coalesce(x.ibd_ven_price,0))::numeric,2) into v
          from purchase_returns x where x.branch=p_branch and x.ibh_id=(r->>'r1')::bigint and x.ibd_id=(r->>'r2')::bigint;
      end if;
      v := coalesce(v,0);
      if reason='لم يصل' then v_notarr := v_notarr + v; else v_ret := v_ret + v; end if;
    end;
  end loop;

  /* ⚠️ حالة واحدة بتشتغل — واللي برا الحالة بيتصفّر في السجل عشان
     ماحدش يقرا المطالبة بعد شهر ويحسب خصم من رقم ما اتستخدمش. */
  if v_mode = 'pct_total' then
    v_local := 0;  v_pct := coalesce(p_pct,0);
    v_disc  := round(v_inv * v_pct / 100.0, 2);
  elsif v_mode = 'val_total' then
    v_local := 0;  v_pct := 0;
    v_disc  := round(greatest(coalesce(p_val,0), 0), 2);
  else
    v_local := coalesce(p_local,0);  v_pct := coalesce(p_pct,0);
    v_disc  := round(v_local * v_pct / 100.0, 2);
  end if;

  /* خصم أكبر من قيمة الفواتير نفسها = غلطة كتابة (صفر زيادة في مربع
     «قيمة الخصم»)، مش حالة شغل. أوقفه هنا مش بعد ما يتسجّل. */
  if v_inv > 0 and v_disc > v_inv then
    raise exception 'قيمة الخصم (%) أكبر من قيمة الفواتير (%) — راجع الرقم', v_disc, v_inv;
  end if;

  v_net := v_inv - v_ret - v_notarr - v_disc;
  insert into supplier_claims(branch, ven_name_ar, from_date, to_date, invoices_total, returns_total,
    notarr_total, local_value, disc_pct, disc_value, disc_mode, net_paid, note, closed_by)
  values (p_branch, p_vendor, p_from, p_to, v_inv, v_ret, v_notarr, v_local,
          v_pct, v_disc, v_mode, v_net, p_note, v_by)
  returning id into v_id;
  insert into claim_invoices(branch, pth_id, claim_id)
  select p_branch, (jsonb_array_elements_text(coalesce(p_inv,'[]'::jsonb)))::bigint, v_id
  on conflict (branch, pth_id) do nothing;
  insert into claim_returns(branch, ret_kind, r1, r2, reason, claim_id)
  select p_branch, el->>'kind', (el->>'r1')::bigint, (el->>'r2')::bigint, coalesce(el->>'reason','غير مطلوب'), v_id
  from jsonb_array_elements(coalesce(p_ret,'[]'::jsonb)) el
  on conflict (branch, ret_kind, r1, r2) do nothing;
  return jsonb_build_object('id', v_id, 'net', v_net, 'invoices', v_inv, 'returns', v_ret,
                            'notarr', v_notarr, 'disc', v_disc, 'disc_mode', v_mode, 'by', v_by);
end$fn$;

create or replace function public.close_supplier_claim(
  p_branch text, p_vendor text, p_inv jsonb, p_ret jsonb,
  p_local numeric, p_pct numeric, p_note text, p_from date, p_to date,
  p_mode text default 'local', p_val numeric default 0)
returns jsonb
language sql security definer set search_path to 'public' as $fn$
  select public.close_supplier_claim_impl(
           coalesce(public.purchase_branch_scope(p_branch, 'supplier_claims'), p_branch),
           p_vendor, p_inv, p_ret, p_local, p_pct, p_note, p_from, p_to, p_mode, p_val);
$fn$;

/* ⚠️ السيرفر الذاتي بيدّي anon و authenticated و service_role تنفيذ
   على أي دالة جديدة تلقائيًا (ذاكرة selfhosted-wide-grants)، وPUBLIC
   بياخد EXECUTE افتراضيًا في الاتنين. فالسحب صريح لكل جهة، والمنح
   لـauthenticated بس — والـimpl ماحدش بينادي عليها إلا الغلاف. */
revoke all on function public.close_supplier_claim_impl(text,text,jsonb,jsonb,numeric,numeric,text,date,date,text,numeric) from public, anon, authenticated, service_role;
revoke all on function public.close_supplier_claim(text,text,jsonb,jsonb,numeric,numeric,text,date,date,text,numeric) from public, anon, service_role;
grant execute on function public.close_supplier_claim(text,text,jsonb,jsonb,numeric,numeric,text,date,date,text,numeric) to authenticated;

/* المودال والمستند المصدَّر للمورّد محتاجين يعرفوا النوع عشان
   يكتبوا سطر الخصم صح — لو نوع مش موجود (صف قديم) يبقى local */
create or replace function public.get_claim_detail_impl(p_id bigint)
returns jsonb
language plpgsql stable security definer set search_path to 'public' as $fn$
declare c record; v_out jsonb;
begin
  select * into c from supplier_claims where id=p_id;
  if not found then return jsonb_build_object('error','المطالبة غير موجودة'); end if;
  select jsonb_build_object(
    'id', c.id, 'branch', c.branch, 'vendor', c.ven_name_ar, 'closed_at', c.closed_at,
    'from_date', c.from_date, 'to_date', c.to_date,
    'invoices_total', c.invoices_total, 'returns_total', c.returns_total, 'notarr_total', c.notarr_total,
    'local_value', c.local_value, 'disc_pct', c.disc_pct, 'disc_value', c.disc_value,
    'disc_mode', coalesce(c.disc_mode,'local'),
    'net_paid', c.net_paid, 'note', c.note, 'closed_by', c.closed_by, 'is_baseline', c.is_baseline,
    'invoices', (select coalesce(jsonb_agg(jsonb_build_object('bill_no',h.ven_bill_no,'date',coalesce(h.sec_insert_date::date,h.ven_bill_date::date),'inv_date',h.ven_bill_date::date,'total',h.total_bill::numeric) order by coalesce(h.sec_insert_date,h.ven_bill_date) desc),'[]'::jsonb)
                  from claim_invoices ci join purchase_invoices h on h.branch=ci.branch and h.pth_id=ci.pth_id where ci.claim_id=p_id),
    'returns', (
      select coalesce(jsonb_agg(x order by (x->>'date') desc),'[]'::jsonb) from (
        select jsonb_build_object('kind','على فاتورة','reason',cr.reason,'date',h.ven_bill_date::date,'bill_no',h.ven_bill_no,
          'code',coalesce(nullif(btrim(i.itm_code),''),i.itm_id::text),'name',coalesce(nullif(btrim(i.itm_name),''),'—'),
          'qty',i.itm_back_qty,'val',round((i.itm_back_qty*coalesce(i.itm_back_pharm,i.itm_pur_price))::numeric,2)) x, h.ven_bill_date d
        from claim_returns cr
          join purchase_invoice_items i on i.branch=cr.branch and i.pth_id=cr.r1 and i.ptd_id=cr.r2
          join purchase_invoices h on h.branch=i.branch and h.pth_id=i.pth_id
        where cr.claim_id=p_id and cr.ret_kind='bill'
        union all
        select jsonb_build_object('kind','شراء عام','reason',cr.reason,'date',r.sec_insert_date::date,'bill_no',null,
          'code',coalesce(nullif(btrim(r.itm_code),''),r.itm_id::text),'name',coalesce(nullif(btrim(r.itm_name),''),'—'),
          'qty',r.qty,'val',round((r.qty*coalesce(r.ibd_ven_price,0))::numeric,2)) x, r.sec_insert_date d
        from claim_returns cr
          join purchase_returns r on r.branch=cr.branch and r.ibh_id=cr.r1 and r.ibd_id=cr.r2
        where cr.claim_id=p_id and cr.ret_kind='gen'
      ) s)
  ) into v_out;
  return v_out;
end$fn$;

notify pgrst, 'reload schema';
