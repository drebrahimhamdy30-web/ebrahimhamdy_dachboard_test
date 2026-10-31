/* ════════════════════════════════════════════════════════════════
   تبسيط إثبات المراجعة: خانة دليل قابلة للكتابة وزر تأكيد (2026-10-31)
   ----------------------------------------------------------------
   **قرار المالك**: «نلغي الاقتراح من أساسه؛ المطابق زي ما هو،
   وغير المطابق خانة الدليل قابلة للكتابة وزر تأكيد وخلاص.»
   وكمان: نفس الشيء في تبويب مراجعة تحصيل بطاقات الائتمان — زر «تم»
   يحفظ النص المكتوب.

   اللي اتشال: حالة «مرشّح» (الاقتراح التلقائي)، وزر الربط، وزر
   الرفض، وقائمة الأسباب، وزر «مشكلة». السبب إن الاقتراح أضاف طبقة
   قرار إضافية على المراجع (أأكّد؟ أرفض؟) من غير ما يقلّل الشغل
   الحقيقي — والمطلوب كان أبسط: اكتب إيه هي واضغط تأكيد.

   **القاعدة اللي فضلت**: اللي النظام لقاه بنفسه **مايتكتبش فوقه**
   (واقعة مش رأي)، واللي مالقاش له مرجع بيتقفل **بنص منسوب لصاحبه**
   — مش بضغطة فاضية.

   ⚠️ العمود `note` في `shift_txn_reviews` والتوقيع الجديد لـ
      `review_shift_txn` اتطبّقوا على السحابة بالفعل، **ومعاهم
      drop للتوقيع القديم** لأن `create or replace` بتوقيع جديد
      بتعمل **نسخة تانية** مش استبدال — والنسختين بيخلّوا PostgREST
      ينادي القديمة بالغلط.

   يتطبّق على: السيرفر الذاتي (السحابة اتعملت).
   ════════════════════════════════════════════════════════════════ */

/* ── ١) الدليل المكتوب يتخزّن مع مراجعة البطاقات ─────────────── */
alter table public.shift_txn_reviews add column if not exists note text;

do $do$
declare src text; nsrc text;
begin
  select pg_get_functiondef(p.oid) into src from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'review_shift_txn'
     and pg_get_function_identity_arguments(p.oid) = 'p_branch text, p_fh_id bigint, p_paid numeric, p_channel text';
  if src is null then raise notice 'التوقيع القديم مش موجود — غالبًا متطبّق'; return; end if;

  nsrc := replace(src,
    'p_paid numeric DEFAULT NULL::numeric, p_channel text DEFAULT NULL::text)',
    'p_paid numeric DEFAULT NULL::numeric, p_channel text DEFAULT NULL::text, p_note text DEFAULT NULL::text)');
  nsrc := replace(nsrc,
    'insert into shift_txn_reviews (branch, fh_id, paid, channel, reviewed_by)',
    'insert into shift_txn_reviews (branch, fh_id, paid, channel, note, reviewed_by)');
  nsrc := replace(nsrc,
    'values (p_branch, p_fh_id, p_paid, nullif(btrim(coalesce(p_channel,'''')),''''), v_by);',
    'values (p_branch, p_fh_id, p_paid, nullif(btrim(coalesce(p_channel,'''')),''''), nullif(btrim(coalesce(p_note,'''')),''''), v_by);');
  execute nsrc;
  /* ⚠️ لازم بعد الإنشاء — وإلا بيفضل توقيعين */
  drop function if exists public.review_shift_txn(text, bigint, numeric, text);
end $do$;

/* get_card_review يرجّع النص جوّه rv */
do $do$
declare src text; nsrc text;
begin
  select pg_get_functiondef(p.oid) into src from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'get_card_review';
  if src is null then raise exception 'get_card_review مش موجودة'; end if;
  if src like '%''note'', rv_note%' then raise notice 'متضاف قبل كده'; return; end if;
  nsrc := replace(src,
    'r.reviewed_by, r.reviewed_at, r.paid as rv_paid, r.channel as rv_channel,',
    'r.reviewed_by, r.reviewed_at, r.paid as rv_paid, r.channel as rv_channel, r.note as rv_note,');
  nsrc := replace(nsrc,
    $old$                 'paid', rv_paid, 'channel', rv_channel) end,$old$,
    $new$                 'paid', rv_paid, 'channel', rv_channel, 'note', rv_note) end,$new$);
  if nsrc = src then raise exception 'مالقيتش أعمدة المراجعة'; end if;
  execute nsrc;
end $do$;

/* ── ٢) إلغاء حالة «مرشّح» من get_wallet_review ───────────────
   الاقتراح اتشال بالكامل: اللي مالوش مطابقة تامة بيبقى «بلا مقابل»
   والمحاسب بيكتب دليله. */
do $do$
declare src text; nsrc text; a int; b int;
begin
  select pg_get_functiondef(p.oid) into src from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'get_wallet_review';
  if src is null then raise exception 'get_wallet_review مش موجودة'; end if;
  if src not like '%candp%' then raise notice 'الاقتراح متشال قبل كده'; return; end if;

  /* نشيل CTEs المرشّحين */
  a := position('  /* ٣) المرشّح' in src);
  b := position('  /* ٤) إثبات المراجعة' in src);
  if a = 0 or b = 0 then raise exception 'مالقيتش حدود بلوك المرشّح'; end if;
  src := substring(src from 1 for a - 1) || substring(src from b);

  /* الحالة: من غير candidate */
  src := replace(src,
    E'                  when h.id is not null then ''has_sale''\n                  when cd.fh_id is not null then ''candidate''\n',
    E'                  when h.id is not null then ''has_sale''\n');
  /* الدليل: من غير سطر «يُحتمل» */
  src := replace(src,
    E'                    when cd.fh_id is not null then ''يُحتمل: فاتورة '' || cd.fh_id::text ||\n                         case when cd.dv > 0 then '' · فرق '' || cd.dv::text || '' ج'' else '''' end ||\n                         '' · بفارق '' || cd.dm::text || '' دقيقة''\n',
    '');
  src := replace(src,
    E'           cd.fh_id as cand_fh_id, cd.dv as cand_diff, cd.dm as cand_mins,\n', '');
  src := replace(src, E'      left join cand cd on cd.src = m.src and cd.id = m.id\n', '');
  src := replace(src,
    E'                ''cand_fh_id'', cand_fh_id, ''cand_diff'', cand_diff, ''cand_mins'', cand_mins,\n', '');
  execute src;
end $do$;
