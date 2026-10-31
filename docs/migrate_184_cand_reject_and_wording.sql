/* ════════════════════════════════════════════════════════════════
   رفض المرشّح + صياغة رسمية لرسائل السيرفر   (2026-10-31)
   ----------------------------------------------------------------
   **١) سؤال المالك**: «لو ضغط على الزر ده، إيه اللي هيحصل؟»
   والإجابة وقتها كانت ناقصة: الزر كان **بيفتح خانة الكتابة وبس**،
   فالاقتراح الغلط بيرجع يظهر تاني في اليوم اللي بعده والمراجع
   يرفضه من أول وجديد — وده بيحوّل الأداة لمصدر إزعاج بدل ما توفّر
   وقت.

   دلوقتي الرفض **بيتسجّل**: النظام مايقترحش نفس الربط تاني، ويعرض
   المرشّح اللي بعده إن وُجد. والرفض **مش إقفال** — الحركة بترجع
   «بلا مقابل» ولسه محتاجة إثبات (ربط أو نص مكتوب).

   **٢) الصياغة**: نصوص الشاشات رسمية مش عامية (قاعدة المالك).
   «مش هي» بقت «غير مطابق»، و«ليها بيع» بقت «مطابِقة لفاتورة»،
   و«مفيش كشف» بقت «لا يوجد كشف»، ورسائل السيرفر اتصلحت هنا.

   يتطبّق على: السحابة **و** السيرفر الذاتي.
   ⚠️ لسه ماتطبّقش على السحابة — تعديل/نشر على البرودكشن محتاج
      موافقة المالك.
   ════════════════════════════════════════════════════════════════ */

/* ── ١) جدول الرفض ───────────────────────────────────────────── */
create table if not exists public.wallet_cand_rejects (
  src         text   not null check (src in ('machine','wallet')),
  row_id      bigint not null,
  ref_fh_id   bigint not null,
  rejected_by text   not null,
  rejected_at timestamptz not null default now(),
  primary key (src, row_id, ref_fh_id)
);
comment on table public.wallet_cand_rejects is
  'اقتراحات ربط رفضها المراجع — النظام لا يقترحها مرة أخرى';

alter table public.wallet_cand_rejects enable row level security;
drop policy if exists wcr_read on public.wallet_cand_rejects;
create policy wcr_read on public.wallet_cand_rejects for select to authenticated using (true);
revoke all on public.wallet_cand_rejects from public, anon;
grant select on public.wallet_cand_rejects to authenticated;

create or replace function public.wallet_cand_reject(
  p_src text, p_id bigint, p_ref_fh_id bigint
) returns jsonb
language plpgsql security definer set search_path = public
as $fn$
declare v_by text; v_branch text; v_role text; v_all boolean; v_scope text;
begin
  if not public.shift_can_review() then
    raise exception 'غير مصرّح بمراجعة حركات الشيفت' using errcode = '42501';
  end if;
  if p_src not in ('machine','wallet') then
    raise exception 'مصدر غير معروف' using errcode = '22023';
  end if;
  if p_src = 'machine' then
    select public.branch_code_of(branch) into v_branch from wallet where id = p_id;
  else
    select public.branch_code_of(branch) into v_branch from wallet_sms where id = p_id;
  end if;
  if v_branch is null then
    raise exception 'الحركة غير موجودة' using errcode = 'P0002';
  end if;

  v_role := public.jwt_app_role();
  if coalesce(current_setting('request.jwt.claims', true)::jsonb ->> 'role','') <> 'service_role'
     and v_role <> 'admin' then
    select pp.all_branches into v_all from page_permissions pp
     where pp.role = v_role and pp.page_key = 'current_shift';
    if not coalesce(v_all,false) then
      v_scope := public.branch_code_of(public.jwt_branch());
      if v_scope is distinct from v_branch then
        raise exception 'غير مصرّح: الحركة خارج نطاق فرعك' using errcode = '42501';
      end if;
    end if;
  end if;

  v_by := public.bank_actor();
  insert into wallet_cand_rejects (src, row_id, ref_fh_id, rejected_by)
  values (p_src, p_id, p_ref_fh_id, v_by)
  on conflict (src, row_id, ref_fh_id) do nothing;
  return jsonb_build_object('success', true);
end $fn$;

revoke all on function public.wallet_cand_reject(text, bigint, bigint) from public, anon;
grant execute on function public.wallet_cand_reject(text, bigint, bigint) to authenticated;

/* ── ٢) المرشّح يستبعد المرفوض + صياغة رسمية ─────────────────── */
do $do$
declare src text; nsrc text;
begin
  select pg_get_functiondef(p.oid) into src from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'get_wallet_review';
  if src is null then raise exception 'get_wallet_review مش موجودة'; end if;

  /* المرفوض ماينفعش يترشّح تاني */
  if src not like '%wallet_cand_rejects%' then
    nsrc := replace(src,
      '      from openm o join openc c on c.bc = o.bc',
      E'      from openm o join openc c on c.bc = o.bc\n'
      || E'     where not exists (select 1 from wallet_cand_rejects x\n'
      || E'                        where x.src = o.src and x.row_id = o.id and x.ref_fh_id = c.fh_id)\n'
      || '       and');
    if nsrc = src then raise exception 'مالقيتش وصلة المرشّحين'; end if;
    /* الـwhere الأصلي بقى and بعد ما حطّينا where جديد */
    nsrc := replace(nsrc,
      E'       and\n     where (abs(c.amt - o.amt) <= 5',
      E'       and ((abs(c.amt - o.amt) <= 5');
    nsrc := replace(nsrc,
      'or (c.amt = o.amt and abs(extract(epoch from c.ts - o.ts)) between 7200 and 86400)',
      'or (c.amt = o.amt and abs(extract(epoch from c.ts - o.ts)) between 7200 and 86400))');
    src := nsrc;
  end if;

  /* «بيع» → «فاتورة» في نص الدليل */
  src := replace(src, '''ربط يدوي: بيع ''', '''ربط يدوي: فاتورة ''');
  src := replace(src, '''بيع '' || coalesce(h.fh_id::text,'''')', '''فاتورة '' || coalesce(h.fh_id::text,'''')');
  src := replace(src, '''يُحتمل: بيع ''', '''يُحتمل: فاتورة ''');
  execute src;
end $do$;

/* ── ٣) رسائل wallet_review_set بالصياغة الرسمية ─────────────── */
do $do$
declare src text;
begin
  select pg_get_functiondef(p.oid) into src from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'wallet_review_set';
  if src is null then raise exception 'wallet_review_set مش موجودة'; end if;
  src := replace(src, 'اختر البيعة المقابلة', 'اختر الفاتورة المقابلة');
  src := replace(src, 'البيعة غير موجودة في نفس الفرع', 'الفاتورة غير موجودة في الفرع نفسه');
  src := replace(src, 'البيعة دي مربوطة بحركة تانية بالفعل', 'هذه الفاتورة مرتبطة بحركة أخرى بالفعل');
  src := replace(src, '''اكتب الدليل''', '''يُرجى كتابة الدليل''');
  src := replace(src, 'غير مصرّح: الحركة خارج فرعك', 'غير مصرّح: الحركة خارج نطاق فرعك');
  execute src;
end $do$;
