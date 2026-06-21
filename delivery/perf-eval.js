// ============================================================
// perf-eval.js — منطق تقييم أداء الطلب (الصيدلية + الطيار)
// التقييم بعد التسليم فقط. الطلب غير المسلّم لا يُقيّم.
// ============================================================

// يحسب الوقت المتوقع للمنطقة (بالدقيقة). null لو مفيش منطقة مسجّلة.
function _regionMins(o, regionMinutes){
  const r = o.cust_region;
  if(!r || !regionMinutes || !regionMinutes[r]) return null;
  return regionMinutes[r];
}

// تقييم بناءً على النسبة والعتبات
// pct = (فعلي ÷ متوقع) × 100
// < excellent → ممتاز · بين الاتنين → جيد · > late → متأخر
function _grade(pct, excellentPct, latePct){
  if(pct < excellentPct) return 'excellent';
  if(pct > latePct)      return 'late';
  return 'good';
}

// التقييم الكامل للطلب. يرجّع null لو الطلب لسه ما اتسلّمش أو مفيش منطقة.
// يرجّع { pharmacy:{...}, driver:{...} } لو اتسلّم.
function evaluateOrder(o, settings, regionMinutes){
  // لازم يكون متسلّم (delivered_at موجود) أو completed
  if(!o.delivered_at) return null;
  const rm = _regionMins(o, regionMinutes);
  if(rm === null) return null; // مفيش منطقة → مفيش تقييم
  const s = settings || {};

  const delivered = new Date(o.delivered_at);

  // ===== تقييم الصيدلية =====
  // متوقع = منطقة + تجهيز + مراجعة + استلام + تسليم
  // فعلي = من آخر تشغيل → التسليم
  const phExpected = rm + (s.prep_minutes||0) + (s.review_minutes||0) + (s.pickup_minutes||0) + (s.handover_minutes||0);
  const phStart = new Date(o.last_activated_at || o.created_at);
  const phActual = Math.max(0, Math.floor((delivered - phStart)/60000));
  const phPct = phExpected>0 ? Math.round((phActual/phExpected)*100) : 0;
  const phGrade = _grade(phPct, s.pharmacy_excellent_pct||90, s.pharmacy_late_pct||110);

  // ===== تقييم الطيار =====
  // متوقع = منطقة + استلام + تسليم
  // فعلي = من آخر تعيين → التسليم
  let driver = null;
  if(o.assigned_at){
    const drExpected = rm + (s.pickup_minutes||0) + (s.handover_minutes||0);
    const drStart = new Date(o.assigned_at);
    const drActual = Math.max(0, Math.floor((delivered - drStart)/60000));
    const drPct = drExpected>0 ? Math.round((drActual/drExpected)*100) : 0;
    const drGrade = _grade(drPct, s.driver_excellent_pct||90, s.driver_late_pct||110);
    driver = { expected:drExpected, actual:drActual, pct:drPct, grade:drGrade };
  }

  return {
    pharmacy: { expected:phExpected, actual:phActual, pct:phPct, grade:phGrade },
    driver: driver
  };
}

// تسميات وألوان التقييم (للعرض)
const GRADE_LABEL = { excellent:'ممتاز', good:'جيد', late:'متأخر' };
const GRADE_COLOR = {
  excellent:{ bg:'#dcfce7', text:'#15803d' },
  good:     { bg:'#dbeafe', text:'#1e40af' },
  late:     { bg:'#fee2e2', text:'#b91c1c' }
};
const GRADE_ICON = { excellent:'🏆', good:'✓', late:'⚠️' };
