-- ============================================================
-- استعلامات workflow: pos_close
-- ============================================================


-- ============================================================
-- action = 'get_close_data'
-- الفرع جاي من: {{ $json.query.branch }}
-- ============================================================

-- استعلام واحد بيرجّع كل حاجة في JSON واحد
select json_build_object(

  -- 1) وسائل الفرع
  'methods', coalesce((
    select json_agg(json_build_object(
      'method_type',  m.method_type,
      'method_key',   m.method_key,
      'display_name', m.display_name
    ) order by m.sort_order)
    from public.pos_methods m
    where m.branch = '{{ $json.query.branch }}' and m.is_active = true
  ), '[]'::json),

  -- 2) رصيد البداية = رصيد نهاية آخر شيفت مقفول لكل محفظة
  'openings', coalesce((
    select json_object_agg(t.method_key, t.closing_balance)
    from (
      select distinct on (l.method_key)
        l.method_key,
        l.closing_balance
      from public.pos_shift_lines l
      join public.pos_shifts s on s.id = l.shift_id
      where s.branch = '{{ $json.query.branch }}'
        and l.method_type = 'wallet'
        and l.closing_balance is not null
      order by l.method_key, s.closed_at desc
    ) t
  ), '{}'::json),

  -- 3) قيم النظام
  'system', coalesce((
    select json_object_agg(t.method_key, t.val)
    from (
      -- المحافظ: آخر رصيد مسجّل
      select distinct on (tx."to")
        tx."to" as method_key,
        tx.balance as val
      from public.pos_transactions tx
      join public.pos_methods m
        on m.method_key = tx."to" and m.branch = '{{ $json.query.branch }}'
      where m.method_type = 'wallet'
        and tx.balance is not null
      order by tx."to", tx.transaction_time desc

      union all

      -- الماكينات: مجموع المعاملات غير المقفولة
      select
        m.method_key,
        coalesce(sum(tx.ammount), 0) as val
      from public.pos_methods m
      left join public.pos_transactions tx
        on tx."to" = m.method_key
       and tx.is_closed = false
       and tx.success = true
      where m.branch = '{{ $json.query.branch }}'
        and m.method_type = 'machine'
      group by m.method_key
    ) t
  ), '{}'::json)

) as result;


-- ============================================================
-- action = 'close_shift'
-- البيانات جاية من: {{ $json.body.* }}
-- ============================================================

-- خطوة 1: أنشئ الشيفت واحصل على id
insert into public.pos_shifts (
  branch, employee_name, total_wallets, total_machines, grand_total, notes
) values (
  '{{ $json.body.branch }}',
  '{{ $json.body.employee_name }}',
  {{ $json.body.total_wallets }},
  {{ $json.body.total_machines }},
  {{ $json.body.grand_total }},
  {{ $json.body.notes ? "'" + $json.body.notes + "'" : 'null' }}
)
returning id;


-- خطوة 2: أدخل السطور (بعد ما تاخد الـ id من الخطوة اللي فوق)
-- في n8n: استخدم Split Out على lines ثم Postgres insert
-- shift_id = {{ $('Create Shift').first().json.id }}

insert into public.pos_shift_lines (
  shift_id, method_type, method_key, display_name,
  opening_balance, closing_balance, system_closing,
  receipt_amount, actual_amount, system_amount, difference
) values (
  {{ $('Create Shift').first().json.id }},
  '{{ $json.method_type }}',
  '{{ $json.method_key }}',
  '{{ $json.display_name }}',
  {{ $json.opening_balance ?? 'null' }},
  {{ $json.closing_balance ?? 'null' }},
  {{ $json.system_closing  ?? 'null' }},
  {{ $json.receipt_amount  ?? 'null' }},
  {{ $json.actual_amount }},
  {{ $json.system_amount   ?? 'null' }},
  {{ $json.difference      ?? 'null' }}
);


-- خطوة 3: علّم معاملات الماكينات إنها اتقفلت
update public.pos_transactions tx
set is_closed = true,
    shift_id  = {{ $('Create Shift').first().json.id }}
from public.pos_methods m
where m.method_key = tx."to"
  and m.branch = '{{ $json.body.branch }}'
  and m.method_type = 'machine'
  and tx.is_closed = false;


-- ============================================================
-- action = 'get_unsettled'
-- ============================================================

select
  s.id,
  s.branch,
  s.employee_name,
  s.shift_date,
  s.closed_at,
  s.total_wallets,
  s.total_machines,
  s.grand_total,
  s.notes,
  coalesce((
    select json_agg(json_build_object(
      'method_type',     l.method_type,
      'method_key',      l.method_key,
      'display_name',    l.display_name,
      'opening_balance', l.opening_balance,
      'closing_balance', l.closing_balance,
      'receipt_amount',  l.receipt_amount,
      'actual_amount',   l.actual_amount,
      'system_amount',   l.system_amount,
      'difference',      l.difference
    ) order by l.id)
    from public.pos_shift_lines l
    where l.shift_id = s.id
  ), '[]'::json) as lines
from public.pos_shifts s
where s.branch = '{{ $json.query.branch }}'
  and s.is_settled = false
order by s.closed_at desc;


-- ============================================================
-- action = 'settle_shift'
-- ============================================================

update public.pos_shifts
set is_settled = true,
    settled_at = now(),
    settled_by = '{{ $json.body.settled_by }}'
where id = {{ $json.body.shift_id }}
  and is_settled = false;
