-- migrate_212_guard_no_undeliver.sql
-- حادثة 2026-11-17: بعد انقطاع نت الصيدلية، مزامنة المبيعات أعادت إنشاء طلبات
-- كانت متسلّمة/مكتملة/مستلمة (حدث order_created باسم «المزامنة» بعد التسليم)،
-- فرجّعتها status='pending' ومسحت الطيار → ظهرت في «للتوزيع» (وبعضها «فوق وتحت»
-- لأنها فضلت في trip_orders). الإصلاح: استرجاع الحالات الحقيقية + الحارس ده.
--
-- الحارس يمنع أي UPDATE يرجّع طلب إلى 'pending' من:
--   • delivered / completed / picked  (لا يوجد استرجاع شرعي لها عبر تحديث)
--   • assigned وهو لسه في رحلة نشطة (عشان مايظهرش فوق وتحت)
-- ويسمح بـ: assigned بدون رحلة → pending (الاسترجاع التلقائي في auto_dispatch_tick)،
--            و postponed/cancelled → pending (إعادة التفعيل اليدوية).
-- INSERT غير متأثر (الطلبات الجديدة تتعمل عادي).
-- مُطبّق على السحابة (برودكشن). الذاتي يتطبّق يدويًا.
create or replace function public.guard_no_undeliver() returns trigger
language plpgsql as $$
begin
  if NEW.status = 'pending'
     and ( OLD.status in ('delivered','completed','picked')
        or ( OLD.status = 'assigned'
             and exists (select 1 from trip_orders tr join trips t on t.id=tr.trip_id
                         where tr.order_id = OLD.id and t.status in ('active','pending_complete')) ) )
  then
    NEW.status          := OLD.status;
    NEW.driver_id       := OLD.driver_id;
    NEW.deliveryman     := OLD.deliveryman;
    NEW.assigned_at     := OLD.assigned_at;
    NEW.picked_at       := OLD.picked_at;
    NEW.delivered_at    := OLD.delivered_at;
    NEW.completed_at    := OLD.completed_at;
    NEW.collected_amount:= OLD.collected_amount;
  end if;
  return NEW;
end$$;
drop trigger if exists trg_guard_no_undeliver on public.orders;
create trigger trg_guard_no_undeliver before update on public.orders
for each row execute function public.guard_no_undeliver();
