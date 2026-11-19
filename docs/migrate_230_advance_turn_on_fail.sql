-- migrate_230_advance_turn_on_fail.sql
-- دور الطيار بعد تعذّر التوصيل: الطيار اللي طالع ويتعذّر توصيل طلب كان معاه
-- لازم ياخد دوره الطبيعي (راجع للتو) في آخر الطابور — مش يفضل بأقدم
-- last_completed_at فياخد الطلب الجاي أول واحد (longest_idle).
--
-- السبب الجذري: تريجر trips_driver_last_completed بيحرّك الدور بس لو الرحلة
-- اتقفلت وفيها طلب طلع فعلاً. لكن التعذّر بيشيل الطلب من الرحلة (trip_orders)،
-- فالرحلة تتقفل «فاضية» والتريجر «يحتفظ بدوره» → يرجع لأول الطابور.
-- الحل: نحرّك الدور مباشرة لحظة التعذّر.
-- يطبّق على السحابة + الذاتي.
create or replace function public.trg_advance_turn_on_fail() returns trigger
language plpgsql as $$
begin
  if OLD.driver_id is not null
     and OLD.status in ('assigned','picked')
     and NEW.status is distinct from OLD.status
     and ( NEW.status = 'failed'
        or ( NEW.status = 'postponed'
             and coalesce(NEW.postpone_reason,'') not in ('','أُزيل من الرحلة') ) )
  then
    update drivers set last_completed_at = now() where id = OLD.driver_id;
  end if;
  return NEW;
end$$;
drop trigger if exists trg_orders_advance_turn_on_fail on public.orders;
create trigger trg_orders_advance_turn_on_fail
  after update of status on public.orders
  for each row execute function public.trg_advance_turn_on_fail();
