// المزامنة السحابية التلقائية الصامتة عبر Firebase Realtime Database (REST فقط، بلا SDK/تسجيل دخول).
// الأجهزة التي تحمل نفس "الرمز السحابي" تتشارك آخر نسخة محدّثة. النسخ يُرفع تلقائياً
// في الخلفية، والاستعادة تجلب آخر نسخة محدّثة من السحابة بضغطة واحدة.
import { store } from './store.js';

const ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
const APP_VERSION = '2.0.0';

// ===== الإعداد =====
export function getCloudConfig() {
  const st = store.settings();
  return {
    backendUrl: (st.cloudBackendUrl || '').trim(),
    code: (st.cloudCode || '').trim(),
    autoSync: st.cloudAutoSync !== false,
    ready: !!(st.cloudBackendUrl || '').trim(),
  };
}

export async function setCloudBackend(url) {
  await store.setSetting('cloudBackendUrl', (url || '').trim());
}

export async function setCloudCode(code) {
  const clean = (code || '').toUpperCase().replace(/[^A-Z0-9]/g, '').slice(0, 8);
  await store.setSetting('cloudCode', clean);
  return clean;
}

export function generateCode(len = 5) {
  let s = '';
  for (let i = 0; i < len; i++) s += ALPHABET[Math.floor(Math.random() * ALPHABET.length)];
  return s;
}

// يضمن وجود رمز سحابي لهذا الجهاز (يُولَّد مرة واحدة).
export async function ensureCloudCode() {
  const { code } = getCloudConfig();
  if (code) return code;
  const fresh = generateCode();
  await store.setSetting('cloudCode', fresh);
  return fresh;
}

// يبني رابط السجل على Firebase (…/codes/<code>.json) أو متجر JSON متوافق.
export function targetFor(base, code) {
  const root = base.replace(/\/+$/, '');
  if (/firebaseio\.com|firebasedatabase\.app/i.test(root)) {
    return `${root}/codes/${code}.json`;
  }
  return `${root}/codes/${code}`;
}

// ===== طبقة HTTP (تُختبر محلياً) =====
export async function requestJson(target, method = 'GET', body) {
  const res = await fetch(target, {
    method,
    headers: { 'Content-Type': 'application/json' },
    body: body ? JSON.stringify(body) : undefined,
  });
  if (!res.ok) throw new Error(`Cloud HTTP ${res.status}`);
  const text = await res.text();
  return text ? JSON.parse(text) : null;
}

// بناء سجل النسخة المخزّن سحابياً (دالة نقية للاختبار).
export function buildRecord(code, payload) {
  const now = new Date();
  return {
    code,
    app: 'sijil',
    appVersion: APP_VERSION,
    updatedAt: now.toISOString(),
    updatedAtLocal: now.toLocaleString('ar-EG-u-ca-gregory-nu-latn'),
    sizeKb: payload && payload._meta && payload._meta.sizeKb ? payload._meta.sizeKb :
      `${(JSON.stringify(payload).length / 1024).toFixed(1)} KB`,
    payload,
  };
}

function payloadTs(payload) {
  const t = payload && payload._meta && payload._meta.timestamp;
  return t ? new Date(t).getTime() : 0;
}

// ===== قراءة آخر نسخة سحابية =====
export async function getCloudStatus() {
  const cfg = getCloudConfig();
  if (!cfg.ready) return { ready: false, configured: false };
  if (!cfg.code) return { ready: true, configured: true, code: '', hasCode: false };
  try {
    const rec = await requestJson(targetFor(cfg.backendUrl, cfg.code), 'GET');
    return {
      ready: true, configured: true, hasCode: true, code: cfg.code,
      exists: !!(rec && rec.payload),
      remote: rec || null,
      updatedAtLocal: rec && rec.updatedAtLocal ? rec.updatedAtLocal : null,
      sizeKb: rec && rec.sizeKb ? rec.sizeKb : null,
    };
  } catch (err) {
    return { ready: true, configured: true, hasCode: true, code: cfg.code, error: err.message || String(err) };
  }
}

// ===== رفع نسخة سحابية (لا يطمس نسخة أحدث من جهاز آخر) =====
export async function pushCloudBackup(payload, { force = false } = {}) {
  const cfg = getCloudConfig();
  if (!cfg.ready) return { ok: false, error: 'لم يُضبط رابط قاعدة البيانات السحابية بعد.' };
  const code = cfg.code || await ensureCloudCode();

  const target = targetFor(cfg.backendUrl, code);
  let existing = null;
  try { existing = await requestJson(target, 'GET'); } catch (_) { existing = null; }

  const localTs = payloadTs(payload);
  const remoteTs = existing && existing.payload ? payloadTs(existing.payload) : 0;
  if (existing && existing.payload && remoteTs > localTs && !force) {
    return { ok: true, skipped: true, remoteIsNewer: true, code,
      remoteDate: existing.updatedAtLocal, sizeKb: existing.sizeKb };
  }

  const rec = buildRecord(code, payload);
  await requestJson(target, 'PUT', rec);
  await store.setSetting('lastCloudSync', { date: rec.updatedAtLocal, size: rec.sizeKb, code });
  return { ok: true, code, date: rec.updatedAtLocal, sizeKb: rec.sizeKb };
}

// ===== سحب آخر نسخة سحابية =====
export async function pullCloudBackup() {
  const cfg = getCloudConfig();
  if (!cfg.ready) return { ok: false, error: 'لم يُضبط رابط قاعدة البيانات السحابية بعد.' };
  if (!cfg.code) return { ok: false, error: 'لا يوجد رمز سحابي.' };
  const rec = await requestJson(targetFor(cfg.backendUrl, cfg.code), 'GET');
  if (!rec || !rec.payload) return { ok: true, exists: false };
  return { ok: true, exists: true, payload: rec.payload, date: rec.updatedAtLocal, sizeKb: rec.sizeKb };
}
