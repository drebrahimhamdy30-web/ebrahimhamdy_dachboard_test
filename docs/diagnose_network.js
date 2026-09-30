/* ═══════════════════════════════════════════════════════════════════
   تشخيص شبكة: الشاشة بتفتح بس البيانات مابتوصلش
   ═══════════════════════════════════════════════════════════════════
   العرض: الصفحة نفسها بتظهر، وفي الـConsole:
       Failed to load resource: net::ERR_CONNECTION_TIMED_OUT
       loadHeaderStats failed · TypeError: Failed to fetch
   يعني الاتصال بقاعدة البيانات **ماتفتحش أصلاً** (مش صلاحيات ولا توكن —
   دول بيرجّعوا 401/403 مش timeout). غالبًا الشبكة في المكان ده حاجبة
   الدومين، أو الـDNS بيرجّع عنوان غلط، أو فيه بروكسي في النص.

   الاستعمال: على الجهاز اللي فيه المشكلة، افتح phalix.ebrahimhamdy.com
   → F12 → Console → الصق ده كله → Enter → انسخ الناتج وابعته.

   ⚠️ مابيطبعش أي توكن ولا سر — عناوين وحالات وأزمنة بس.
   ═══════════════════════════════════════════════════════════════════ */
(async () => {
  const TIMEOUT = 8000;

  const TARGETS = [
    ['الإنترنت عمومًا',        'https://www.google.com/generate_204'],
    ['موقع النظام (الصفحات)',  'https://phalix.ebrahimhamdy.com/config.js'],
    ['قاعدة البيانات (السحابة)', 'https://rxtjoqulmgkkcohmgzgi.supabase.co/rest/v1/'],
    ['السيرفر الذاتي',         'https://supabase.ebrahimhamdy.com/rest/v1/'],
    ['ويبهوكات n8n',           'https://agent.ebrahimhamdy.com/healthz'],
    ['سيرفر eplus بتاع الفرع',  'https://eplus3.ebrahimhamdy.com/']
  ];

  const rows = [];
  for (const [name, url] of TARGETS) {
    const t0 = Date.now();
    let state;
    try {
      const c = new AbortController();
      const timer = setTimeout(() => c.abort(), TIMEOUT);
      const r = await fetch(url, { mode: 'no-cors', cache: 'no-store', signal: c.signal });
      clearTimeout(timer);
      // opaque رد كفاية: معناه الاتصال اتفتح ووصل للسيرفر
      state = '✅ وصل' + (r.type === 'opaque' ? '' : ' (HTTP ' + r.status + ')');
    } catch (e) {
      const ms = Date.now() - t0;
      state = (e.name === 'AbortError' || ms >= TIMEOUT - 200)
        ? '❌ علّق (timeout) — الاتصال ماتفتحش'
        : '❌ فشل فورًا (' + e.name + ') — غالبًا DNS أو حجب';
    }
    rows.push({ 'الوجهة': name, 'الحالة': state, 'الزمن (ملي ثانية)': Date.now() - t0 });
  }

  console.table(rows);

  const cloud = rows[2], site = rows[1], net = rows[0];
  let verdict;
  if (net['الحالة'].startsWith('❌'))            verdict = 'النت نفسه فاصل أو محجوب بالكامل على الجهاز ده.';
  else if (site['الحالة'].startsWith('❌'))      verdict = 'الموقع نفسه مش واصل — مشكلة DNS عامة على الشبكة دي.';
  else if (cloud['الحالة'].startsWith('❌'))     verdict = '⚠️ النت شغّال والموقع بيفتح، بس **قاعدة البيانات متحجوبة من الشبكة دي**. '
                                                        + 'راجع راوتر/فاير وول الفرع أو مزوّد الخدمة — الدومين supabase.co محتاج يتفك.';
  else                                          verdict = '✅ كل الوجهات واصلة — لو الشاشة لسه فاضية، المشكلة في التوكن أو الساعة (شغّل diagnose_device.js).';

  console.log('%c' + verdict, 'font-size:14px;font-weight:bold');

  /* ── الجزء التاني: تكرار النداء اللي بيقع فعلاً ──────────────────
     الفحص فوق بياخد لقطة واحدة، والانقطاع ساعات بيكون متقطّع. هنا
     بنكرّر **نفس نداء عدّادات الهيدر** (اللي بيطلّع ERR_CONNECTION_TIMED_OUT)
     خمس مرات ورا بعض عشان نشوف بيقع كل مرة ولا بالمزاج. */
  try {
    const base = (typeof PHALIX_CONFIG !== 'undefined' && PHALIX_CONFIG.supabaseUrl) || '';
    const key  = (typeof PHALIX_CONFIG !== 'undefined' && PHALIX_CONFIG.supabaseAnonKey) || '';
    if (base && key) {
      const url = base + '/rest/v1/orders?select=id&status=eq.pending&limit=1&offset=0';
      const tries = [];
      for (let i = 1; i <= 5; i++) {
        const t0 = Date.now();
        try {
          const c = new AbortController();
          const timer = setTimeout(() => c.abort(), TIMEOUT);
          const r = await fetch(url, { headers: { apikey: key, Authorization: 'Bearer ' + key },
                                       cache: 'no-store', signal: c.signal });
          clearTimeout(timer);
          tries.push({ 'المحاولة': i, 'النتيجة': '✅ HTTP ' + r.status, 'الزمن (ملي ثانية)': Date.now() - t0 });
        } catch (e) {
          tries.push({ 'المحاولة': i, 'النتيجة': '❌ ' + e.name, 'الزمن (ملي ثانية)': Date.now() - t0 });
        }
      }
      console.log('%cتكرار نداء عدّادات الهيدر (اللي بيقع):', 'font-weight:bold');
      console.table(tries);
      const bad = tries.filter(t => t['النتيجة'].startsWith('❌')).length;
      console.log('%c' + (bad === 0 ? '✅ الخمس محاولات نجحت — الانقطاع كان لحظي وقت فتح الصفحة (اعمل تحديث للصفحة).'
                 : bad === 5 ? '❌ الخمسة وقعوا — الاتصال بالقاعدة مقطوع فعلاً من الشبكة دي.'
                 : '⚠️ ' + bad + ' من 5 وقعوا — الاتصال **متقطّع**: نت الفرع ضعيف أو فيه انقطاع متكرر.'),
                 'font-size:13px;font-weight:bold');
    }
  } catch (e) { console.log('تعذّر تكرار النداء:', e.message); }

  console.log('المتصفح:', navigator.userAgent);
  console.log('الوقت على الجهاز:', new Date().toString());
})();
