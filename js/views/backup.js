// النسخ الاحتياطي والاستعادة والتصدير/الاستيراد والتكامل مع Google Drive
import { $, $$, esc, fmt, uid, todayISO, nowStamp, downloadFile } from '../utils.js';
import { store } from '../store.js';
import { toast, toastErr, confirmDialog } from '../components.js';
import { exportAllData, importAllData, resetAllData, dbGetAll, dbSize } from '../db.js';
import { prepareBackupPayload } from '../drive.js';
import {
  getCloudConfig, ensureCloudCode, setCloudBackend, setCloudCode,
  getCloudStatus, pushCloudBackup, pullCloudBackup, generateCode,
} from '../cloud.js';
import { safeCreateBackup } from '../notifications.js';

export function render(container, params, state) {
  const backups = store.list('backups');
  const settings = store.settings();
  const est = dbSize();
  const cloud = getCloudConfig();
  const lastSync = settings.lastCloudSync;

  container.innerHTML = `
    <div class="view-head">
      <div>
        <div class="view-title">النسخ الاحتياطي والمزامنة السحابية 💾</div>
        <small>حماية بياناتك — مزامنة تلقائية صامتة عبر السحابة بين أجهزتك، أو نسخ محلي/ملف</small>
      </div>
    </div>

    <!-- البطاقة السحابية: مزامنة تلقائية صامتة عبر Firebase (بدون تسجيل دخول) -->
    <div class="card" style="border:2px solid var(--primary);background:linear-gradient(180deg,var(--surface),var(--surface2));margin-bottom:18px">
      <div style="display:flex;align-items:center;gap:14px;margin-bottom:12px">
        <div style="width:52px;height:52px;border-radius:16px;background:var(--primary-soft);display:flex;align-items:center;justify-content:center;font-size:26px">☁️</div>
        <div>
          <h3 style="font-size:17px;font-weight:800;color:var(--text);margin:0">المزامنة السحابية التلقائية</h3>
          <small style="color:var(--text2);font-size:13px">تُرفع نسختك تلقائياً في الخلفية، وتُسحب آخر نسخة محدّثة بضغطة واحدة — بدون تسجيل دخول أو ربط حساب</small>
        </div>
      </div>

      <div class="field" style="margin-bottom:10px">
        <label>رابط قاعدة البيانات السحابية (Firebase Realtime Database URL)</label>
        <div style="display:flex;gap:8px">
          <input type="text" id="cloud-url" class="input" dir="ltr" placeholder="https://xxxx-default-rtdb.firebaseio.com"
                 value="${esc(cloud.backendUrl || '')}" style="flex:1;text-align:left">
          <button class="btn soft sm" id="btn-cloud-save" style="white-space:nowrap">💾 حفظ</button>
        </div>
      </div>

      <div style="display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:12px;margin-bottom:12px">
        <div style="background:var(--surface2);border-radius:12px;padding:12px 14px;border:1px solid var(--border)">
          <div style="font-size:12.5px;color:var(--text2);margin-bottom:6px">🔑 الرمز السحابي (ضع نفسه على أجهزتك الأخرى)</div>
          <div style="display:flex;gap:8px;align-items:center">
            <b id="cloud-code-val" dir="ltr" style="font-size:22px;letter-spacing:4px;color:var(--primary);font-family:monospace">${esc(cloud.code || '— — — —')}</b>
            <button class="btn sm ghost" id="btn-cloud-copy-code" title="نسخ الرمز">📋</button>
            <button class="btn sm ghost" id="btn-cloud-new-code" title="رمز جديد">🔄</button>
          </div>
        </div>
        <div style="background:var(--surface2);border-radius:12px;padding:12px 14px;border:1px solid var(--border)">
          <div style="font-size:12.5px;color:var(--text2);margin-bottom:4px">🕒 آخر مزامنة سحابية:</div>
          <b id="cloud-last" style="font-size:14px;color:var(--text)">${lastSync ? esc(lastSync.date) : 'لم تتم المزامنة بعد'}</b>
          ${lastSync ? `<small id="cloud-last-size" style="display:block;color:var(--text3);margin-top:2px">الحجم: ${esc(lastSync.size || '')}</small>` : '<small style="display:block;color:var(--text3);margin-top:2px" id="cloud-last-size"></small>'}
        </div>
      </div>

      <label class="chk" style="margin-bottom:12px">
        <input type="checkbox" id="cloud-auto" ${cloud.autoSync ? 'checked' : ''}>
        <span>مزامنة تلقائية صامتة في الخلفية بعد كل تغيير</span>
      </label>

      <div style="display:flex;gap:10px;flex-wrap:wrap">
        <button class="btn primary big" id="btn-cloud-push" style="flex:1">☁️ رفع النسخة الآن</button>
        <button class="btn soft big" id="btn-cloud-pull" style="flex:1">↩️ سحب آخر نسخة محدّثة من السحابة</button>
      </div>

      <details style="margin-top:12px;background:var(--accent-soft);border-radius:12px;border:1px solid color-mix(in srgb,var(--accent) 25%,transparent);padding:10px 14px">
        <summary style="cursor:pointer;font-weight:700;color:var(--text);font-size:13.5px">⚙️ كيف أنشئ قاعدة البيانات السحابية؟ (مرة واحدة، مجاناً)</summary>
        <ol style="font-size:12.5px;color:var(--text2);line-height:1.8;margin:10px 18px 0 0;padding:0">
          <li>افتح <b dir="ltr">console.firebase.google.com</b> وأنشئ مشروعاً مجانياً (أي اسم).</li>
          <li>من القائمة اختر <b>Realtime Database</b> ← <b>Create Database</b>، واختر أي منطقة.</li>
          <li>في تبويب <b>Rules</b> ضع السماح بالقراءة والكتابة:
            <code dir="ltr" style="display:block;background:var(--surface);padding:6px 8px;border-radius:6px;margin-top:4px">{ "rules": { ".read": true, ".write": true } }</code>
          </li>
          <li>انسخ رابط القاعدة (صيغته <b dir="ltr">https://xxxxx-default-rtdb.firebaseio.com</b>) والصقه في الحقل بالأعلى واضغط «حفظ».</li>
          <li>انسخ <b>الرمز السحابي</b> وضع نفس الرابط والرمز على هاتفك الآخر لتتزامن البيانات بينهما.</li>
        </ol>
      </details>
    </div>

    <!-- شبكة النسخ المحلي والتصدير -->
    <div class="grid grid-2">
      <!-- 1. النسخ الاحتياطي المحلي -->
      <div class="card">
        <div class="section-title">نسخة احتياطية محلية (على هذا الجهاز)</div>
        <p class="muted" style="margin-bottom:14px">إنشاء وحفظ نسخة كاملة سريعة في متصفحك أو جهازك الحالي. <span id="bk-size"></span></p>
        <button class="btn primary block big" data-backup>⬇️ إنشاء نسخة محلية فورية</button>
        
        <div class="divider"></div>
        
        <div class="section-title">استعادة نسخة محلية سابقة</div>
        <p class="muted" style="margin-bottom:14px">استرجاع نسخة محفوظة مسبقاً. <b style="color:var(--danger)">سيتم استبدال البيانات الحالية!</b></p>
        <select class="select" id="bk-list" style="width:100%;margin-bottom:10px">
          <option value="">— اختر نسخة احتياطية من السجل —</option>
          ${backups.map(b => `<option value="${b.id}">${esc(b.name)} — ${esc(b.date)} (${esc(b.size || '')})</option>`).join('')}
        </select>
        <button class="btn danger block" data-restore>↩️ استعادة النسخة المختارة</button>
      </div>

      <!-- 2. التصدير والاستيراد والتلقائي -->
      <div class="card">
        <div class="section-title">تصدير / استيراد ملف خارجي</div>
        <p class="muted" style="margin-bottom:14px">تصدير ملف JSON يحتوي كل بياناتك لنقله لأي هاتف أو حاسوب آخر، أو استيراده هنا.</p>
        <button class="btn soft block" data-export>📤 تصدير قاعدة البيانات كملف (JSON)</button>
        
        <div class="divider"></div>
        
        <label class="btn ghost block" style="cursor:pointer">📥 استيراد قاعدة بيانات من ملف خارجي
          <input type="file" id="import-file" accept=".json" style="display:none">
        </label>
        
        <div class="divider"></div>

        <div class="section-title">إعدادات الجدولة والتلقائية</div>
        <label class="chk" style="margin-bottom:10px">
          <input type="checkbox" id="auto-bk" ${settings.autoBackup !== false ? 'checked' : ''}>
          <span>تفعيل النسخ الاحتياطي التلقائي داخل الجهاز عند تسجيل العمليات</span>
        </label>
        <p class="hint" style="font-size:12px;color:var(--text3);margin-top:6px">
          💡 النسخ المحلي التلقائي يُحفظ داخل الجهاز. إن فعّلت «المزامنة التلقائية» بالأعلى، تُرفع نسخة للسحابة في الخلفية بعد كل تغيير.
        </p>
      </div>
    </div>

    <!-- سجل النسخ المحفوظة -->
    <div class="card" style="margin-top:16px">
      <div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:12px">
        <div class="section-title" style="margin-bottom:0">سجل النسخ الاحتياطية المحفوظة محلياً</div>
        <span class="tag">${backups.length} نسخة محفوظة</span>
      </div>
      ${backups.length ? `
        <div class="table-wrap">
          <table class="tbl">
            <thead>
              <tr>
                <th>الاسم</th>
                <th>التاريخ والوقت</th>
                <th>الحجم</th>
                <th>النوع</th>
                <th style="width:120px">إجراءات</th>
              </tr>
            </thead>
            <tbody>
              ${backups.map(b => `
                <tr>
                  <td><b>${esc(b.name)}</b></td>
                  <td>${esc(b.date)}</td>
                  <td>${esc(b.size || '—')}</td>
                  <td><span class="pill ${b.type === 'تلقائي' ? 'teal' : 'blue'}">${esc(b.type || 'تلقائي')}</span></td>
                  <td>
                    <button class="btn sm soft" data-download-bk="${b.id}" title="تنزيل كملف">📥</button>
                    <button class="btn sm danger" data-del-bk="${b.id}" title="حذف">🗑️</button>
                  </td>
                </tr>
              `).join('')}
            </tbody>
          </table>
        </div>
      ` : '<div class="muted" style="text-align:center;padding:24px 0">لا توجد نسخ احتياطية محفوظة بعد — قم بإنشاء أول نسخة الآن لحماية بياناتك.</div>'}
    </div>
  `;

  // الحجم التقديري
  est.then(bytes => {
    const size = $('#bk-size', container);
    if (size && bytes) size.textContent = `(حجم البيانات الحالي: ${(bytes/1024).toFixed(1)} KB)`;
  });

  // حفظ رابط قاعدة البيانات السحابية
  $('#btn-cloud-save', container).onclick = async () => {
    const url = $('#cloud-url', container).value.trim();
    await setCloudBackend(url);
    if (url) {
      await ensureCloudCode();
      toast('تم حفظ إعداد المزامنة السحابية ✅');
    } else {
      toast('تم مسح رابط السحابة', 'warn');
    }
    render(container, params, state);
  };

  // المزامنة التلقائية تشغيل/إيقاف
  $('#cloud-auto', container).addEventListener('change', async (e) => {
    await store.setSetting('cloudAutoSync', e.target.checked);
    toast(e.target.checked ? 'المزامنة التلقائية مفعّلة ☁️' : 'تم إيقاف المزامنة التلقائية');
  });

  // نسخ / تجديد الرمز السحابي
  $('#btn-cloud-copy-code', container).onclick = async () => {
    const code = await ensureCloudCode();
    try { await navigator.clipboard.writeText(code); toast('تم نسخ الرمز السحابي 📋'); }
    catch (_) { toast(`الرمز: ${code}`); }
  };
  $('#btn-cloud-new-code', container).onclick = async () => {
    const ok = await confirmDialog({
      title: 'توليد رمز سحابي جديد',
      message: 'سيبدأ هذا الجهاز نسخة سحابية جديدة برمز جديد. الأجهزة التي تحمل الرمز القديم لن تتزامن معه بعد الآن. متابعة؟',
      confirmText: 'توليد رمز جديد',
    });
    if (!ok) return;
    const c = await setCloudCode(generateCode());
    toast(`الرمز الجديد: ${c}`);
    render(container, params, state);
  };

  // رفع النسخة الآن
  $('#btn-cloud-push', container).onclick = async (e) => {
    const btn = e.currentTarget;
    btn.disabled = true; btn.textContent = 'جاري الرفع للسحابة... ⏳';
    try {
      const cfg = getCloudConfig();
      if (!cfg.ready) { toastErr('أدخل رابط قاعدة البيانات السحابية أولاً (الخطوات داخل «كيف أنشئ القاعدة»)'); return; }
      await ensureCloudCode();
      const payload = await prepareBackupPayload();
      const res = await pushCloudBackup(payload, { force: true });
      if (res.ok && res.skipped) toast('النسخة السحابية أحدث من المحلية — لم يُستبدل شيء ✅', 'warn');
      else if (res.ok) toast(`تمت المزامنة السحابية بنجاح (${res.sizeKb}) ✅`);
      else toastErr(res.error || 'فشل الرفع');
      render(container, params, state);
    } catch (err) {
      console.error('Cloud push failed:', err);
      toastErr(`فشل الرفع للسحابة: ${err.message || 'تحقق من الرابط والإنترنت'}`);
      btn.disabled = false; btn.textContent = '☁️ رفع النسخة الآن';
    }
  };

  // سحب آخر نسخة محدّثة من السحابة واستعادتها
  $('#btn-cloud-pull', container).onclick = async (e) => {
    const btn = e.currentTarget;
    btn.disabled = true; btn.textContent = 'جاري سحب آخر نسخة... ⏳';
    try {
      const cfg = getCloudConfig();
      if (!cfg.ready) { toastErr('أدخل رابط قاعدة البيانات السحابية أولاً'); return; }
      if (!cfg.code) { await ensureCloudCode(); toastErr('لا توجد نسخة سحابية على هذا الرمز بعد — ارفع نسخة أولاً'); return; }
      const res = await pullCloudBackup();
      if (!res.ok) { toastErr(res.error || 'فشل السحب'); btn.disabled = false; btn.textContent = '↩️ سحب آخر نسخة محدّثة من السحابة'; return; }
      if (!res.exists) { toast('لا توجد نسخة سحابية بعد على هذا الرمز — اضغط «رفع النسخة الآن» أولاً', 'warn'); btn.disabled = false; btn.textContent = '↩️ سحب آخر نسخة محدّثة من السحابة'; return; }

      const ok = await confirmDialog({
        title: '⚠️ استعادة من السحابة',
        message: `تم العثور على آخر نسخة محدّثة في السحابة (${res.date}، ${res.sizeKb}).\n\nسيتم استبدال البيانات الحالية بالكامل بالنسخة السحابية. متابعة؟`,
        danger: true,
        confirmText: 'استعادة واستبدال البيانات',
      });
      if (!ok) { btn.disabled = false; btn.textContent = '↩️ سحب آخر نسخة محدّثة من السحابة'; return; }

      await importAllData(res.payload);
      await store.load();
      toast('تمت استعادة آخر نسخة محدّثة من السحابة بنجاح ✅');
      render(container, params, state);
    } catch (err) {
      console.error('Cloud pull failed:', err);
      toastErr(`فشل السحب من السحابة: ${err.message || 'تحقق من الرابط والإنترنت'}`);
      btn.disabled = false; btn.textContent = '↩️ سحب آخر نسخة محدّثة من السحابة';
    }
  };

  // أحداث النسخ والاستعادة المحلية والتصدير
  container.addEventListener('click', async (e) => {
    if (e.target.closest('[data-backup]')) await doBackup(container, params, state);
    if (e.target.closest('[data-restore]')) await doRestore(container, params, state);
    if (e.target.closest('[data-export]')) await doExport();
    
    // تنزيل نسخة مسجلة كملف
    const dlBtn = e.target.closest('[data-download-bk]');
    if (dlBtn) {
      const id = dlBtn.dataset.downloadBk;
      const bk = store.get('backups', id);
      if (bk && bk.data) {
        downloadFile(`${bk.name.replace(/\s+/g, '_')}.json`, JSON.stringify(bk.data, null, 2), 'application/json');
        toast('تم بدء تنزيل النسخة');
      }
    }

    // حذف نسخة محلية
    const delBtn = e.target.closest('[data-del-bk]');
    if (delBtn) {
      const id = delBtn.dataset.delBk;
      const ok = await confirmDialog({
        title: 'حذف نسخة احتياطية',
        message: 'هل أنت متأكد من حذف هذه النسخة من السجل المحلي؟',
        danger: true,
        confirmText: 'حذف',
      });
      if (!ok) return;
      await store.remove('backups', id);
      toast('تم حذف النسخة من السجل');
      render(container, params, state);
    }
  });

  $('#auto-bk', container).addEventListener('change', async (e) => {
    await store.setSetting('autoBackup', e.target.checked);
    toast('تم تحديث إعداد النسخ التلقائي');
  });

  const fileInput = $('#import-file', container);
  fileInput.addEventListener('change', async () => {
    const f = fileInput.files[0];
    if (!f) return;
    try {
      const text = await f.text();
      const payload = JSON.parse(text);
      const ok = await confirmDialog({
        title: '⚠️ تحذير استيراد ملف خارجي',
        message: 'سيتم استبدال كل البيانات الحالية بالبيانات المستوردة من هذا الملف. لا يمكن التراجع عن هذا الإجراء!',
        danger: true,
        confirmText: 'استيراد واستبدال الآن'
      });
      if (!ok) { fileInput.value = ''; return; }
      await importAllData(payload);
      await store.load();
      toast('تم استيراد البيانات بنجاح ✅');
      render(container, params, state);
    } catch (err) {
      toastErr('ملف غير صالح أو تعذّر الاستيراد: ' + (err.message || ''));
    }
    fileInput.value = '';
  });
}

async function doBackup(container, params, state) {
  const data = await prepareBackupPayload();
  const now = new Date();
  const name = `نسخة يدوية ${todayISO()} ${now.toTimeString().slice(0, 5)}`;
  const rawStr = JSON.stringify(data);
  const rec = {
    id: uid('bk'),
    name,
    date: now.toLocaleString('ar-EG-u-ca-gregory-nu-latn'),
    size: (rawStr.length / 1024).toFixed(1) + ' KB',
    type: 'يدوي',
    data,
    createdAt: now.toISOString(),
  };
  const savedLocally = await safeCreateBackup(rec);
  if (!savedLocally) {
    // امتلأت سعة التخزين المحلي؛ نوفر نسخة للتنزيل بدل فقدانها
    downloadFile(`edara-backup-${todayISO()}.json`, JSON.stringify(data, null, 2), 'application/json');
    toast('امتلأت مساحة التخزين المحلية؛ تم تنزيل النسخة كملف بدلاً من حفظها داخل التطبيق ⚠️', 'warn');
  } else {
    toast('تم إنشاء وحفظ النسخة الاحتياطية محلياً بنجاح ✅');
  }
  if (container) render(container, params, state);
}

async function doRestore(container, params, state) {
  const sel = $('#bk-list', container).value;
  if (!sel) { toastErr('يرجى اختيار نسخة احتياطية من القائمة أولاً'); return; }
  const bk = store.get('backups', sel);
  if (!bk || !bk.data) { toastErr('النسخة المختارة غير صالحة أو تالفة'); return; }
  const ok = await confirmDialog({
    title: '⚠️ استعادة نسخة احتياطية',
    message: `سيتم استبدال البيانات الحالية بالكامل ببيانات "${bk.name}" (${bk.date}). متابعة؟`,
    danger: true,
    confirmText: 'استعادة وتطبيق البيانات'
  });
  if (!ok) return;
  await importAllData(bk.data);
  await store.load();
  toast('تمت استعادة البيانات بنجاح ✅');
  render(container, params, state);
}

async function doExport() {
  const data = await prepareBackupPayload();
  downloadFile(`edara-backup-${todayISO()}.json`, JSON.stringify(data, null, 2), 'application/json');
  toast('تم تصدير ملف قاعدة البيانات الكاملة بنجاح ✅');
}
