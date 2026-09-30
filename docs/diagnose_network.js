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
    ['سيرفر eplus بتاع الفرع',  'http://eplus3.ebrahimhamdy.com/']
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
  console.log('المتصفح:', navigator.userAgent);
  console.log('الوقت على الجهاز:', new Date().toString());
})();
