// نظام تنبيهات الدفع (Push Notifications) والمزامنة في وضع السكون والنسخ الاحتياطي الذكي
import { store } from './store.js';
import { exportAllData } from './db.js';
import { uid, todayISO, fmt } from './utils.js';
import { toast, toastErr } from './components.js';
// المزامنة السحابية التلقائية الصامتة عبر Firebase (بدون تسجيل دخول).
import { getCloudConfig, pushCloudBackup } from './cloud.js';
import { prepareBackupPayload } from './drive.js';

let backupTimer = null;
let retryBackupTimer = null;
let lastBackupChangeTime = 0;

function nativeNotifications() {
  return globalThis.Capacitor?.Plugins?.LocalNotifications || null;
}

// التحقق من دعم المتصفح للإشعارات ونظام الدفع Push
export function isNotificationSupported() {
  return !!nativeNotifications() || (typeof window !== 'undefined' && 'Notification' in window);
}

export function isPushSupported() {
  return typeof window !== 'undefined' && 'serviceWorker' in navigator && 'PushManager' in window;
}

// قراءة حالة إذن الإشعارات
export function getNotificationPermission() {
  if (nativeNotifications()) return store.settings().systemNotificationsEnabled ? 'granted' : 'default';
  if (!isNotificationSupported()) return 'unsupported';
  return Notification.permission; // 'granted' | 'denied' | 'default'
}

// طلب إذن الإشعارات وتفعيل وضع الدفع
export async function requestNotificationPermission() {
  const native = nativeNotifications();
  if (native) {
    try {
      const result = await native.requestPermissions();
      const granted = result.display === 'granted' || result.display === 'provisional';
      await store.setSetting('systemNotificationsEnabled', granted);
      if (granted) {
        await sendSystemNotification('🔔 تم تفعيل الإشعارات', { body: 'ستصلك تنبيهات التطبيق على جهاز Android.' });
        toast('تم تفعيل إشعارات Android الأصلية بنجاح 🔔');
      } else toast('يرجى السماح بالإشعارات من إعدادات التطبيق', 'warn');
      return granted;
    } catch (err) {
      console.error('Native notification permission error:', err);
      toastErr('تعذر تفعيل إشعارات Android');
      return false;
    }
  }
  if (!isNotificationSupported()) {
    toastErr('المتصفح أو الجهاز الحالي لا يدعم إشعارات النظام');
    return false;
  }

  try {
    const perm = await Notification.requestPermission();
    if (perm === 'granted') {
      await store.setSetting('systemNotificationsEnabled', true);
      await registerBackgroundPeriodicSync();
      toast('تم تفعيل إشعارات النظام والدفع بنجاح 🔔');
      
      // إرسال إشعار ترحيبي وتأكيدي
      await sendSystemNotification('🔔 تم تفعيل تنبيهات الدفع بنجاح', {
        body: 'ستصلك تنبيهات النسخ الاحتياطي ومبيعات المخزون والأصناف النافذة والراكدة حتى في وضع السكون.',
        tag: 'welcome-notification',
      });
      return true;
    } else if (perm === 'denied') {
      await store.setSetting('systemNotificationsEnabled', false);
      toast('تم رفض إذن الإشعارات من إعدادات المتصفح', 'warn');
      return false;
    } else {
      return false;
    }
  } catch (err) {
    console.error('Error requesting notification permission:', err);
    return false;
  }
}

// تسجيل المزامنة الدورية في الخلفية عبر Service Worker أثناء سكون الهاتف
export async function registerBackgroundPeriodicSync() {
  if (nativeNotifications()) return true;
  if (typeof navigator === 'undefined' || !('serviceWorker' in navigator)) return false;

  try {
    const registration = await navigator.serviceWorker.ready;
    
    // محاولة تفعيل Periodic Background Sync إن كانت مدعومة بالمتصفح (Chrome/Android/PWA)
    if ('periodicSync' in registration) {
      const status = await navigator.permissions.query({ name: 'periodic-background-sync' }).catch(() => null);
      if (!status || status.state === 'granted') {
        await registration.periodicSync.register('audit-and-backup-check', {
          // فحص دوري كل 6 ساعات أثناء وضع السكون
          minInterval: 6 * 60 * 60 * 1000,
        });
        console.log('Periodic background sync registered successfully.');
      }
    }

    // تسجيل Background Sync للشبكة
    if ('sync' in registration) {
      await registration.sync.register('audit-and-backup-check').catch(() => {});
    }
    return true;
  } catch (e) {
    console.warn('Periodic sync registration not supported or skipped:', e);
    return false;
  }
}

/**
 * إرسال إشعار نظام حقيقي ودفع Push عبر Service Worker
 * يعمل عند سكون الشاشة، تصغير التطبيق، أو إغلاق التبويب
 */
export async function sendSystemNotification(title, options = {}) {
  const st = store.settings();

  const native = nativeNotifications();
  if (native) {
    try {
      await native.schedule({ notifications: [{
        id: Math.floor(Date.now() % 2147483647),
        title,
        body: options.body || '',
        extra: options.data || {},
      }] });
      return true;
    } catch (err) {
      console.warn('Native notification failed:', err);
      return false;
    }
  }
  
  // التحقق من صلاحية الإشعارات
  if (!isNotificationSupported() || Notification.permission !== 'granted') {
    if (options.body) toast(`${title}\n${options.body}`, 'info');
    return false;
  }

  // شعار المؤسسة كأيقونة للإشعار
  const iconUrl = st.logo || './icons/icon-192.png';

  const defaultOptions = {
    icon: iconUrl,
    badge: iconUrl,
    vibrate: [300, 150, 300, 150, 300],
    requireInteraction: false,
    silent: false,
    dir: 'rtl',
    lang: 'ar',
    ...options,
  };

  try {
    // 1. الأولوية: إرسال عبر Service Worker النشط لضمان الظهور في مركز إشعارات النظام وشاشة القفل
    if ('serviceWorker' in navigator) {
      const reg = await navigator.serviceWorker.ready;
      if (reg && typeof reg.showNotification === 'function') {
        await reg.showNotification(title, defaultOptions);
        return true;
      }
    }
  } catch (swErr) {
    console.warn('ServiceWorker showNotification failed, trying postMessage or fallback:', swErr);
  }

  try {
    // 2. إرسال أمر للـ Service Worker عبر postMessage
    if (navigator.serviceWorker && navigator.serviceWorker.controller) {
      navigator.serviceWorker.controller.postMessage({
        type: 'SHOW_NOTIFICATION',
        title,
        options: defaultOptions,
      });
      return true;
    }
  } catch (postErr) {
    console.warn('postMessage to SW failed:', postErr);
  }

  try {
    // 3. البديل المباشر
    const notif = new Notification(title, defaultOptions);
    notif.onclick = () => {
      window.focus();
      notif.close();
    };
    return true;
  } catch (err) {
    console.warn('Fallback Notification failed:', err);
    return false;
  }
}

/**
 * تجربة تنبيه وضع السكون (Sleep Mode Push Test)
 * يعطي المستخدم مؤقتاً تنازلياً (مثلاً 4 ثوانٍ) ليقفل شاشة الهاتف أو يصغر التطبيق لتجربة استقبال التنبيه أثناء السكون
 */
export async function testSleepModePushNotification(delaySeconds = 4) {
  if (getNotificationPermission() !== 'granted') {
    const ok = await requestNotificationPermission();
    if (!ok) {
      toast('يرجى السماح بإذن الإشعارات من إعدادات المتصفح أولاً', 'warn');
      return false;
    }
  }

  toast(`⏳ سيتم إرسال إشعار الدفع بعد ${delaySeconds} ثوانٍ. يمكنك قفل الشاشة أو تصغير التطبيق الآن لاختباره.`);

  return new Promise((resolve) => {
    setTimeout(async () => {
      const st = store.settings();
      const sent = await sendSystemNotification('🔔 تجربة تنبيه دفع في وضع السكون', {
        body: `نظام الإشعارات يعمل بكفاءة في وضع السكون (${st.businessName || 'المؤسسة'}). يتم إرسال تنبيهات المبيعات والنسخ بنجاح!`,
        tag: 'sleep-test-' + Date.now(),
        data: { url: '#/settings' },
        requireInteraction: true,
      });
      resolve(sent);
    }, delaySeconds * 1000);
  });
}

// حفظ نسخة احتياطية محلية مع حماية من امتلاء قاعدة البيانات (QuotaExceeded):
// نحذف أقدم النسخ تدريجياً ونعيد المحاولة، حتى لا يتعطّل حفظ البيانات الأساسية.
export async function safeCreateBackup(rec, keepFloor = 3) {
  let attempt = 0;
  while (true) {
    try {
      await store.create('backups', rec, { noActivity: true });
      return true;
    } catch (err) {
      const isQuota = err && (
        err.name === 'QuotaExceededError' ||
        err.code === 22 ||
        (err.message && /quota|storage|space|bytes/i.test(err.message))
      );
      if (!isQuota || attempt >= 4) {
        // ليست مشكلة سعة، أو استنفدنا المحاولات: لا نخزّن محلياً (السحابة لا تزال تحمي البيانات)
        console.warn('safeCreateBackup: تعذّر حفظ النسخة المحلية', err && err.message);
        return false;
      }
      // قلّص عدد النسخ المحفوظة ثم أعد المحاولة
      const keep = Math.max(keepFloor, 10 - attempt * 3);
      const removed = await store.pruneBackups(keep);
      attempt++;
      if (removed === 0 && attempt > 1) return false; // لا يوجد ما يُحذف
    }
  }
}

// جدولة النسخ الاحتياطي التلقائي بعد دقيقة واحدة من آخر تغيير (Debounced Backup Queue)
export function notifyDataChangeForBackup() {
  const st = store.settings();
  if (st.autoBackup === false && st.autoBackupNotification === false) return;

  lastBackupChangeTime = Date.now();
  if (backupTimer) clearTimeout(backupTimer);

  // مؤقت 60 ثانية (دقيقة واحدة بفارق زمني)
  const delayMs = 60 * 1000;
  backupTimer = setTimeout(async () => {
    await performAutoBackupWithNotification();
  }, delayMs);
}

// تنفيذ النسخ الاحتياطي التلقائي (محلي أو سحابي إلى Google Drive) مع إشعار الفشل وإعادة المحاولة بعد 15 دقيقة
export async function performAutoBackupWithNotification(manualTrigger = false) {
  try {
    const data = await exportAllData();
    const now = new Date();
    const timeStr = now.toTimeString().slice(0, 5);
    const dateStr = todayISO();
    const name = `نسخة تلقائية ${dateStr} ${timeStr}`;
    const rawJson = JSON.stringify(data);
    const sizeKb = (rawJson.length / 1024).toFixed(1);

    const rec = {
      id: uid('bk_auto'),
      name,
      date: now.toLocaleString('ar-EG-u-ca-gregory-nu-latn'),
      size: `${sizeKb} KB`,
      type: 'تلقائي',
      data,
      createdAt: now.toISOString(),
    };

    // حفظ النسخة محلياً بأمان (نقلّم النسخ القديمة عند امتلاء السعة حتى لا نفقد البيانات).
    await safeCreateBackup(rec);

    // تنظيف النسخ التلقائية القديمة جداً محلياً (الاحتفاظ بآخر 10 نسخ)
    await store.pruneBackups(10);

    // مزامنة سحابية صامتة في الخلفية (إن كانت مُعدّة ومفعّلة) — لا تُفشل العملية إن تعذّرت.
    let cloudNote = '';
    try {
      const cfg = getCloudConfig();
      if (cfg.ready && cfg.autoSync && cfg.code) {
        const payload = await prepareBackupPayload();
        const cr = await pushCloudBackup(payload);
        if (cr && cr.ok && !cr.skipped) cloudNote = ` وتمت المزامنة السحابية (${cr.sizeKb})`;
      }
    } catch (cloudErr) {
      console.warn('silent cloud sync skipped:', cloudErr && cloudErr.message);
    }

    // إلغاء أي مؤقت إعادة محاولة سابق عند النجاح
    if (retryBackupTimer) {
      clearTimeout(retryBackupTimer);
      retryBackupTimer = null;
    }

    // إشعار بالنجاح
    await sendSystemNotification('💾 تم حفظ نسخة احتياطية بنجاح', {
      body: `تم أرشفة وحفظ كل الحركات والعمليات الأخيرة بأمان (${sizeKb} KB)${cloudNote}.`,
      tag: 'auto-backup-success',
      data: { url: '#/backup' }
    });

    if (manualTrigger) {
      toast('تم إنشاء النسخة الاحتياطية بنجاح ✅');
    }
    return true;
  } catch (err) {
    console.error('Auto backup failed:', err);

    // جدولة إعادة المحاولة تلقائياً بعد 15 دقيقة
    if (retryBackupTimer) clearTimeout(retryBackupTimer);
    const retryDelayMs = 15 * 60 * 1000; // 15 دقيقة
    retryBackupTimer = setTimeout(async () => {
      console.log('Retrying auto-backup after 15 minutes failure...');
      await performAutoBackupWithNotification(false);
    }, retryDelayMs);

    // إرسال إشعار للمستخدم بالفشل والمحاولة بعد 15 دقيقة
    const reasonMsg = err && err.message ? `السبب: ${err.message}` : '';
    await sendSystemNotification('⚠️ فشل النسخ الاحتياطي التلقائي', {
      body: `تعذر إتمام النسخ الاحتياطي للعمليات الأخيرة. ${reasonMsg} — ستتم إعادة المحاولة تلقائياً بعد 15 دقيقة.`,
      tag: 'auto-backup-failure',
      data: { url: '#/backup' }
    });

    if (manualTrigger) {
      toastErr(`فشل النسخ الاحتياطي: ${err.message || 'خطأ غير معروف'}`);
    }
    return false;
  }
}

// فحص وإطلاق تنبيهات المبيعات والمخزون الذكية (الأصناف النافذة، الراكدة، وقرب النفاد)
export async function runInventoryAndSalesAudit(forceNotify = false) {
  const st = store.settings();
  if (st.stockNotificationsEnabled === false && !forceNotify) return;

  const items = store.list('items');
  if (!items || !items.length) return;

  const outOfStock = [];
  const lowStock = [];
  const stagnantItems = [];

  // فحص حركات البيع لتحديد ركود الأصناف (حسب الأيام المحددة بالإعدادات، افتراضياً 20 يوماً)
  const txItems = store.list('transactionItems');
  const now = Date.now();
  const stagnantDays = Number(st.stagnantDaysThreshold || 20);
  const stagnantMs = stagnantDays * 24 * 60 * 60 * 1000;

  // خريطة بآخر تاريخ بيع لكل صنف
  const lastSoldMap = {};
  txItems.forEach(line => {
    // البنود تربط بالعملية عبر الحقل txId (وليس transactionId)
    const tx = store.get('transactions', line.txId) || store.get('transactions', line.transactionId);
    if (tx && tx.date) {
      const txTime = new Date(tx.date).getTime();
      if (line.itemId && (!lastSoldMap[line.itemId] || txTime > lastSoldMap[line.itemId])) {
        lastSoldMap[line.itemId] = txTime;
      }
    }
  });

  items.forEach(item => {
    const q = Number(item.quantity || 0);
    // حد التنبيه المخزّن هو alertQty (مع دعم minQuantity القديم إن وُجد)
    const minQ = Number(item.alertQty ?? item.minQuantity ?? 5);

    if (q <= 0) {
      outOfStock.push(item);
    } else if (q <= minQ) {
      lowStock.push(item);
    }

    // فحص الأصناف الراكدة: إذا كانت الكمية متوفرة ولم يسجل أي بيع منذ المدة المحددة
    const lastSold = lastSoldMap[item.id];
    if (q > 0) {
      if (!lastSold) {
        // لم يسجل أي بيع من قبل
        stagnantItems.push(item);
      } else if (now - lastSold > stagnantMs) {
        stagnantItems.push(item);
      }
    }
  });

  // 1. تنبيه الأصناف النافذة
  if (outOfStock.length > 0) {
    const names = outOfStock.slice(0, 3).map(i => i.name).join('، ');
    const extra = outOfStock.length > 3 ? ` و ${outOfStock.length - 3} أصناف أخرى` : '';
    await sendSystemNotification(`❌ تنبيه نفاد مخزون (${outOfStock.length} صنف)`, {
      body: `نفد مخزون: ${names}${extra}. يرجى التوريد وتحديث الكميات فوراً.`,
      tag: 'out-of-stock-alert',
      data: { url: '#/inventory' }
    });
  }

  // 2. تنبيه انخفاض المخزون وقرب النفاد
  if (lowStock.length > 0) {
    const names = lowStock.slice(0, 3).map(i => `${i.name} (متبقي ${i.quantity})`).join('، ');
    await sendSystemNotification(`⚠️ تنبيه قرب نفاد المخزون (${lowStock.length} صنف)`, {
      body: `أصناف شارفت على النفاد: ${names}.`,
      tag: 'low-stock-alert',
      data: { url: '#/inventory' }
    });
  }

  // 3. تنبيه الأصناف الراكدة وبطيئة الحركة
  if (stagnantItems.length > 0 && (st.stagnantAlertsEnabled !== false || forceNotify)) {
    const names = stagnantItems.slice(0, 3).map(i => i.name).join('، ');
    const extra = stagnantItems.length > 3 ? ` و ${stagnantItems.length - 3} أصناف أخرى` : '';
    await sendSystemNotification(`⏳ تنبيه أصناف راكدة بالمخزن (${stagnantItems.length} صنف)`, {
      body: `أصناف لم تسجل أي حركة بيع منذ أكثر من ${stagnantDays} يوماً: ${names}${extra}. ينصح بعمل عروض ترويجية وتخفيضات.`,
      tag: 'stagnant-items-alert',
      data: { url: '#/inventory' }
    });
  }
}

// تهيئة نظام الإشعارات والمستمعات الدورية في الخلفية
export function initNotificationEngine() {
  // تسجيل المزامنة الدورية
  registerBackgroundPeriodicSync();

  // تشغيل فحص المخزون بعد تحميل التطبيق بـ 5 ثوانٍ
  setTimeout(() => {
    runInventoryAndSalesAudit();
  }, 5000);

  // تشغيل فحص دوري كل ساعة أثناء بقاء التطبيق
  setInterval(() => {
    runInventoryAndSalesAudit();
  }, 60 * 60 * 1000);

  // فحص عند استيقاظ الشاشة أو عودة المستخدم للتطبيق
  if (typeof document !== 'undefined') {
    document.addEventListener('visibilitychange', () => {
      if (document.visibilityState === 'visible') {
        const lastAudit = Number(sessionStorage.getItem('last_audit_time') || 0);
        if (Date.now() - lastAudit > 15 * 60 * 1000) { // كل 15 دقيقة عند الاستيقاظ
          sessionStorage.setItem('last_audit_time', Date.now());
          runInventoryAndSalesAudit();
        }
      }
    });
  }

  // إشعار عند استعادة اتصال الإنترنت
  if (typeof window !== 'undefined') {
    window.addEventListener('online', () => {
      console.log('Network connected, triggering sync audit...');
      runInventoryAndSalesAudit();
    });
  }
}
