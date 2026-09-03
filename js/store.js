// المخزن المركزي — يحمّل كل البيانات في الذاكرة للسرعة ويتزامن مع IndexedDB
import * as db from './db.js';
import { accountBalance, DEFAULT_CURRENCIES, opEffect } from './accounting.js';
import { uid, nowStamp } from './utils.js';
import { requestPersistentStorage } from './db.js';

const STORES = ['settings','currencies','categories','accounts','transactions','transactionItems','vouchers','items',
  'conversations','messages','users','activity','templates','reminders','notifications','contacts','trash'];

class Store {
  constructor() {
    this.state = {};
    this.listeners = new Set();
    this.ready = false;
  }

  onChange(fn) { this.listeners.add(fn); return () => this.listeners.delete(fn); }
  emit(payload) { this.listeners.forEach(fn => { try { fn(payload); } catch (e) { console.error(e); } }); }

  async load() {
    // طلب تخزين دائم لمنع المتصفح من مسح بيانات التطبيق عند ضغط المساحة
    await requestPersistentStorage();
    for (const s of STORES) {
      try { this.state[s] = await db.dbGetAll(s); } catch (e) { this.state[s] = []; }
    }
    this.ready = true;
    // إزالة الحسابات التي أنشأتها النسخ التجريبية السابقة فقط؛ الحسابات الجديدة لا تحمل sampleOps.
    await this.removeLegacyDemoAccounts();
    // سدّ الثغرات في أرقام العمليات فقط (لا نُعيد ترقيم القيم الصحيحة حتى لا تتغير أرقام السندات المطبوعة/المُرسلة)
    try {
      await this.fillMissingRefs();
    } catch (err) {
      console.warn('fillMissingRefs error:', err);
    }
    this.emit({ type: 'loaded' });
  }

  async removeLegacyDemoAccounts() {
    const demoAccounts = this.col('accounts').filter(a => a.sampleOps !== undefined || a.demo === true);
    for (const account of demoAccounts) {
      const related = this.col('transactions').filter(t => t.accountId === account.id || t.fromId === account.id || t.toId === account.id);
      for (const tx of related) {
        this.state.transactions = this.col('transactions').filter(item => item.id !== tx.id);
        await db.dbDelete('transactions', tx.id);
        const items = this.col('transactionItems').filter(item => item.txId === tx.id);
        for (const item of items) await db.dbDelete('transactionItems', item.id);
        this.state.transactionItems = this.col('transactionItems').filter(item => item.txId !== tx.id);
      }
      this.state.accounts = this.col('accounts').filter(item => item.id !== account.id);
      await db.dbDelete('accounts', account.id);
    }
  }

  col(name) { return this.state[name] || (this.state[name] = []); }
  get(name, id) { return (this.state[name] || []).find(x => x.id === id); }
  list(name, sorted = true) {
    const arr = this.col(name).slice();
    if (sorted) arr.sort((a, b) => (b.createdAt || '').localeCompare(a.createdAt || ''));
    return arr;
  }
  findBy(name, fn) { return (this.state[name] || []).find(fn); }
  filter(name, fn) { return (this.state[name] || []).filter(fn); }

  async save(name, obj, { silent = false, noActivity = false } = {}) {
    obj.updatedAt = nowStamp();
    if (!obj.createdAt) obj.createdAt = nowStamp();
    if (!obj.id) obj.id = uid(name);
    const arr = this.col(name);
    const i = arr.findIndex(x => x.id === obj.id);
    if (i >= 0) arr[i] = obj; else arr.push(obj);
    await db.dbPut(name, obj);
    if (!silent) this.emit({ type: 'save', store: name, item: obj });
    if (!noActivity) this.activity('تم تحديث ' + name, obj.id, obj.id);
    return obj;
  }

  async create(name, obj, opts = {}) {
    return this.save(name, obj, opts);
  }

  async remove(name, id, { silent = false } = {}) {
    this.state[name] = (this.state[name] || []).filter(x => x.id !== id);
    await db.dbDelete(name, id);
    if (!silent) this.emit({ type: 'remove', store: name, id });
    return true;
  }

  // ---------- الإعدادات ----------
  settings() {
    const all = {};
    this.col('settings').forEach(s => all[s.key] = s.value);
    return all;
  }
  async setSetting(key, value) {
    await this.save('settings', { id: key, key, value }, { noActivity: true, silent: true });
  }

  // ---------- العملات ----------
  getCurrencies() {
    const list = this.col('currencies');
    if (!list.length) return DEFAULT_CURRENCIES;
    return list;
  }
  currency(code) {
    return this.getCurrencies().find(c => c.code === code) || { code: code || '', name: code || '', symbol: code || '', decimal: 0 };
  }

  // ---------- الحسابات ----------
  accounts(active = true) {
    const all = this.col('accounts');
    return active ? all.filter(a => a.archived !== true) : all;
  }
  getAccount(id) { return this.get('accounts', id); }
  async saveAccount(acc) { return this.create('accounts', acc); }
  balance(accountId) {
    const a = this.getAccount(accountId);
    if (!a) return 0;
    return accountBalance(a, this.col('transactions'));
  }
  // كل الأرصدة دفعة واحدة (معتمدة على المعاملات النشطة فقط)
  allBalances(accountList) {
    const txs = this.col('transactions');
    const map = {};
    for (const a of accountList) map[a.id] = accountBalance(a, txs);
    return map;
  }

  // ---------- العمليات ----------
  transactions() { return this.list('transactions'); }
  transactionItems(txId) {
    return this.col('transactionItems')
      .filter(item => String(item.txId) === String(txId))
      .sort((a, b) => (a.position ?? 0) - (b.position ?? 0));
  }
  async replaceTransactionItems(txId, items = []) {
    const old = this.transactionItems(txId);
    for (const item of old) await db.dbDelete('transactionItems', item.id);
    this.state.transactionItems = this.col('transactionItems').filter(item => String(item.txId) !== String(txId));
    const saved = [];
    for (const [position, line] of items.entries()) {
      const item = {
        id: line.id || uid('txitem'),
        txId,
        position,
        itemId: line.itemId || null,
        name: String(line.name || ''),
        unit: String(line.unit || 'حبة'),
        quantity: Number(line.quantity) || 0,
        unitPrice: Number(line.unitPrice) || 0,
        total: Number.isFinite(Number(line.total)) ? Number(line.total) : (Number(line.quantity) || 0) * (Number(line.unitPrice) || 0),
        createdAt: line.createdAt || nowStamp(),
      };
      await db.dbPut('transactionItems', item);
      this.state.transactionItems.push(item);
      saved.push(item);
    }
    return saved;
  }
  // توليد الرقم التسلسلي المنتظم للعمليات (أرقام فقط بدون أحرف إنجليزية وعلامات)
  getNextSequentialRef() {
    const txs = this.col('transactions');
    let max = 0;
    for (const t of txs) {
      if (t.ref) {
        const clean = String(t.ref).replace(/\D/g, '');
        if (clean) {
          const num = parseInt(clean, 10);
          if (Number.isFinite(num) && num > max) max = num;
        }
      }
    }
    return String(max + 1);
  }

  // سدّ الثغرات فقط: منح رقم تسلسلي نقي للعمليات التي بلا رقم صالح،
  // دون تغيير أي رقم صحيح موجود (حفاظاً على تطابق السندات المطبوعة/المُرسلة).
  async fillMissingRefs() {
    const txs = this.col('transactions');
    if (!txs || !txs.length) return 0;
    const used = new Set();
    for (const t of txs) {
      const r = String(t.ref || '').trim();
      if (/^\d+$/.test(r)) used.add(r);
    }
    let changed = false;
    for (const t of txs) {
      const r = String(t.ref || '').trim();
      if (!r || !/^\d+$/.test(r)) {
        let next = this.getNextSequentialRef();
        while (used.has(next)) next = String(parseInt(next, 10) + 1);
        t.ref = next;
        used.add(next);
        await db.dbPut('transactions', t);
        changed = true;
      }
    }
    if (changed) this.emit({ type: 'save', store: 'transactions' });
    return changed;
  }

  // تقليم النسخ الاحتياطية المخزنة محلياً عند الحاجة (لمنع امتلاء قاعدة البيانات)
  async pruneBackups(keep = 15) {
    const all = this.col('backups').slice()
      .sort((a, b) => new Date(a.createdAt || 0) - new Date(b.createdAt || 0));
    const toRemove = all.slice(0, Math.max(0, all.length - keep));
    for (const b of toRemove) {
      await db.dbDelete('backups', b.id);
    }
    if (toRemove.length) {
      this.state.backups = this.col('backups').filter(b => !toRemove.includes(b));
    }
    return toRemove.length;
  }

  async saveTransaction(t) {
    // التأكد من أن رقم الفاتورة أو العملية تسلسلي منتظم بدون أحرف إنجليزية أو علامات
    if (!t.ref || !/^\d+$/.test(String(t.ref).trim())) {
      const digitsOnly = String(t.ref || '').replace(/\D/g, '');
      t.ref = digitsOnly || this.getNextSequentialRef();
    }
    const saved = await this.create('transactions', t);
    await this.replaceTransactionItems(saved.id, Array.isArray(saved.invoiceItems) ? saved.invoiceItems : []);
    return saved;
  }
  async deleteTransaction(id, { silent = false } = {}) {
    await this.remove('transactions', id, { silent });
    await this.replaceTransactionItems(id, []);
  }
  // كشف العمليات المكررة (لتحذير المستخدم دون منعه)
  findDuplicates(t) {
    return this.col('transactions').filter(x =>
      x.id !== t.id && x.accountId === t.accountId &&
      x.type === t.type && x.amount === t.amount &&
      x.currency === t.currency && x.date === t.date &&
      Math.abs(new Date(x.createdAt).getTime() - new Date(t.createdAt || Date.now()).getTime()) < 120000
    );
  }

  // ---------- الأرقام التسلسلية ----------
  nextSequence(kind) {
    const st = this.settings();
    const prefix = (st.voucherPrefix && st.voucherPrefix[kind]) || this.defaultPrefix(kind);
    let counter = st.counters && st.counters[kind] || 0;
    counter++;
    this.setSetting('counters', { ...st.counters, [kind]: counter });
    return prefix + String(counter).padStart(4, '0');
  }
  defaultPrefix(kind) {
    const map = { receipt: 'ق', payment: 'ص', debit: 'ق', credit: 'د', transfer: 'تح' };
    return map[kind] || 'س';
  }

  // ---------- النشاط ----------
  activity(text, refType, refId) {
    const users = this.col('users');
    const me = users.find(u => u.me) || { name: 'المدير' };
    this.create('activity', {
      text,
      refType,
      refId,
      user: me.name,
      userName: me.name,
    }, { noActivity: true });
  }
  recentActivity(limit = 30) { return this.list('activity').slice(0, limit); }

  // ---------- العدادات ----------
  counts() {
    return {
      accounts: this.accounts(true).length,
      transactions: this.col('transactions').length,
      vouchers: this.col('vouchers').length,
      conversations: this.col('conversations').length,
      trash: this.col('trash').length,
    };
  }
}

export const store = new Store();
export { accountBalance, opEffect };
