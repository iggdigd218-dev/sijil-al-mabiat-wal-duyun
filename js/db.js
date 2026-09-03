// طبقة قاعدة البيانات — IndexedDB (تعمل دون إنترنت بشكل كامل)
const DB_NAME = 'nexora_db';
const DB_VERSION = 2;

function openDB() {
  return new Promise((resolve, reject) => {
    const req = indexedDB.open(DB_NAME, DB_VERSION);
    req.onupgradeneeded = (e) => {
      const db = e.target.result;
      if (!db.objectStoreNames.contains('meta')) {
        db.createObjectStore('meta');
      }
      if (!db.objectStoreNames.contains('settings')) {
        const s = db.createObjectStore('settings', { keyPath: 'key' });
        s.createIndex('by_key', 'key', { unique: true });
      }
      ['accounts', 'transactions', 'transactionItems', 'vouchers', 'categories', 'currencies', 'items',
       'conversations', 'messages', 'backups', 'activity', 'trash'].forEach((name) => {
        if (!db.objectStoreNames.contains(name)) {
          db.createObjectStore(name, { keyPath: 'id' });
        }
      });
      ['users', 'notifications', 'audit', 'templates', 'reminders', 'contacts'].forEach((name) => {
        if (!db.objectStoreNames.contains(name)) {
          db.createObjectStore(name, { keyPath: 'id' });
        }
      });
    };
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
}

let _db = null;
export async function getDB() {
  if (!_db) _db = await openDB();
  return _db;
}
export function setDBInstance(db) { _db = db; }

function tx(store, mode = 'readonly') {
  return getDB().then(db => db.transaction(store, mode).objectStore(store));
}
function reqToPromise(r) {
  return new Promise((res, rej) => { r.onsuccess = () => res(r.result); r.onerror = () => rej(r.error); });
}

export async function dbGetAll(store) {
  const s = await tx(store);
  return reqToPromise(s.getAll());
}
export async function dbGet(store, id) {
  const s = await tx(store);
  return reqToPromise(s.get(id));
}
export async function dbPut(store, value) {
  const s = await tx(store, 'readwrite');
  return reqToPromise(s.put(value));
}
export async function dbDelete(store, id) {
  const s = await tx(store, 'readwrite');
  return reqToPromise(s.delete(id));
}
export async function dbClear(store) {
  const s = await tx(store, 'readwrite');
  return reqToPromise(s.clear());
}
export async function dbBulk(store, values, mode = 'readwrite') {
  const s = await tx(store, mode);
  values.forEach(v => s.put(v));
  return new Promise((res, rej) => { s.transaction.oncomplete = res; s.transaction.onerror = () => rej(s.transaction.error); });
}
// حذف من خلال مؤشر يمسح كل السجلات
export async function dbClearWithCount(store) {
  const s = await tx(store, 'readwrite');
  return new Promise((res, rej) => {
    s.openCursor().onsuccess = (e) => {
      const c = e.target.result;
      if (c) { c.delete(); c.continue(); }
      else res();
    };
    s.transaction.onerror = () => rej(s.transaction.error);
  });
}

// إعادة تعيين كاملة (تشمل الإعدادات وسلة المحذوفات والنسخ المخزنة)
export async function resetAllData() {
  const db = await getDB();
  return new Promise((res, rej) => {
    const names = ['settings','accounts','transactions','transactionItems','vouchers','categories','currencies','items',
      'conversations','messages','backups','activity','trash','users','notifications',
      'audit','templates','reminders','contacts'];
    const t = db.transaction(names, 'readwrite');
    names.forEach(n => { try { t.objectStore(n).clear(); } catch (_) {} });
    t.oncomplete = res; t.onerror = () => rej(t.error);
  });
}

// طلب تخزين دائم من المتصفح لمنع الحذف التلقائي للبيانات عند ضغط المساحة
export async function requestPersistentStorage() {
  try {
    if (typeof navigator !== 'undefined' && navigator.storage && navigator.storage.persist) {
      const already = await navigator.storage.persisted();
      if (!already) await navigator.storage.persist();
    }
  } catch (_) { /* وضع الاختبار أو المتصفحات القديمة */ }
}

export async function dbSize() {
  const db = await getDB();
  return new Promise((res) => {
    try {
      navigator.storage && navigator.storage.estimate && navigator.storage.estimate().then(e => res(e.usage || 0));
    } catch (e) { res(0); }
  });
}

// إزالة الصور المولّدة ديناميكياً (receiptImage) لتقليص حجم النسخة ومنع تضخمها أُسّياً
function slimRecord(rec) {
  if (!rec || typeof rec !== 'object') return rec;
  const copy = { ...rec };
  // صور السندات تُعاد توليدها عند الحاجة، فلا داعي لتخزينها داخل النسخة
  if ('receiptImage' in copy) delete copy.receiptImage;
  if ('generatedImageData' in copy) delete copy.generatedImageData;
  if ('tempReceiptImage' in copy) delete copy.tempReceiptImage;
  return copy;
}

// تصدير كل البيانات ككائن (يستبعد سجل النسخ الاحتياطية نفسه لمنع التضخم الأُسّي)
export async function exportAllData() {
  // ملاحظة: 'backups' متعمَّد استبعادها لأن كل نسخة كانت تتضمن سابقاتها فينفجر الحجم
  const stores = ['settings','currencies','categories','accounts','transactions','transactionItems','vouchers','items',
    'conversations','messages','users','activity','templates','reminders','notifications','contacts','trash'];
  const out = { _version: DB_VERSION, _exportedAt: new Date().toISOString(), data: {} };
  for (const s of stores) {
    try {
      const rows = await dbGetAll(s);
      out.data[s] = Array.isArray(rows) ? rows.map(slimRecord) : [];
    } catch (e) { out.data[s] = []; }
  }
  return out;
}

// التحقق من سلامة حمولة النسخة قبل أي مسح للبيانات (حماية من فقدان البيانات)
function validateBackupPayload(payload) {
  if (!payload || typeof payload !== 'object') throw new Error('الملف ليس نسخة احتياطية صالحة (البنية غير صحيحة).');
  const data = payload.data;
  if (!data || typeof data !== 'object') throw new Error('الملف تالف: لا يحتوي على بيانات (data).');
  // يجب أن يحتوي على جدول أساسي واحد على الأقل بصيغة مصفوفة
  const keyTables = ['accounts', 'transactions'];
  const hasAnyTable = Object.keys(data).some(k => Array.isArray(data[k]));
  if (!hasAnyTable && !Array.isArray(data.transactions)) {
    throw new Error('الملف تالف أو فارغ: لا توجد بيانات قابلة للاستعادة.');
  }
  for (const k of keyTables) {
    if (data[k] !== undefined && !Array.isArray(data[k])) {
      throw new Error(`الملف تالف: الجدول ${k} ليس بالصيغة المتوقعة.`);
    }
  }
  return true;
}

// استيراد كل البيانات — يتحقق أولاً ثم يمسح، حتى لا تُفقد البيانات عند ملف تالف
export async function importAllData(payload) {
  validateBackupPayload(payload);
  const stores = ['settings','currencies','categories','accounts','transactions','transactionItems','vouchers','items',
    'conversations','messages','users','activity','templates','reminders','notifications','contacts','trash'];
  await resetAllData();
  for (const s of stores) {
    const arr = (payload.data && Array.isArray(payload.data[s])) ? payload.data[s] : [];
    if (arr.length) {
      try { await dbBulk(s, arr); }
      catch (e) {
        // في حال فشل متجر واحد (سعة/حجم) لا نُسقط البقية
        console.warn('import: تخطي متجر بسبب خطأ', s, e && e.message);
      }
    }
  }
}
