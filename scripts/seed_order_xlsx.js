/* بيجيب طلبية تأسيس السيوف من سان ستيفانو ويبني منها شيت.
   مفيش مكتبات — نفس طريقة make_avail_xlsx.js المستعملة قبل كده. */
const fs = require('fs'), path = require('path'), zlib = require('zlib');
const cfg = JSON.parse(fs.readFileSync(
  path.join(process.env.USERPROFILE, '.phalix', 'sync_engine.json'), 'utf8').replace(/^﻿/, ''));
const SB = (cfg.supabaseUrl || cfg.sbUrl).replace(/\/$/, '');
const KEY = cfg.serviceKey || cfg.service_key;
/* الاستعمال: node scripts/seed_order_xlsx.js <الملف> [الفرع] [الفرع المرجع] */
const OUT = process.argv[2];
const TARGET = process.argv[3] || 'السيوف';
const SOURCE = process.argv[4] || 'سان ستيفانو';

const CAT_AR = { med: 'أدوية', cos: 'كوزمو', paper: 'ورقيات', sup: 'مستلزمات طبية' };

(async () => {
  const r = await fetch(SB + '/rest/v1/rpc/get_new_branch_seed_order', {
    method: 'POST',
    headers: { apikey: KEY, Authorization: 'Bearer ' + KEY, 'Content-Type': 'application/json' },
    body: JSON.stringify({ p_target: TARGET, p_source: SOURCE })
  });
  if (!r.ok) { console.error('✗ ' + r.status + ' ' + (await r.text()).slice(0, 300)); process.exit(1); }
  const rows = await r.json();
  console.log('صفوف من القاعدة:', rows.length);

  const n = v => { const x = Number(v); return isFinite(x) ? x : null; };

  /* الشيت: اللي محتاج شراء الأول (مرتّب بالكمية)، وبعده اللي يتغطى بالتحويل */
  const buy = rows.filter(x => n(x.net_qty) > 0);
  const trf = rows.filter(x => n(x.net_qty) === 0);

  const HEAD = ['الكود', 'الصنف', 'الشركة', 'الوحدة', 'التصنيف',
                'رصيد '+SOURCE, 'استهلاك '+SOURCE+'/شهر', 'هدف شراء '+SOURCE, 'الشريحة %',
                'معدل '+TARGET+' المشتق', 'المطلوب',
                'أكبر فائض عند فرع', 'الفرع', 'صافى الشراء',
                'لو الشريحة ١٠٪', 'المخزن', 'السعر', 'الخصم %', 'الصافى', 'قيمة السطر'];
  const NUM = new Set([5, 6, 7, 8, 9, 10, 11, 13, 14, 16, 17, 18, 19]);

  const toRow = x => [
    String(x.itm_code == null ? '' : x.itm_code),
    x.itm_name || '', x.company || '', x.unit || '', CAT_AR[x.cat] || x.cat || '',
    n(x.src_stock), n(x.src_base), n(x.src_target), n(x.tier_pct),
    n(x.derived_rate), n(x.req_qty_n),
    n(x.surplus_max), x.surplus_branch || '', n(x.net_qty),
    n(x.net_qty_alt), x.store || '', n(x.price), n(x.disc), n(x.net_price), n(x.line_value)
  ];

  const sheets = [
    { name: 'للشراء من المخازن', rows: buy.map(toRow) },
    { name: 'يتغطى بالتحويل',   rows: trf.map(toRow) }
  ];

  const esc = s => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;')
    .replace(/>/g, '&gt;').replace(/"/g, '&quot;');
  const col = i => { let s = ''; i++; while (i > 0) { const m = (i - 1) % 26; s = String.fromCharCode(65 + m) + s; i = (i - 1 - m) / 26; } return s; };

  function sheetXml(data) {
    const all = [HEAD].concat(data);
    let x = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      + '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
      + '<sheetViews><sheetView rightToLeft="1" tabSelected="1" workbookViewId="0">'
      + '<pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>'
      + '<cols><col min="1" max="1" width="11" customWidth="1"/>'
      + '<col min="2" max="2" width="38" customWidth="1"/>'
      + '<col min="3" max="3" width="20" customWidth="1"/>'
      + '<col min="4" max="5" width="13" customWidth="1"/>'
      + '<col min="6" max="15" width="14" customWidth="1"/>'
      + '<col min="16" max="16" width="18" customWidth="1"/>'
      + '<col min="17" max="20" width="12" customWidth="1"/></cols><sheetData>';
    all.forEach((rw, i) => {
      x += '<row r="' + (i + 1) + '">';
      rw.forEach((v, j) => {
        if (v === '' || v == null) return;
        const ref = col(j) + (i + 1);
        const isNum = i > 0 && NUM.has(j) && typeof v === 'number';
        x += isNum
          ? '<c r="' + ref + '" s="0"><v>' + v + '</v></c>'
          : '<c r="' + ref + '" t="str" s="' + (i === 0 ? 1 : 0) + '"><v>' + esc(v) + '</v></c>';
      });
      x += '</row>';
    });
    return x + '</sheetData><autoFilter ref="A1:T' + all.length + '"/></worksheet>';
  }

  const files = {};
  const overrides = sheets.map((s, i) =>
    '<Override PartName="/xl/worksheets/sheet' + (i + 1) + '.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>').join('');
  files['[Content_Types].xml'] = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    + '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
    + '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
    + '<Default Extension="xml" ContentType="application/xml"/>'
    + '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
    + overrides
    + '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/></Types>';
  files['_rels/.rels'] = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    + '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
    + '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>';
  files['xl/workbook.xml'] = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    + '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"'
    + ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>'
    + sheets.map((s, i) => '<sheet name="' + esc(s.name) + '" sheetId="' + (i + 1) + '" r:id="rId' + (i + 1) + '"/>').join('')
    + '</sheets></workbook>';
  files['xl/_rels/workbook.xml.rels'] = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    + '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
    + sheets.map((s, i) => '<Relationship Id="rId' + (i + 1) + '" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet' + (i + 1) + '.xml"/>').join('')
    + '<Relationship Id="rIdS" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>';
  files['xl/styles.xml'] = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    + '<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
    + '<fonts count="2"><font><sz val="11"/><name val="Calibri"/></font>'
    + '<font><b/><sz val="11"/><color rgb="FFFFFFFF"/><name val="Calibri"/></font></fonts>'
    + '<fills count="3"><fill><patternFill patternType="none"/></fill>'
    + '<fill><patternFill patternType="gray125"/></fill>'
    + '<fill><patternFill patternType="solid"><fgColor rgb="FF0F766E"/><bgColor indexed="64"/></patternFill></fill></fills>'
    + '<borders count="1"><border/></borders><cellStyleXfs count="1"><xf/></cellStyleXfs>'
    + '<cellXfs count="2"><xf xfId="0"/><xf xfId="0" fontId="1" fillId="2" applyFont="1" applyFill="1"/></cellXfs></styleSheet>';
  sheets.forEach((s, i) => { files['xl/worksheets/sheet' + (i + 1) + '.xml'] = sheetXml(s.rows); });

  const crcT = (() => { const t = []; for (let i = 0; i < 256; i++) { let c = i; for (let k = 0; k < 8; k++) c = c & 1 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1; t[i] = c >>> 0; } return t; })();
  const crc32 = b => { let c = 0xFFFFFFFF; for (let i = 0; i < b.length; i++) c = crcT[(c ^ b[i]) & 0xFF] ^ (c >>> 8); return (c ^ 0xFFFFFFFF) >>> 0; };
  const loc = [], cen = []; let off = 0;
  Object.entries(files).forEach(([name, content]) => {
    const dd = Buffer.from(content, 'utf8'), z = zlib.deflateRawSync(dd), nm = Buffer.from(name, 'utf8');
    const lh = Buffer.alloc(30);
    lh.writeUInt32LE(0x04034b50, 0); lh.writeUInt16LE(20, 4); lh.writeUInt16LE(0x0800, 6);
    lh.writeUInt16LE(8, 8); lh.writeUInt32LE(crc32(dd), 14); lh.writeUInt32LE(z.length, 18);
    lh.writeUInt32LE(dd.length, 22); lh.writeUInt16LE(nm.length, 26);
    loc.push(lh, nm, z);
    const ch = Buffer.alloc(46);
    ch.writeUInt32LE(0x02014b50, 0); ch.writeUInt16LE(20, 4); ch.writeUInt16LE(20, 6);
    ch.writeUInt16LE(0x0800, 8); ch.writeUInt16LE(8, 10); ch.writeUInt32LE(crc32(dd), 16);
    ch.writeUInt32LE(z.length, 20); ch.writeUInt32LE(dd.length, 24); ch.writeUInt16LE(nm.length, 28);
    ch.writeUInt32LE(off, 42);
    cen.push(ch, nm); off += 30 + nm.length + z.length;
  });
  const cb = Buffer.concat(cen), eo = Buffer.alloc(22);
  eo.writeUInt32LE(0x06054b50, 0); eo.writeUInt16LE(Object.keys(files).length, 8);
  eo.writeUInt16LE(Object.keys(files).length, 10); eo.writeUInt32LE(cb.length, 12); eo.writeUInt32LE(off, 16);
  fs.writeFileSync(OUT, Buffer.concat([Buffer.concat(loc), cb, eo]));

  const sum = (a, k) => Math.round(a.reduce((s, x) => s + (Number(x[k]) || 0), 0));
  const withStore = buy.filter(x => x.store).length;
  console.log('— للشراء من المخازن:', buy.length, 'صنف ·', sum(buy, 'net_qty'), 'وحدة ·',
    sum(buy, 'line_value').toLocaleString('en-US'), 'جنيه ·', withStore, 'منهم له مخزن متاح');
  console.log('— يتغطى بالتحويل  :', trf.length, 'صنف');
  const byStore = {};
  buy.forEach(x => { const s = x.store || '(مفيش مخزن متاح)'; byStore[s] = (byStore[s] || 0) + (Number(x.net_qty) || 0); });
  console.log('\nالتوزيع على المخازن:');
  Object.entries(byStore).sort((a, b) => b[1] - a[1])
    .forEach(([s, q]) => console.log('  ' + (s + '                      ').slice(0, 24) + q + ' وحدة'));
  console.log('\nاتكتب:', OUT);
})().catch(e => { console.error('✗ ' + e.message); process.exit(1); });
