import express from 'express';
import cors from 'cors';
import path from 'path';
import { DatabaseSync } from 'node:sqlite';
import { v4 as uuidv4 } from 'uuid';
import QRCode from 'qrcode';
import { createServer as createViteServer } from 'vite';

const PORT = 3000;
const dbPath = path.join(process.cwd(), 'nexora.db');
const db = new DatabaseSync(dbPath);

function initDB() {
  db.exec(`
    PRAGMA foreign_keys = ON;
    
    CREATE TABLE IF NOT EXISTS accounts (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL,
      kind TEXT NOT NULL DEFAULT 'customer',
      opening_balance REAL NOT NULL DEFAULT 0,
      currency TEXT NOT NULL DEFAULT 'YER',
      phone TEXT DEFAULT '',
      whatsapp TEXT DEFAULT '',
      address TEXT DEFAULT '',
      notes TEXT DEFAULT '',
      category TEXT DEFAULT '',
      credit_limit REAL,
      archived INTEGER DEFAULT 0,
      deleted_at TEXT DEFAULT '',
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    );
    
    CREATE TABLE IF NOT EXISTS transactions (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      account_id INTEGER,
      type TEXT NOT NULL,
      amount REAL NOT NULL CHECK (amount > 0),
      currency TEXT NOT NULL DEFAULT 'YER',
      from_id INTEGER,
      to_id INTEGER,
      rate REAL NOT NULL DEFAULT 1,
      description TEXT DEFAULT '',
      reference TEXT DEFAULT '',
      notes TEXT DEFAULT '',
      date TEXT NOT NULL,
      deleted_at TEXT DEFAULT '',
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    );
    
    CREATE TABLE IF NOT EXISTS transaction_items (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      tx_id INTEGER NOT NULL,
      name TEXT NOT NULL,
      quantity REAL NOT NULL DEFAULT 1,
      unit_price REAL NOT NULL DEFAULT 0,
      total REAL NOT NULL DEFAULT 0
    );
    
    CREATE TABLE IF NOT EXISTS vouchers (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      number TEXT NOT NULL,
      kind TEXT NOT NULL,
      account_id INTEGER,
      amount REAL NOT NULL DEFAULT 0,
      currency TEXT NOT NULL DEFAULT 'YER',
      statement TEXT DEFAULT '',
      notes TEXT DEFAULT '',
      status TEXT NOT NULL DEFAULT 'draft',
      date TEXT NOT NULL,
      deleted_at TEXT DEFAULT '',
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    );
    
    CREATE TABLE IF NOT EXISTS currencies (
      code TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      symbol TEXT NOT NULL,
      rate REAL NOT NULL DEFAULT 1
    );
    
    CREATE TABLE IF NOT EXISTS items (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL,
      sku TEXT DEFAULT '',
      buy_price REAL DEFAULT 0,
      sell_price REAL DEFAULT 0,
      quantity REAL DEFAULT 0,
      min_quantity REAL DEFAULT 0,
      category TEXT DEFAULT '',
      deleted_at TEXT DEFAULT '',
      created_at TEXT NOT NULL
    );
    
    CREATE TABLE IF NOT EXISTS users (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL,
      role TEXT NOT NULL DEFAULT 'viewer',
      pin TEXT DEFAULT '',
      permissions TEXT DEFAULT '',
      is_me INTEGER DEFAULT 0,
      active INTEGER DEFAULT 1,
      created_at TEXT NOT NULL
    );
    
    CREATE TABLE IF NOT EXISTS devices (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      platform TEXT DEFAULT 'web',
      is_owner INTEGER DEFAULT 0,
      user_id INTEGER,
      user_role TEXT DEFAULT '',
      last_seen_at TEXT,
      last_sync_at TEXT,
      revoked_at TEXT DEFAULT '',
      expelled_at TEXT DEFAULT '',
      fingerprint TEXT DEFAULT ''
    );
    
    CREATE TABLE IF NOT EXISTS settings (
      key TEXT PRIMARY KEY,
      value TEXT NOT NULL
    );
    
    CREATE TABLE IF NOT EXISTS activity (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      text TEXT NOT NULL,
      ref_type TEXT DEFAULT '',
      ref_id TEXT DEFAULT '',
      user_name TEXT DEFAULT '',
      created_at TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS google_auth (
      id INTEGER PRIMARY KEY,
      email TEXT DEFAULT '',
      name TEXT DEFAULT '',
      picture TEXT DEFAULT '',
      id_token TEXT DEFAULT '',
      access_token TEXT DEFAULT '',
      created_at TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS invites (
      id TEXT PRIMARY KEY,
      token TEXT NOT NULL,
      pin TEXT NOT NULL,
      workspace_id TEXT DEFAULT 'default',
      created_by TEXT DEFAULT '',
      expires_at TEXT NOT NULL,
      used INTEGER DEFAULT 0,
      created_at TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS join_requests (
      id TEXT PRIMARY KEY,
      device_id TEXT NOT NULL,
      device_name TEXT NOT NULL,
      platform TEXT DEFAULT 'web',
      fingerprint TEXT DEFAULT '',
      token TEXT NOT NULL,
      status TEXT DEFAULT 'pending',
      requested_role TEXT DEFAULT 'viewer',
      created_at TEXT NOT NULL
    );
  `);
  
  const countRow = db.prepare('SELECT COUNT(*) as c FROM accounts').get() as { c: number };
  if (countRow && countRow.c === 0) {
    const now = new Date().toISOString();
    const insertAcc = db.prepare(`INSERT INTO accounts (name, kind, opening_balance, currency, phone, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)`);
    insertAcc.run('الصندوق الرئيسي', 'cash', 1540000, 'YER', '', now, now);
    insertAcc.run('أحمد محمد - محل الجملة', 'customer', 0, 'YER', '777123456', now, now);
    insertAcc.run('محمد علي - سوبر ماركت النور', 'customer', 0, 'YER', '712345678', now, now);
    insertAcc.run('شركة التوريد المتحدة', 'supplier', 0, 'YER', '01456789', now, now);
    insertAcc.run('صالح - مواد غذائية', 'customer', 50000, 'YER', '733987654', now, now);
    
    const insertCur = db.prepare(`INSERT INTO currencies (code, name, symbol, rate) VALUES (?, ?, ?, ?)`);
    insertCur.run('YER', 'ريال يمني', 'ر.ي', 1);
    insertCur.run('USD', 'دولار أمريكي', '$', 530);
    insertCur.run('SAR', 'ريال سعودي', 'ر.س', 140);
    
    const insertItem = db.prepare(`INSERT INTO items (name, sku, buy_price, sell_price, quantity, min_quantity, category, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)`);
    insertItem.run('عصير مانجو', 'MNG-001', 350, 500, 45, 10, 'مشروبات', now);
    insertItem.run('خبز بر', 'BRD-002', 120, 200, 120, 20, 'مخبوزات', now);
    insertItem.run('حليب 1 لتر', 'MLK-003', 600, 800, 30, 5, 'ألبان', now);
    insertItem.run('جبن مثلثات', 'CHS-004', 900, 1200, 18, 5, 'ألبان', now);
    insertItem.run('بن مطحون', 'COF-005', 2800, 3500, 12, 3, 'مشروبات', now);
    insertItem.run('شوكولاتة', 'CHC-006', 200, 300, 200, 30, 'حلويات', now);
    
    const insertUser = db.prepare(`INSERT INTO users (name, role, is_me, active, created_at) VALUES (?, ?, ?, ?, ?)`);
    insertUser.run('المدير', 'admin', 1, 1, now);
    insertUser.run('محاسب', 'accountant', 0, 1, now);
    insertUser.run('كاشير', 'dataentry', 0, 1, now);
    
    const deviceId = 'WEB-' + uuidv4().substring(0, 8).toUpperCase();
    const insertDev = db.prepare(`INSERT INTO devices (id, name, platform, is_owner, last_seen_at, last_sync_at, fingerprint) VALUES (?, ?, ?, ?, ?, ?, ?)`);
    insertDev.run(deviceId, 'المتصفح الحالي - المدير', 'web', 1, now, now, deviceId);
    insertDev.run('DEV-' + uuidv4().substring(0, 8).toUpperCase(), 'جهاز الكاشير - الفرع 1', 'android', 0, now, now, 'FP-AND-001');
    insertDev.run('DEV-' + uuidv4().substring(0, 8).toUpperCase(), 'جهاز المحاسب', 'windows', 0, new Date(Date.now() - 3600000).toISOString(), new Date(Date.now() - 3600000).toISOString(), 'FP-WIN-002');
    
    const insertSet = db.prepare(`INSERT INTO settings (key, value) VALUES (?, ?)`);
    insertSet.run('businessName', 'سجل المبيعات والديون - Nexora');
    insertSet.run('businessNameEn', 'Nexora Ledger');
    insertSet.run('address', 'صنعاء - اليمن');
    insertSet.run('phone', '777123456');
    insertSet.run('defaultCurrency', 'YER');
    insertSet.run('workspaceMode', 'enterprise');
    insertSet.run('cloudBackendUrl', 'https://nexora-ledger-default-rtdb.europe-west1.firebasedatabase.app');
    
    const insertTx = db.prepare(`INSERT INTO transactions (account_id, type, amount, currency, description, reference, date, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`);
    insertTx.run(2, 'debit', 50000, 'YER', 'فاتورة مبيعات', '1245', now, now, now);
    insertTx.run(3, 'debit', 30000, 'YER', 'فاتورة مبيعات', '1244', now, now, now);
  }
}

async function startServer() {
  initDB();
  const app = express();
  
  app.use(cors());
  app.use(express.json({ limit: '10mb' }));

  // Real-time SSE Sync Bus for instant manager-member syncing
  const sseClients = new Set<express.Response>();

  function broadcastSyncEvent(eventType: string, data: Record<string, any> = {}) {
    const payload = `event: sync\ndata: ${JSON.stringify({ type: eventType, timestamp: new Date().toISOString(), ...data })}\n\n`;
    for (const client of sseClients) {
      try {
        client.write(payload);
      } catch {
        sseClients.delete(client);
      }
    }
  }

  app.get('/api/sync/events', (req, res) => {
    res.writeHead(200, {
      'Content-Type': 'text/event-stream',
      'Cache-Control': 'no-cache',
      'Connection': 'keep-alive',
      'Access-Control-Allow-Origin': '*',
    });
    res.write(`event: connected\ndata: ${JSON.stringify({ status: 'connected', clientsCount: sseClients.size + 1 })}\n\n`);
    sseClients.add(res);

    req.on('close', () => {
      sseClients.delete(res);
    });
  });

  // QR Code generation
  app.get('/api/qr', async (req, res) => {
    try {
      const data = (req.query.data as string) || 'nexora';
      const qrDataUrl = await QRCode.toDataURL(data, { width: 300, margin: 2, color: { dark: '#000000', light: '#ffffff' } });
      if (req.query.format === 'image') {
        const base64 = qrDataUrl.split(',')[1];
        const img = Buffer.from(base64, 'base64');
        res.writeHead(200, { 'Content-Type': 'image/png', 'Content-Length': img.length });
        res.end(img);
      } else {
        res.json({ qr: qrDataUrl, data });
      }
    } catch (e: any) {
      res.status(500).json({ error: e.message });
    }
  });

  app.get('/api/qr/:token/image', async (req, res) => {
    try {
      const token = req.params.token;
      const invite = db.prepare(`SELECT * FROM invites WHERE token=?`).get(token) as any;
      const qrContent = invite ? JSON.stringify({ v: 1, ws: invite.workspace_id, token: invite.token, pin: invite.pin, url: 'https://nexora-ledger-default-rtdb.europe-west1.firebasedatabase.app' }) : token;
      const qrDataUrl = await QRCode.toDataURL(qrContent, { width: 400, margin: 1 });
      const base64 = qrDataUrl.split(',')[1];
      const img = Buffer.from(base64, 'base64');
      res.writeHead(200, { 'Content-Type': 'image/png', 'Content-Length': img.length, 'Cache-Control': 'no-cache' });
      res.end(img);
    } catch (e: any) {
      res.status(500).json({ error: e.message });
    }
  });

  // Google Auth endpoints
  app.get('/api/auth/google/status', (req, res) => {
    try {
      const row = db.prepare(`SELECT * FROM google_auth WHERE id=1`).get() as any;
      if (!row) return res.json({ loggedIn: false });
      res.json({ loggedIn: true, email: row.email, name: row.name, picture: row.picture });
    } catch (e) {
      res.json({ loggedIn: false });
    }
  });

  app.post('/api/auth/google/login', (req, res) => {
    try {
      const { email, name, picture, id_token, access_token } = req.body;
      const now = new Date().toISOString();
      if (!email) return res.status(400).json({ error: 'البريد الإلكتروني مطلوب' });
      
      db.prepare(`INSERT OR REPLACE INTO google_auth (id, email, name, picture, id_token, access_token, created_at) VALUES (1, ?, ?, ?, ?, ?, ?)`).run(email, name || email.split('@')[0], picture || '', id_token || '', access_token || '', now);
      db.prepare(`INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)`).run('owner_google_id', email);
      db.prepare(`INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)`).run('owner_google_name', name || email);
      db.prepare(`INSERT INTO activity (text, created_at) VALUES (?, ?)`).run(`تسجيل دخول Google: ${email}`, now);
      
      broadcastSyncEvent('auth_updated', { email, name });
      res.json({ ok: true, email, name });
    } catch (e: any) {
      res.status(500).json({ error: e.message });
    }
  });

  app.post('/api/auth/google/logout', (req, res) => {
    try {
      db.prepare(`DELETE FROM google_auth WHERE id=1`).run();
      broadcastSyncEvent('auth_updated', { email: '', name: '' });
      res.json({ ok: true });
    } catch (e: any) {
      res.status(500).json({ error: e.message });
    }
  });

  // Snapshot Sync Endpoint for Linked Member Devices (compatible with Flutter SnapshotApply / CloudJoin)
  app.get('/api/sync/snapshot', (req, res) => {
    try {
      const accounts = db.prepare(`SELECT a.*, COALESCE(SUM(CASE WHEN t.type='debit' THEN t.amount WHEN t.type='credit' THEN -t.amount WHEN t.type='inflow' THEN -t.amount WHEN t.type='outflow' THEN t.amount ELSE 0 END),0) + a.opening_balance as balance FROM accounts a LEFT JOIN transactions t ON t.account_id = a.id AND (t.deleted_at='' OR t.deleted_at IS NULL) WHERE (a.deleted_at='' OR a.deleted_at IS NULL) GROUP BY a.id`).all();
      const transactions = db.prepare(`SELECT * FROM transactions WHERE deleted_at='' OR deleted_at IS NULL ORDER BY date DESC`).all();
      const items = db.prepare(`SELECT * FROM items WHERE deleted_at='' OR deleted_at IS NULL ORDER BY name`).all();
      const vouchers = db.prepare(`SELECT * FROM vouchers WHERE deleted_at='' OR deleted_at IS NULL ORDER BY date DESC`).all();
      const devices = db.prepare(`SELECT * FROM devices ORDER BY is_owner DESC`).all();
      const settingsRows = db.prepare(`SELECT * FROM settings`).all() as any[];
      const settingsMap: Record<string, string> = {};
      for (const r of settingsRows) settingsMap[r.key] = r.value;

      res.json({
        ok: true,
        timestamp: new Date().toISOString(),
        snapshot: {
          accounts,
          transactions,
          items,
          vouchers,
          devices,
          settings: settingsMap,
        },
      });
    } catch (e: any) {
      res.status(500).json({ error: e.message });
    }
  });

  // Invites & Join Requests
  app.post('/api/invite', (req, res) => {
    try {
      const now = new Date().toISOString();
      const expiresAt = new Date(Date.now() + 15 * 60 * 1000).toISOString();
      let token = '', pin = '', id = '';
      for (let attempt = 0; attempt < 10; attempt++) {
        token = uuidv4().substring(0, 8).toUpperCase();
        pin = Math.floor(100000 + Math.random() * 900000).toString();
        const existing = db.prepare(`SELECT id FROM invites WHERE (token=? OR pin=?) AND used=0 AND expires_at > ?`).get(token, pin, now);
        if (!existing) break;
        if (attempt === 9) return res.status(500).json({ error: 'تعذر توليد رمز فريد بعد 10 محاولات' });
      }
      id = uuidv4();
      
      db.prepare(`INSERT INTO invites (id, token, pin, workspace_id, created_by, expires_at, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)`).run(id, token, pin, 'default', 'owner', expiresAt, now);
      
      const qrContent = JSON.stringify({
        v: 1,
        ws: 'default',
        token,
        pin,
        url: 'https://nexora-ledger-default-rtdb.europe-west1.firebasedatabase.app',
        name: 'متجري',
        exp: Date.now() + 15 * 60 * 1000
      });
      
      res.json({
        id,
        token,
        pin: `${pin.substring(0, 3)} ${pin.substring(3)}`,
        pinRaw: pin,
        qrContent,
        expiresAt,
        backendUrl: 'https://nexora-ledger-default-rtdb.europe-west1.firebasedatabase.app',
        workspaceName: 'سجل المبيعات والديون - Nexora'
      });
    } catch (e: any) {
      res.status(500).json({ error: e.message });
    }
  });

  app.get('/api/invites', (req, res) => {
    try {
      const rows = db.prepare(`SELECT * FROM invites WHERE used=0 AND expires_at > ? ORDER BY created_at DESC`).all(new Date().toISOString());
      res.json(rows);
    } catch (e: any) {
      res.status(500).json({ error: e.message });
    }
  });

  app.post('/api/join-request', (req, res) => {
    try {
      const { deviceName, platform, fingerprint, token, pin } = req.body;
      const now = new Date().toISOString();
      const cleanPin = pin ? String(pin).replace(/\s/g, '') : '';
      const invite = db.prepare(`SELECT * FROM invites WHERE (token=? OR pin=? OR pin=?) AND used=0 AND expires_at > ?`).get(token || '', token || '', cleanPin, now) as any;
      if (!invite) {
        return res.status(400).json({ error: '❌ فشل الربط: رمز الدعوة غير صحيح أو منتهي أو استُخدم من قبل. مدة الصلاحية 15 دقيقة.' });
      }
      
      const id = uuidv4();
      const deviceId = 'DEV-' + uuidv4().substring(0, 8).toUpperCase();
      db.prepare(`INSERT INTO join_requests (id, device_id, device_name, platform, fingerprint, token, status, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)`).run(id, deviceId, deviceName || 'جهاز جديد', platform || 'web', fingerprint || deviceId, token || invite.token, 'pending', now);
      
      broadcastSyncEvent('join_requested', {
        requestId: id,
        deviceId,
        deviceName: deviceName || 'جهاز جديد',
        platform: platform || 'web',
      });

      res.json({ ok: true, requestId: id, deviceId, message: 'تم إرسال طلب الانضمام إلى المدير، بانتظار الموافقة' });
    } catch (e: any) {
      res.status(500).json({ error: e.message });
    }
  });

  app.get('/api/join-requests', (req, res) => {
    try {
      const rows = db.prepare(`SELECT * FROM join_requests WHERE status='pending' ORDER BY created_at DESC`).all();
      res.json(rows);
    } catch (e: any) {
      res.status(500).json({ error: e.message });
    }
  });

  app.post('/api/join-requests/:id/approve', (req, res) => {
    try {
      const { role } = req.body;
      const reqRow = db.prepare(`SELECT * FROM join_requests WHERE id=?`).get(req.params.id) as any;
      if (!reqRow) return res.status(404).json({ error: 'الطلب غير موجود' });
      
      const now = new Date().toISOString();
      let effectiveName = (reqRow.device_name || 'جهاز جديد').trim();
      
      db.prepare(`INSERT OR REPLACE INTO devices (id, name, platform, is_owner, user_role, last_seen_at, last_sync_at, fingerprint) VALUES (?, ?, ?, ?, ?, ?, ?, ?)`).run(reqRow.device_id, effectiveName, reqRow.platform, 0, role || 'viewer', now, now, reqRow.fingerprint);
      db.prepare(`UPDATE join_requests SET status='approved' WHERE id=?`).run(req.params.id);
      db.prepare(`UPDATE invites SET used=1 WHERE token=?`).run(reqRow.token);
      db.prepare(`INSERT INTO activity (text, created_at) VALUES (?, ?)`).run(`✅ تم قبول جهاز: ${effectiveName} بدور ${role || 'viewer'}`, now);
      
      broadcastSyncEvent('join_approved', {
        requestId: req.params.id,
        deviceId: reqRow.device_id,
        deviceName: effectiveName,
        role: role || 'viewer',
      });

      res.json({ ok: true, deviceId: reqRow.device_id, message: '✅ تم الارتباط بنجاح', deviceName: effectiveName });
    } catch (e: any) {
      res.status(500).json({ error: e.message });
    }
  });

  app.post('/api/join-requests/:id/reject', (req, res) => {
    try {
      db.prepare(`UPDATE join_requests SET status='rejected' WHERE id=?`).run(req.params.id);
      broadcastSyncEvent('join_rejected', { requestId: req.params.id });
      res.json({ ok: true });
    } catch (e: any) {
      res.status(500).json({ error: e.message });
    }
  });

  // Dashboard endpoint
  app.get('/api/dashboard', (req, res) => {
    try {
      const totalSales = db.prepare(`SELECT COALESCE(SUM(amount),0) as total FROM transactions WHERE type IN ('debit','inflow','revenue') AND deleted_at=''`).get() as any;
      const totalDebts = db.prepare(`SELECT COALESCE(SUM(amount),0) as total FROM transactions WHERE type='debit' AND deleted_at=''`).get() as any;
      const totalCredits = db.prepare(`SELECT COALESCE(SUM(amount),0) as total FROM transactions WHERE type='credit' AND deleted_at=''`).get() as any;
      const accountsCount = db.prepare(`SELECT COUNT(*) as c FROM accounts WHERE deleted_at=''`).get() as any;
      const lowStock = db.prepare(`SELECT COUNT(*) as c FROM items WHERE quantity <= min_quantity AND deleted_at=''`).get() as any;
      const pendingJoins = db.prepare(`SELECT COUNT(*) as c FROM join_requests WHERE status='pending'`).get() as any;
      
      const topDebtors = db.prepare(`
        SELECT a.id, a.name, a.phone, 
               COALESCE(SUM(CASE WHEN t.type='debit' THEN t.amount WHEN t.type='credit' THEN -t.amount ELSE 0 END),0) + a.opening_balance as balance
        FROM accounts a
        LEFT JOIN transactions t ON t.account_id = a.id AND t.deleted_at=''
        WHERE a.deleted_at='' AND a.kind='customer'
        GROUP BY a.id HAVING balance > 0 ORDER BY balance DESC LIMIT 5
      `).all();
      
      const recentTx = db.prepare(`SELECT t.*, a.name as account_name FROM transactions t LEFT JOIN accounts a ON a.id = t.account_id WHERE t.deleted_at='' ORDER BY t.created_at DESC LIMIT 10`).all();
      
      res.json({
        totalSales: totalSales?.total || 0,
        totalDebts: totalDebts?.total || 0,
        totalCredits: totalCredits?.total || 0,
        accountsCount: accountsCount?.c || 0,
        lowStock: lowStock?.c || 0,
        pendingJoins: pendingJoins?.c || 0,
        topDebtors,
        recentTx
      });
    } catch (e: any) {
      res.status(500).json({ error: e.message });
    }
  });

  // Accounts
  app.get('/api/accounts', (req, res) => {
    try {
      const { kind, search } = req.query;
      let sql = `SELECT a.*, COALESCE(SUM(CASE WHEN t.type='debit' THEN t.amount WHEN t.type='credit' THEN -t.amount WHEN t.type='inflow' THEN -t.amount WHEN t.type='outflow' THEN t.amount ELSE 0 END),0) + a.opening_balance as balance, (SELECT MAX(date) FROM transactions WHERE account_id=a.id AND (deleted_at='' OR deleted_at IS NULL)) as last_tx FROM accounts a LEFT JOIN transactions t ON t.account_id = a.id AND (t.deleted_at='' OR t.deleted_at IS NULL) WHERE (a.deleted_at='' OR a.deleted_at IS NULL)`;
      const params: any[] = [];
      if (kind) { sql += ' AND a.kind=?'; params.push(kind); }
      if (search) { sql += ' AND a.name LIKE ?'; params.push(`%${search}%`); }
      sql += ' GROUP BY a.id ORDER BY a.created_at DESC';
      const rows = db.prepare(sql).all(...params);
      res.json(rows);
    } catch (e: any) {
      res.status(500).json({ error: e.message });
    }
  });

  app.post('/api/accounts', (req, res) => {
    try {
      const { name, kind, opening_balance, currency, phone, whatsapp, address, notes, category } = req.body;
      const now = new Date().toISOString();
      const result = db.prepare(`INSERT INTO accounts (name, kind, opening_balance, currency, phone, whatsapp, address, notes, category, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`).run(name, kind || 'customer', opening_balance || 0, currency || 'YER', phone || '', whatsapp || '', address || '', notes || '', category || '', now, now);
      db.prepare(`INSERT INTO activity (text, ref_type, ref_id, created_at) VALUES (?, ?, ?, ?)`).run(`إضافة حساب: ${name}`, 'account', String(result.lastInsertRowid), now);
      
      broadcastSyncEvent('account_created', {
        id: result.lastInsertRowid,
        name,
        kind: kind || 'customer',
        opening_balance: opening_balance || 0,
        currency: currency || 'YER',
      });

      res.json({ id: result.lastInsertRowid });
    } catch (e: any) {
      res.status(500).json({ error: e.message });
    }
  });

  app.put('/api/accounts/:id', (req, res) => {
    try {
      const { name, kind, opening_balance, currency, phone, whatsapp, address, notes, category } = req.body;
      const now = new Date().toISOString();
      db.prepare(`UPDATE accounts SET name=?, kind=?, opening_balance=?, currency=?, phone=?, whatsapp=?, address=?, notes=?, category=?, updated_at=? WHERE id=?`).run(name, kind, opening_balance, currency, phone, whatsapp || '', address, notes, category, now, req.params.id);
      
      broadcastSyncEvent('account_updated', {
        id: Number(req.params.id),
        name,
        kind,
        opening_balance,
      });

      res.json({ ok: true });
    } catch (e: any) {
      res.status(500).json({ error: e.message });
    }
  });

  app.delete('/api/accounts/:id', (req, res) => {
    try {
      db.prepare(`UPDATE accounts SET deleted_at=? WHERE id=?`).run(new Date().toISOString(), req.params.id);
      broadcastSyncEvent('account_deleted', {
        id: Number(req.params.id),
      });
      res.json({ ok: true });
    } catch (e: any) {
      res.status(500).json({ error: e.message });
    }
  });

  // Transactions
  app.get('/api/transactions', (req, res) => {
    try {
      const { type, account_id } = req.query;
      let sql = `SELECT t.*, a.name as account_name FROM transactions t LEFT JOIN accounts a ON a.id=t.account_id WHERE (t.deleted_at='' OR t.deleted_at IS NULL)`;
      const params: any[] = [];
      if (type) { sql += ' AND t.type=?'; params.push(type); }
      if (account_id) { sql += ' AND t.account_id=?'; params.push(account_id); }
      sql += ' ORDER BY t.date DESC, t.id DESC';
      res.json(db.prepare(sql).all(...params));
    } catch (e: any) {
      res.status(500).json({ error: e.message });
    }
  });

  app.post('/api/transactions', (req, res) => {
    try {
      const { account_id, type, amount, currency, from_id, to_id, description, reference, notes, date, items } = req.body;
      if (!amount || Number(amount) <= 0) return res.status(400).json({ error: 'المبلغ يجب أن يكون أكبر من صفر' });
      const now = new Date().toISOString();
      const result = db.prepare(`INSERT INTO transactions (account_id, type, amount, currency, from_id, to_id, description, reference, notes, date, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`).run(account_id || null, type, amount, currency || 'YER', from_id || null, to_id || null, description || '', reference || '', notes || '', date || now, now, now);
      
      if (items && Array.isArray(items) && items.length > 0) {
        const stmt = db.prepare(`INSERT INTO transaction_items (tx_id, name, quantity, unit_price, total) VALUES (?, ?, ?, ?, ?)`);
        for (const it of items) {
          stmt.run(result.lastInsertRowid, it.name, it.quantity || 1, it.unit_price || 0, it.total || 0);
        }
        if (type === 'debit') {
          const upd = db.prepare(`UPDATE items SET quantity = quantity - ? WHERE name=?`);
          for (const it of items) {
            upd.run(it.quantity || 1, it.name);
          }
        }
      }
      db.prepare(`INSERT INTO activity (text, ref_type, ref_id, created_at) VALUES (?, ?, ?, ?)`).run(`عملية ${type}: ${amount}`, 'transaction', String(result.lastInsertRowid), now);
      
      broadcastSyncEvent('transaction_created', {
        id: result.lastInsertRowid,
        type,
        amount,
        account_id: account_id || null,
        description: description || '',
      });

      if (account_id) {
        broadcastSyncEvent('account_balance_updated', {
          account_id: Number(account_id),
          amount,
          type,
        });
      }

      res.json({ id: result.lastInsertRowid });
    } catch (e: any) {
      res.status(500).json({ error: e.message });
    }
  });

  app.delete('/api/transactions/:id', (req, res) => {
    try {
      const tx = db.prepare(`SELECT * FROM transactions WHERE id=?`).get(req.params.id) as any;
      db.prepare(`UPDATE transactions SET deleted_at=? WHERE id=?`).run(new Date().toISOString(), req.params.id);
      broadcastSyncEvent('transaction_deleted', { id: req.params.id, account_id: tx?.account_id });
      if (tx?.account_id) {
        broadcastSyncEvent('account_balance_updated', { account_id: Number(tx.account_id) });
      }
      res.json({ ok: true });
    } catch (e: any) {
      res.status(500).json({ error: e.message });
    }
  });

  // Items / Inventory
  app.get('/api/items', (req, res) => {
    try {
      res.json(db.prepare(`SELECT * FROM items WHERE deleted_at='' ORDER BY name`).all());
    } catch (e: any) {
      res.status(500).json({ error: e.message });
    }
  });

  app.post('/api/items', (req, res) => {
    try {
      const { name, sku, buy_price, sell_price, quantity, min_quantity, category } = req.body;
      const now = new Date().toISOString();
      const result = db.prepare(`INSERT INTO items (name, sku, buy_price, sell_price, quantity, min_quantity, category, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)`).run(name, sku || '', buy_price || 0, sell_price || 0, quantity || 0, min_quantity || 0, category || '', now);
      res.json({ id: result.lastInsertRowid });
    } catch (e: any) {
      res.status(500).json({ error: e.message });
    }
  });

  app.put('/api/items/:id', (req, res) => {
    try {
      const { name, sku, buy_price, sell_price, quantity, min_quantity, category } = req.body;
      db.prepare(`UPDATE items SET name=?, sku=?, buy_price=?, sell_price=?, quantity=?, min_quantity=?, category=? WHERE id=?`).run(name, sku, buy_price, sell_price, quantity, min_quantity, category, req.params.id);
      res.json({ ok: true });
    } catch (e: any) {
      res.status(500).json({ error: e.message });
    }
  });

  app.delete('/api/items/:id', (req, res) => {
    try {
      db.prepare(`UPDATE items SET deleted_at=? WHERE id=?`).run(new Date().toISOString(), req.params.id);
      res.json({ ok: true });
    } catch (e: any) {
      res.status(500).json({ error: e.message });
    }
  });

  // Users
  app.get('/api/users', (req, res) => {
    try {
      res.json(db.prepare(`SELECT * FROM users ORDER BY id`).all());
    } catch (e: any) {
      res.status(500).json({ error: e.message });
    }
  });

  app.post('/api/users', (req, res) => {
    try {
      const { name, role, pin, permissions } = req.body;
      const now = new Date().toISOString();
      const result = db.prepare(`INSERT INTO users (name, role, pin, permissions, active, created_at) VALUES (?, ?, ?, ?, 1, ?)`).run(name, role || 'viewer', pin || '', JSON.stringify(permissions || {}), now);
      res.json({ id: result.lastInsertRowid });
    } catch (e: any) {
      res.status(500).json({ error: e.message });
    }
  });

  app.put('/api/users/:id', (req, res) => {
    try {
      const { name, role, pin, permissions, active } = req.body;
      db.prepare(`UPDATE users SET name=?, role=?, pin=?, permissions=?, active=? WHERE id=?`).run(name, role, pin, JSON.stringify(permissions || {}), active ? 1 : 0, req.params.id);
      res.json({ ok: true });
    } catch (e: any) {
      res.status(500).json({ error: e.message });
    }
  });

  app.delete('/api/users/:id', (req, res) => {
    try {
      const user = db.prepare(`SELECT * FROM users WHERE id=?`).get(req.params.id) as any;
      if (user && user.is_me) return res.status(400).json({ error: 'لا يمكن حذف المستخدم الحالي' });
      db.prepare(`DELETE FROM users WHERE id=?`).run(req.params.id);
      res.json({ ok: true });
    } catch (e: any) {
      res.status(500).json({ error: e.message });
    }
  });

  // Devices
  app.get('/api/devices', (req, res) => {
    try {
      res.json(db.prepare(`SELECT d.*, u.name as user_name, u.role as user_role FROM devices d LEFT JOIN users u ON u.id = d.user_id ORDER BY d.is_owner DESC, d.last_seen_at DESC`).all());
    } catch (e: any) {
      res.status(500).json({ error: e.message });
    }
  });

  app.post('/api/devices', (req, res) => {
    try {
      const { name, platform, user_id, user_role } = req.body;
      const id = 'DEV-' + uuidv4().substring(0, 8).toUpperCase();
      const now = new Date().toISOString();
      db.prepare(`INSERT INTO devices (id, name, platform, user_id, user_role, last_seen_at, last_sync_at, fingerprint) VALUES (?, ?, ?, ?, ?, ?, ?, ?)`).run(id, name || 'جهاز جديد', platform || 'web', user_id || null, user_role || 'viewer', now, now, id);
      res.json({ id });
    } catch (e: any) {
      res.status(500).json({ error: e.message });
    }
  });

  app.put('/api/devices/:id', (req, res) => {
    try {
      const { name, user_id, user_role, revoked_at, expelled_at } = req.body;
      const now = new Date().toISOString();
      let sql = `UPDATE devices SET last_seen_at=?`;
      const params: any[] = [now];
      if (name !== undefined) { sql += `, name=?`; params.push(name); }
      if (user_id !== undefined) { sql += `, user_id=?`; params.push(user_id); }
      if (user_role !== undefined) { sql += `, user_role=?`; params.push(user_role); }
      if (revoked_at !== undefined) { sql += `, revoked_at=?`; params.push(revoked_at); }
      if (expelled_at !== undefined) { sql += `, expelled_at=?`; params.push(expelled_at); }
      sql += ` WHERE id=?`; params.push(req.params.id);
      db.prepare(sql).run(...params);
      res.json({ ok: true });
    } catch (e: any) {
      res.status(500).json({ error: e.message });
    }
  });

  app.delete('/api/devices/:id', (req, res) => {
    try {
      const dev = db.prepare(`SELECT is_owner FROM devices WHERE id=?`).get(req.params.id) as any;
      if (dev && dev.is_owner) return res.status(400).json({ error: 'لا يمكن حذف جهاز المالك' });
      db.prepare(`DELETE FROM devices WHERE id=?`).run(req.params.id);
      res.json({ ok: true });
    } catch (e: any) {
      res.status(500).json({ error: e.message });
    }
  });

  app.post('/api/devices/:id/transfer-ownership', (req, res) => {
    try {
      const targetId = req.params.id;
      const now = new Date().toISOString();
      db.prepare(`UPDATE devices SET is_owner=0`).run();
      db.prepare(`UPDATE devices SET is_owner=1, last_seen_at=? WHERE id=?`).run(now, targetId);
      db.prepare(`INSERT INTO activity (text, created_at) VALUES (?,?)`).run(`تم نقل الملكية إلى ${targetId}`, now);
      res.json({ ok: true });
    } catch (e: any) {
      res.status(500).json({ error: e.message });
    }
  });

  // Settings
  app.get('/api/settings', (req, res) => {
    try {
      const rows = db.prepare(`SELECT * FROM settings`).all() as any[];
      const obj: Record<string, string> = {};
      rows.forEach(r => obj[r.key] = r.value);
      res.json(obj);
    } catch (e: any) {
      res.status(500).json({ error: e.message });
    }
  });

  app.post('/api/settings', (req, res) => {
    try {
      const stmt = db.prepare(`INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)`);
      for (const [k, v] of Object.entries(req.body)) {
        stmt.run(k, String(v));
      }
      res.json({ ok: true });
    } catch (e: any) {
      res.status(500).json({ error: e.message });
    }
  });

  // Vouchers
  app.get('/api/vouchers', (req, res) => {
    try {
      res.json(db.prepare(`SELECT v.*, a.name as account_name FROM vouchers v LEFT JOIN accounts a ON a.id=v.account_id WHERE (v.deleted_at='' OR v.deleted_at IS NULL) ORDER BY v.date DESC`).all());
    } catch (e: any) {
      res.status(500).json({ error: e.message });
    }
  });

  app.post('/api/vouchers', (req, res) => {
    try {
      const { number, kind, account_id, amount, currency, statement, notes, status, date } = req.body;
      const now = new Date().toISOString();
      const num = number || `V-${Date.now()}`;
      const result = db.prepare(`INSERT INTO vouchers (number, kind, account_id, amount, currency, statement, notes, status, date, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`).run(num, kind, account_id || null, amount || 0, currency || 'YER', statement || '', notes || '', status || 'posted', date || now, now, now);
      
      // If linked to an account, record corresponding transaction to update account balance
      if (account_id && Number(amount) > 0) {
        const txType = kind === 'receipt' ? 'credit' : 'debit';
        const desc = statement || (kind === 'receipt' ? `سند قبض رقم ${num}` : `سند صرف رقم ${num}`);
        db.prepare(`INSERT INTO transactions (account_id, type, amount, currency, description, reference, notes, date, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`).run(account_id, txType, amount, currency || 'YER', desc, num, notes || '', date || now, now, now);
        
        broadcastSyncEvent('account_balance_updated', {
          account_id: Number(account_id),
          amount,
          type: txType,
        });
      }

      broadcastSyncEvent('voucher_created', {
        id: result.lastInsertRowid,
        kind,
        account_id: account_id || null,
        amount: Number(amount) || 0,
        number: num,
      });

      res.json({ id: result.lastInsertRowid });
    } catch (e: any) {
      res.status(500).json({ error: e.message });
    }
  });

  app.delete('/api/vouchers/:id', (req, res) => {
    try {
      const v = db.prepare(`SELECT * FROM vouchers WHERE id=?`).get(req.params.id) as any;
      db.prepare(`UPDATE vouchers SET deleted_at=? WHERE id=?`).run(new Date().toISOString(), req.params.id);
      broadcastSyncEvent('voucher_deleted', { id: req.params.id, account_id: v?.account_id });
      if (v?.account_id) {
        broadcastSyncEvent('account_balance_updated', { account_id: Number(v.account_id) });
      }
      res.json({ ok: true });
    } catch (e: any) {
      res.status(500).json({ error: e.message });
    }
  });

  // Batch Push Synchronization (Push offline operations or queued account updates)
  app.post('/api/sync/push', (req, res) => {
    try {
      const { operations } = req.body;
      if (!Array.isArray(operations)) return res.status(400).json({ error: 'قائمة العمليات مطلوبة' });
      const now = new Date().toISOString();
      const results: any[] = [];
      for (const op of operations) {
        if (op.entityType === 'account' && (op.type === 'create' || op.type === 'upsert')) {
          const { name, kind, opening_balance, currency, phone, whatsapp, address, notes, category } = op.payload || {};
          const r = db.prepare(`INSERT INTO accounts (name, kind, opening_balance, currency, phone, whatsapp, address, notes, category, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`).run(name, kind || 'customer', opening_balance || 0, currency || 'YER', phone || '', whatsapp || '', address || '', notes || '', category || '', now, now);
          results.push({ opId: op.id, entityId: r.lastInsertRowid });
        } else if (op.entityType === 'transaction' && op.type === 'create') {
          const { account_id, type, amount, currency, description, reference, notes, date } = op.payload || {};
          const r = db.prepare(`INSERT INTO transactions (account_id, type, amount, currency, description, reference, notes, date, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`).run(account_id || null, type, amount, currency || 'YER', description || '', reference || '', notes || '', date || now, now, now);
          results.push({ opId: op.id, entityId: r.lastInsertRowid });
        }
      }
      broadcastSyncEvent('batch_sync_applied', { count: results.length });
      res.json({ ok: true, results });
    } catch (e: any) {
      res.status(500).json({ error: e.message });
    }
  });

  // Activity
  app.get('/api/activity', (req, res) => {
    try {
      res.json(db.prepare(`SELECT * FROM activity ORDER BY created_at DESC LIMIT 50`).all());
    } catch (e: any) {
      res.status(500).json({ error: e.message });
    }
  });

  // Backup Export
  app.get('/api/backup/export', (req, res) => {
    try {
      const tables = ['accounts', 'transactions', 'transaction_items', 'vouchers', 'currencies', 'items', 'users', 'devices', 'settings', 'google_auth', 'invites', 'join_requests'];
      const data: Record<string, any> = {};
      for (const t of tables) {
        try {
          data[t] = db.prepare(`SELECT * FROM ${t}`).all();
        } catch {
          data[t] = [];
        }
      }
      data.exportedAt = new Date().toISOString();
      data.version = '3.65.0';
      res.json(data);
    } catch (e: any) {
      res.status(500).json({ error: e.message });
    }
  });

  // Backup Import & Restore
  app.post('/api/backup/restore', (req, res) => {
    try {
      const backup = req.body;
      if (!backup || typeof backup !== 'object') {
        return res.status(400).json({ error: 'ملف النسخة الاحتياطية غير صالح' });
      }

      db.exec('BEGIN TRANSACTION');
      try {
        // Restore accounts
        if (Array.isArray(backup.accounts) && backup.accounts.length > 0) {
          db.prepare(`DELETE FROM accounts`).run();
          const stmt = db.prepare(`INSERT INTO accounts (id, name, kind, opening_balance, currency, phone, whatsapp, address, notes, category, deleted_at, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`);
          for (const a of backup.accounts) {
            stmt.run(a.id, a.name, a.kind || 'customer', a.opening_balance || 0, a.currency || 'YER', a.phone || '', a.whatsapp || '', a.address || '', a.notes || '', a.category || '', a.deleted_at || '', a.created_at || '', a.updated_at || '');
          }
        }

        // Restore items
        if (Array.isArray(backup.items) && backup.items.length > 0) {
          db.prepare(`DELETE FROM items`).run();
          const stmt = db.prepare(`INSERT INTO items (id, name, sku, category, buy_price, sell_price, quantity, min_quantity, unit, image_url, deleted_at, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`);
          for (const it of backup.items) {
            stmt.run(it.id, it.name, it.sku || '', it.category || '', it.buy_price || 0, it.sell_price || 0, it.quantity || 0, it.min_quantity || 0, it.unit || '', it.image_url || '', it.deleted_at || '', it.created_at || '', it.updated_at || '');
          }
        }

        // Restore transactions
        if (Array.isArray(backup.transactions) && backup.transactions.length > 0) {
          db.prepare(`DELETE FROM transactions`).run();
          const stmt = db.prepare(`INSERT INTO transactions (id, account_id, type, amount, currency, description, reference, notes, date, deleted_at, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`);
          for (const tx of backup.transactions) {
            stmt.run(tx.id, tx.account_id || null, tx.type || 'debit', tx.amount || 0, tx.currency || 'YER', tx.description || '', tx.reference || '', tx.notes || '', tx.date || '', tx.deleted_at || '', tx.created_at || '', tx.updated_at || '');
          }
        }

        // Restore vouchers
        if (Array.isArray(backup.vouchers) && backup.vouchers.length > 0) {
          db.prepare(`DELETE FROM vouchers`).run();
          const stmt = db.prepare(`INSERT INTO vouchers (id, number, kind, account_id, amount, currency, statement, notes, status, date, deleted_at, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`);
          for (const v of backup.vouchers) {
            stmt.run(v.id, v.number || '', v.kind || 'receipt', v.account_id || null, v.amount || 0, v.currency || 'YER', v.statement || '', v.notes || '', v.status || 'posted', v.date || '', v.deleted_at || '', v.created_at || '', v.updated_at || '');
          }
        }

        // Restore users
        if (Array.isArray(backup.users) && backup.users.length > 0) {
          db.prepare(`DELETE FROM users`).run();
          const stmt = db.prepare(`INSERT INTO users (id, name, role, pin, permissions, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)`);
          for (const u of backup.users) {
            stmt.run(u.id, u.name, u.role || 'agent', u.pin || '1234', u.permissions || '[]', u.created_at || '', u.updated_at || '');
          }
        }

        // Restore settings
        if (Array.isArray(backup.settings) && backup.settings.length > 0) {
          db.prepare(`DELETE FROM settings`).run();
          const stmt = db.prepare(`INSERT INTO settings (key, value) VALUES (?, ?)`);
          for (const s of backup.settings) {
            stmt.run(s.key, s.value || '');
          }
        }

        db.prepare(`INSERT INTO activity (type, text, created_at) VALUES (?, ?, ?)`).run('backup_restored', 'تمت استعادة نسخة احتياطية سحابية ومحلية لقاعدة البيانات بنجاح', new Date().toISOString());

        db.exec('COMMIT');
      } catch (err) {
        db.exec('ROLLBACK');
        throw err;
      }

      broadcastSyncEvent('backup_restored', { timestamp: new Date().toISOString() });
      res.json({ ok: true, message: 'تمت استعادة النسخة الاحتياطية بنجاح' });
    } catch (e: any) {
      res.status(500).json({ error: e.message });
    }
  });

  // Vite middleware in dev, static files in prod
  if (process.env.NODE_ENV !== 'production') {
    const vite = await createViteServer({
      server: { middlewareMode: true },
      appType: 'spa',
    });
    app.use(vite.middlewares);
  } else {
    const distPath = path.join(process.cwd(), 'dist');
    app.use(express.static(distPath));
    app.get('*', (req, res) => {
      res.sendFile(path.join(distPath, 'index.html'));
    });
  }

  app.listen(PORT, '0.0.0.0', () => {
    console.log(`🚀 Nexora Ledger App running on http://0.0.0.0:${PORT}`);
  });
}

startServer();
