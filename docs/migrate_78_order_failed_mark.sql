-- migrate_78_order_failed_mark.sql
-- علامة دائمة على الطلب إنه اتعذّر توصيله قبل كده (محاولة فاشلة من الطيار)
-- الهدف: في شاشة التوزيع، لما الطلب يترجّع الصيدلية بعد التعذّر ويتعاد توصيله،
--        يبان عليه إنه محاولة جديدة عشان المتابع مايعتبروش متأخر ظلمًا.
-- ملاحظة: ده علامة عرض فقط — مش بيغيّر حساب الوقت (realOrderMins) ولا تقييم الفرع (trg_sla_rating).
-- يُطبَّق على القاعدتين: السحابة (rxtjoqulmgkkcohmgzgi) + السيرفر الذاتي.

alter table public.orders
  add column if not exists had_failed_attempt boolean not null default false;

comment on column public.orders.had_failed_attempt is
  'true لو الطلب مرّ بحالة failed (تعذّر توصيل من الطيار) مرة على الأقل. علامة عرض دائمة، لا تُمسح عند إعادة التوصيل.';

-- نضيف ضبط العلامة داخل تريجر update_last_activated (BEFORE UPDATE الموجود)
create or replace function public.update_last_activated()
 returns trigger
 language plpgsql
as $function$
begin
  if new.status = 'pending' and (old.status is distinct from 'pending') then
    new.last_activated_at = now();
    new.prep_hold_seconds = 0;
    new.prep_hold_started_at = case when coalesce(new.prep_hold,false) then now() else null end;
  end if;

  -- علامة دائمة للتعذّر (محاولة فاشلة) — تتحطّ أول ما الطلب يبقى failed، ومتتمسحش
  if new.status = 'failed' and old.status is distinct from 'failed' then
    new.had_failed_attempt = true;
  end if;

  if coalesce(new.prep_hold,false) is distinct from coalesce(old.prep_hold,false) then
    if coalesce(new.prep_hold,false) then
      new.prep_hold_started_at = now();
    else
      new.prep_hold_seconds = coalesce(new.prep_hold_seconds, old.prep_hold_seconds, 0)
        + greatest(0, extract(epoch from (now() - coalesce(old.prep_hold_started_at, now()))));
      new.prep_hold_started_at = null;
    end if;
  end if;

  return new;
end;
$function$;
