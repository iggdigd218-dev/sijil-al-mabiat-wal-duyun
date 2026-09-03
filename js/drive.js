// النسخ الاحتياطي السحابي عبر Google Drive بلا مصادقة معقّدة:
// نولّد ملف النسخة ونفتح قائمة المشاركة الأصلية للنظام، فيختار المستخدم
// تطبيق Google Drive ثم حسابه ثم يضغط «حفظ/موافق» — بصفر إعدادات أو OAuth.
import { exportAllData } from './db.js';
import { store } from './store.js';
import { downloadFile } from './utils.js';

function dateStamp() {
  const d = new Date();
  const p = (n) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
}

function backupFileName() {
  return `نسخة-سجل-المبيعات-${dateStamp()}.json`;
}

/**
 * تحضير محتوى النسخة الاحتياطية (نفس البنية القديمة) مع بيانات وصفية.
 */
export async function prepareBackupPayload() {
  const raw = await exportAllData();

  if (raw.data && raw.data.vouchers) {
    raw.data.vouchers = raw.data.vouchers.map(v => {
      const clean = { ...v };
      delete clean.generatedImageData;
      delete clean.tempReceiptImage;
      return clean;
    });
  }

  raw._meta = {
    appName: 'سجل المبيعات والديون',
    version: '2.0.0',
    timestamp: new Date().toISOString(),
    exportedAtFormatted: new Date().toLocaleString('ar-EG-u-ca-gregory-nu-latn'),
  };

  return raw;
}

function jsonToFile(jsonStr, name) {
  try {
    const blob = new Blob([jsonStr], { type: 'application/json' });
    return new File([blob], name, { type: 'application/json' });
  } catch (_) {
    return null;
  }
}

// مسار تطبيق الأندرويد الأصلي (Capacitor): نكتب الملف مؤقتاً ونستدعي المشاركة الأصلية
async function nativeShareBackup(jsonStr, fileName) {
  try {
    const Cap = globalThis.Capacitor;
    const isNative = Cap && typeof Cap.isNativePlatform === 'function' && Cap.isNativePlatform();
    if (!isNative) return false;
    const { Share } = await import('@capacitor/share');
    if (!Share || typeof Share.share !== 'function') return false;

    let fileUri = null;
    try {
      const { Filesystem, Directory, Encoding } = await import('@capacitor/filesystem');
      const w = await Filesystem.writeFile({
        path: fileName,
        data: jsonStr,
        directory: Directory.Cache,
        encoding: Encoding.UTF8,
        recursive: true,
      });
      fileUri = w.uri;
    } catch (_) { fileUri = null; }

    await Share.share({
      title: 'حفظ نسخة احتياطية سحابية',
      text: 'اختر Google Drive ثم حسابك ثم اضغط حفظ لحفظ النسخة السحابية.',
      url: fileUri || undefined,
      dialogTitle: 'حفظ النسخة الاحتياطية في Google Drive',
    });
    return true;
  } catch (err) {
    if (err && (err.message === 'AbortError' || /cancel/i.test(err.message || ''))) return null; // ألغى المستخدم
    return false;
  }
}

/**
 * النسخ السحابي: يفتح قائمة المشاركة ليختار المستخدم Google Drive ويحفظ على حسابه.
 * في الويب يستخدم Web Share API مع إرفاق الملف؛ وإن تعذّر ينزّل الملف محلياً.
 * @returns {Promise<{shared:boolean, fileName:string, sizeKb:string}>}
 */
export async function shareCloudBackup() {
  const payload = await prepareBackupPayload();
  const jsonStr = JSON.stringify(payload, null, 2);
  const fileName = backupFileName();
  const sizeKb = `${(jsonStr.length / 1024).toFixed(1)} KB`;

  // 1) الأندرويد الأصلي
  const native = await nativeShareBackup(jsonStr, fileName);
  if (native === true) {
    await recordCloudBackup(sizeKb);
    return { shared: true, native: true, fileName, sizeKb };
  }
  if (native === null) {
    return { shared: false, cancelled: true, fileName, sizeKb };
  }

  // 2) الويب: Web Share API مع إرفاق الملف (يظهر Google Drive في القائمة)
  const nav = typeof navigator !== 'undefined' ? navigator : {};
  const file = jsonToFile(jsonStr, fileName);
  const canShareFiles = file && typeof nav.canShare === 'function' && nav.canShare({ files: [file] });
  if (file && typeof nav.share === 'function' && (canShareFiles || typeof nav.canShare !== 'function')) {
    try {
      await nav.share({
        files: canShareFiles ? [file] : undefined,
        title: 'حفظ نسخة احتياطية سحابية',
        text: 'اختر Google Drive ثم حسابك ثم احفظ.',
      });
      await recordCloudBackup(sizeKb);
      return { shared: true, native: false, fileName, sizeKb };
    } catch (err) {
      if (err && (err.name === 'AbortError' || /cancel/i.test(err.message || ''))) {
        return { shared: false, cancelled: true, fileName, sizeKb };
      }
      // إن لم يدعم مشاركة الملفات ننتقل للتنزيل
    }
  }

  // 3) فولباك: تنزيل الملف ليحفظه المستخدم في Drive يدوياً
  downloadFile(fileName, jsonStr, 'application/json');
  await recordCloudBackup(sizeKb);
  return { shared: true, downloaded: true, fileName, sizeKb };
}

async function recordCloudBackup(sizeKb) {
  try {
    await store.setSetting('lastCloudBackup', {
      date: new Date().toLocaleString('ar-EG-u-ca-gregory-nu-latn'),
      size: sizeKb,
      via: 'share-drive',
    });
  } catch (_) { /* غير حرج */ }
}
