import 'dart:async';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'db_init.dart';

/// معرف Workspace الافتراضي (ثابت محلي لتجنب circular imports).
const defaultWorkspaceIdConst = 'default';

/// قاعدة البيانات المحلية — تقابل مخازن IndexedDB في نسخة الويب،
/// لكن بجداول SQL حقيقية مع فهارس ومفاتيح أجنبية.
class AppDatabase {
  AppDatabase._();
  static final AppDatabase instance = AppDatabase._();

  static Database? _db;
  static const int _version = 13;

  static int get schemaVersion => _version;

  /// حقن قاعدة في الذاكرة للاختبارات.
  static void overrideForTest(Database db) => _db = db;

  Future<Database> get database async {
    if (_db != null) return _db!;
    final dir = await databaseDirectory();
    _db = await openDatabase(
      p.join(dir, 'nexora.db'),
      version: _version,
      onConfigure: (db) async => db.execute('PRAGMA foreign_keys = ON'),
      onCreate: (db, v) async => createSchema(db),
      onUpgrade: (db, from, to) async => _migrate(db, from, to),
      onOpen: (db) async {
        // حماية إضافية: حتى لو لم يعمل onUpgrade في حالة غريبة نضمن وجود الجداول.
        await _ensureCoreSyncTables(db);
      },
    );
    return _db!;
  }

  Future<void> close() async {
    final db = _db;
    _db = null;
    if (db != null && db.isOpen) await db.close();
  }

  /// إنشاء كل الجداول — مستقل ليُستخدم في الاختبارات أيضًا.
  static Future<void> createSchema(Database db) async {
    // ---------- البنية الجديدة للمزامنة ----------
    await db.execute(createSyncSchemaSql);

    // ---------- الحسابات ----------
    await db.execute('''
      CREATE TABLE accounts (
        id              INTEGER PRIMARY KEY AUTOINCREMENT,
        workspace_id    TEXT NOT NULL DEFAULT 'default',
        name            TEXT NOT NULL,
        kind            TEXT NOT NULL DEFAULT 'customer',
        opening_balance REAL NOT NULL DEFAULT 0,
        currency        TEXT NOT NULL DEFAULT 'YER',
        phone           TEXT DEFAULT '',
        whatsapp        TEXT DEFAULT '',
        address         TEXT DEFAULT '',
        notes           TEXT DEFAULT '',
        category        TEXT DEFAULT '',
        credit_limit    REAL,
        tags            TEXT DEFAULT '',
        archived        INTEGER NOT NULL DEFAULT 0,
        image           TEXT DEFAULT '',
        notify_channel  TEXT NOT NULL DEFAULT 'whatsapp',
        deleted_at      TEXT DEFAULT '',
        deleted_by      INTEGER,
        restore_op_id   TEXT DEFAULT '',
        created_at      TEXT NOT NULL,
        updated_at      TEXT NOT NULL
      )''');
    await db.execute('CREATE INDEX idx_acc_kind ON accounts(kind)');
    await db.execute('CREATE INDEX idx_acc_arch ON accounts(archived)');
    await db.execute('CREATE INDEX idx_acc_del  ON accounts(deleted_at)');

    // ---------- العمليات ----------
    await db.execute('''
      CREATE TABLE transactions (
        id           INTEGER PRIMARY KEY AUTOINCREMENT,
        workspace_id TEXT NOT NULL DEFAULT 'default',
        account_id   INTEGER,
        account_kind TEXT DEFAULT 'customer',
        type         TEXT NOT NULL,
        amount       REAL NOT NULL CHECK (amount > 0),
        currency     TEXT NOT NULL DEFAULT 'YER',
        sign         TEXT DEFAULT '',
        from_id      INTEGER,
        to_id        INTEGER,
        rate         REAL NOT NULL DEFAULT 1,
        description  TEXT DEFAULT '',
        reference    TEXT DEFAULT '',
        notes        TEXT DEFAULT '',
        category     TEXT DEFAULT '',
        attachment   TEXT DEFAULT '',
        image        TEXT DEFAULT '',
        status       TEXT NOT NULL DEFAULT 'done',
        date         TEXT NOT NULL,
        deleted_at   TEXT DEFAULT '',
        deleted_by   INTEGER,
        restore_op_id TEXT DEFAULT '',
        created_at   TEXT NOT NULL,
        updated_at   TEXT NOT NULL,
        FOREIGN KEY (account_id) REFERENCES accounts (id) ON DELETE CASCADE,
        FOREIGN KEY (from_id)    REFERENCES accounts (id) ON DELETE CASCADE,
        FOREIGN KEY (to_id)      REFERENCES accounts (id) ON DELETE CASCADE
      )''');
    await db.execute('CREATE INDEX idx_tx_acc ON transactions(account_id)');
    await db.execute('CREATE INDEX idx_tx_date ON transactions(date)');
    await db.execute('CREATE INDEX idx_tx_from ON transactions(from_id)');
    await db.execute('CREATE INDEX idx_tx_to ON transactions(to_id)');
    await db.execute('CREATE INDEX idx_tx_del ON transactions(deleted_at)');

    // ---------- السندات ----------
    await db.execute('''
      CREATE TABLE vouchers (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        workspace_id TEXT NOT NULL DEFAULT 'default',
        number      TEXT NOT NULL,
        kind        TEXT NOT NULL,
        account_id  INTEGER,
        tx_id       INTEGER,
        amount      REAL NOT NULL DEFAULT 0,
        currency    TEXT NOT NULL DEFAULT 'YER',
        statement   TEXT DEFAULT '',
        notes       TEXT DEFAULT '',
        status      TEXT NOT NULL DEFAULT 'draft',
        date        TEXT NOT NULL,
        deleted_at  TEXT DEFAULT '',
        deleted_by   INTEGER,
        restore_op_id TEXT DEFAULT '',
        created_at  TEXT NOT NULL,
        updated_at  TEXT NOT NULL,
        FOREIGN KEY (account_id) REFERENCES accounts (id) ON DELETE SET NULL
      )''');
    await db.execute('CREATE INDEX idx_v_acc ON vouchers(account_id)');
    await db.execute('CREATE INDEX idx_v_del ON vouchers(deleted_at)');

    // ---------- العملات ----------
    await db.execute('''
      CREATE TABLE currencies (
        code    TEXT PRIMARY KEY,
        workspace_id TEXT NOT NULL DEFAULT 'default',
        name    TEXT NOT NULL,
        symbol  TEXT NOT NULL,
        decimal INTEGER NOT NULL DEFAULT 0,
        rate    REAL NOT NULL DEFAULT 1,
        deleted_at TEXT DEFAULT ''
      )''');

    // ---------- التصنيفات ----------
    await db.execute('''
      CREATE TABLE categories (
        id         INTEGER PRIMARY KEY AUTOINCREMENT,
        workspace_id TEXT NOT NULL DEFAULT 'default',
        name       TEXT NOT NULL,
        scope      TEXT NOT NULL DEFAULT 'account',
        created_at TEXT NOT NULL
      )''');

    // ---------- فئات المخزون ----------
    await db.execute(createItemCategoriesSql);
    await db.execute(
        'CREATE UNIQUE INDEX idx_item_categories_name ON item_categories(name COLLATE NOCASE)');

    // ---------- المستخدمون والصلاحيات ----------
    await db.execute('''
      CREATE TABLE users (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        workspace_id TEXT NOT NULL DEFAULT 'default',
        name        TEXT NOT NULL,
        role        TEXT NOT NULL DEFAULT 'manager',
        pin         TEXT DEFAULT '',
        password    TEXT DEFAULT '',
        permissions TEXT DEFAULT '',
        is_me       INTEGER NOT NULL DEFAULT 0,
        active      INTEGER NOT NULL DEFAULT 1,
        deleted_at  TEXT DEFAULT '',
        deleted_by   INTEGER,
        restore_op_id TEXT DEFAULT '',
        created_at  TEXT NOT NULL,
        updated_at  TEXT NOT NULL
      )''');

    // ---------- الدردشة ----------
    await db.execute('''
      CREATE TABLE conversations (
        id         INTEGER PRIMARY KEY AUTOINCREMENT,
        workspace_id TEXT NOT NULL DEFAULT 'default',
        title      TEXT NOT NULL,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )''');
    await db.execute('''
      CREATE TABLE messages (
        id              INTEGER PRIMARY KEY AUTOINCREMENT,
        conversation_id INTEGER NOT NULL,
        workspace_id    TEXT NOT NULL DEFAULT 'default',
        sender          TEXT NOT NULL DEFAULT '',
        body            TEXT DEFAULT '',
        kind            TEXT NOT NULL DEFAULT 'text',
        payload         TEXT DEFAULT '',
        created_at      TEXT NOT NULL,
        FOREIGN KEY (conversation_id) REFERENCES conversations (id) ON DELETE CASCADE
      )''');
    await db.execute('CREATE INDEX idx_msg_conv ON messages(conversation_id)');

    // ---------- سجل النشاط ----------
    await db.execute('''
      CREATE TABLE activity (
        id         INTEGER PRIMARY KEY AUTOINCREMENT,
        workspace_id TEXT NOT NULL DEFAULT 'default',
        text       TEXT NOT NULL,
        ref_type   TEXT DEFAULT '',
        ref_id     TEXT DEFAULT '',
        user_name  TEXT DEFAULT '',
        created_at TEXT NOT NULL
      )''');
    await db.execute('CREATE INDEX idx_act_date ON activity(created_at)');

    // ---------- سلة المحذوفات القديمة (يبقى للتوافق مع الإصدارات السابقة) ----------
    await db.execute('''
      CREATE TABLE trash (
        id         INTEGER PRIMARY KEY AUTOINCREMENT,
        store      TEXT NOT NULL,
        payload    TEXT NOT NULL,
        label      TEXT DEFAULT '',
        created_at TEXT NOT NULL
      )''');

    // ---------- التنبيهات ----------
    await db.execute('''
      CREATE TABLE notifications (
        id         INTEGER PRIMARY KEY AUTOINCREMENT,
        title      TEXT NOT NULL,
        body       TEXT DEFAULT '',
        kind       TEXT DEFAULT 'info',
        seen       INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL
      )''');

    // ---------- قوالب الرسائل ----------
    await db.execute('''
      CREATE TABLE templates (
        id         INTEGER PRIMARY KEY AUTOINCREMENT,
        name       TEXT NOT NULL,
        body       TEXT NOT NULL,
        created_at TEXT NOT NULL
      )''');

    // ---------- الأصناف والمخزون ----------
    await db.execute(createItemsSql);
    await db.execute(createStockSql);
    await db.execute('CREATE INDEX idx_stock_item ON stock_moves(item_id)');
    await db.execute(createTransactionItemsSql);
    await db.execute('CREATE INDEX idx_tx_items_tx ON transaction_items(tx_id)');

    // ---------- الإعدادات ----------
    await db.execute('''
      CREATE TABLE settings (
        key   TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )''');

    await _seed(db);
  }

  /// جداول المزامنة الجديدة (v5).
  static const createSyncSchemaSql = '''
      CREATE TABLE workspaces (
        id              TEXT PRIMARY KEY,
        name            TEXT NOT NULL DEFAULT '',
        owner_google_id TEXT DEFAULT '',
        owner_email     TEXT DEFAULT '',
        owner_name      TEXT DEFAULT '',
        created_at      TEXT NOT NULL,
        updated_at      TEXT NOT NULL
      );

      CREATE TABLE devices (
        id             TEXT PRIMARY KEY,
        workspace_id   TEXT NOT NULL,
        name           TEXT NOT NULL DEFAULT '',
        platform       TEXT DEFAULT '',
        app_version    TEXT DEFAULT '',
        ip_address     TEXT DEFAULT '',
        port           INTEGER DEFAULT 0,
        last_seen_at   TEXT DEFAULT '',
        last_sync_at   TEXT DEFAULT '',
        pair_token     TEXT DEFAULT '',
        pair_token_exp TEXT DEFAULT '',
        auth_secret    TEXT DEFAULT '',
        revoked_at     TEXT DEFAULT '',
        user_id        INTEGER,
        paired_by      INTEGER,
        is_paired      INTEGER NOT NULL DEFAULT 1,
        is_owner       INTEGER NOT NULL DEFAULT 0,
        created_at     TEXT NOT NULL,
        updated_at     TEXT NOT NULL,
        FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE,
        FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE SET NULL
      );

      CREATE TABLE operations (
        id           TEXT PRIMARY KEY,
        device_id    TEXT NOT NULL,
        workspace_id TEXT NOT NULL,
        user_id      INTEGER,
        entity_type  TEXT NOT NULL,
        entity_id    TEXT NOT NULL,
        op_type      TEXT NOT NULL,
        version      INTEGER NOT NULL DEFAULT 1,
        parent_op_id TEXT DEFAULT '',
        payload      TEXT NOT NULL,
        device_time  TEXT NOT NULL,
        server_time  TEXT DEFAULT '',
        timestamp    TEXT NOT NULL,
        synced       INTEGER NOT NULL DEFAULT 0
      );
      CREATE INDEX idx_ops_entity ON operations(entity_type, entity_id);
      CREATE INDEX idx_ops_time   ON operations(timestamp);
      CREATE INDEX idx_ops_sync   ON operations(synced, timestamp);

      CREATE TABLE sync_queue (
        id           INTEGER PRIMARY KEY AUTOINCREMENT,
        operation_id TEXT NOT NULL,
        status       TEXT NOT NULL DEFAULT 'pending',
        target       TEXT NOT NULL DEFAULT 'cloud',
        attempts     INTEGER NOT NULL DEFAULT 0,
        last_error   TEXT DEFAULT '',
        next_try_at  TEXT DEFAULT '',
        created_at   TEXT NOT NULL,
        updated_at   TEXT NOT NULL,
        UNIQUE(operation_id, target),
        FOREIGN KEY (operation_id) REFERENCES operations(id) ON DELETE CASCADE
      );
      CREATE INDEX idx_queue_status ON sync_queue(status, next_try_at);

      CREATE TABLE sync_meta (
        key   TEXT PRIMARY KEY,
        value TEXT NOT NULL
      );

      CREATE TABLE google_auth (
        id           INTEGER PRIMARY KEY CHECK (id = 1),
        google_id    TEXT DEFAULT '',
        email        TEXT DEFAULT '',
        display_name TEXT DEFAULT '',
        photo_url    TEXT DEFAULT '',
        id_token     TEXT DEFAULT '',
        signed_in_at TEXT DEFAULT '',
        updated_at   TEXT DEFAULT ''
      );
  ''';

  static const createItemCategoriesSql = '''
      CREATE TABLE item_categories (
        id         INTEGER PRIMARY KEY AUTOINCREMENT,
        workspace_id TEXT NOT NULL DEFAULT 'default',
        name       TEXT NOT NULL,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )''';

  static const createItemsSql = '''
      CREATE TABLE items (
        id            INTEGER PRIMARY KEY AUTOINCREMENT,
        workspace_id  TEXT NOT NULL DEFAULT 'default',
        name          TEXT NOT NULL,
        category_id   INTEGER,
        sku           TEXT DEFAULT '',
        unit          TEXT DEFAULT 'حبة',
        buy_price     REAL NOT NULL DEFAULT 0,
        sell_price    REAL NOT NULL DEFAULT 0,
        quantity      REAL NOT NULL DEFAULT 0,
        min_quantity  REAL NOT NULL DEFAULT 0,
        currency      TEXT NOT NULL DEFAULT 'YER',
        category      TEXT DEFAULT '',
        notes         TEXT DEFAULT '',
        image         TEXT DEFAULT '',
        archived      INTEGER NOT NULL DEFAULT 0,
        deleted_at    TEXT DEFAULT '',
        deleted_by    INTEGER,
        restore_op_id TEXT DEFAULT '',
        created_at    TEXT NOT NULL,
        updated_at    TEXT NOT NULL,
        FOREIGN KEY (category_id) REFERENCES item_categories (id) ON DELETE SET NULL
      )''';

  static const createStockSql = '''
      CREATE TABLE stock_moves (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        workspace_id TEXT NOT NULL DEFAULT 'default',
        item_id     INTEGER NOT NULL,
        kind        TEXT NOT NULL,
        quantity    REAL NOT NULL DEFAULT 0,
        unit_price  REAL NOT NULL DEFAULT 0,
        account_id  INTEGER,
        notes       TEXT DEFAULT '',
        date        TEXT NOT NULL,
        deleted_at  TEXT DEFAULT '',
        deleted_by  INTEGER,
        restore_op_id TEXT DEFAULT '',
        created_at  TEXT NOT NULL,
        FOREIGN KEY (item_id) REFERENCES items (id) ON DELETE CASCADE
      )''';

  static const createTransactionItemsSql = '''
      CREATE TABLE transaction_items (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        tx_id       INTEGER NOT NULL,
        workspace_id TEXT NOT NULL DEFAULT 'default',
        item_id     INTEGER,
        name        TEXT NOT NULL,
        unit        TEXT NOT NULL DEFAULT 'حبة',
        quantity    REAL NOT NULL CHECK (quantity > 0),
        unit_price  REAL NOT NULL CHECK (unit_price >= 0),
        total       REAL NOT NULL CHECK (total >= 0),
        FOREIGN KEY (tx_id) REFERENCES transactions (id) ON DELETE CASCADE,
        FOREIGN KEY (item_id) REFERENCES items (id) ON DELETE SET NULL
      )''';

  /// ترقية المخطط مع الحفاظ على كل البيانات القائمة.
  /// ينشئ جداول المزامنة المفقودة بأمان (للدفاع ضد قواعد قديمة ناقصة).
  static Future<void> _ensureCoreSyncTables(Database db) async {
    await _tryCreateTable(db, 'sync_meta',
        'CREATE TABLE IF NOT EXISTS sync_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)');
    await _tryCreateTable(db, 'workspaces', '''
        CREATE TABLE IF NOT EXISTS workspaces (
          id TEXT PRIMARY KEY, name TEXT NOT NULL DEFAULT '',
          owner_google_id TEXT DEFAULT '', owner_email TEXT DEFAULT '',
          owner_name TEXT DEFAULT '', created_at TEXT NOT NULL, updated_at TEXT NOT NULL
        )''');
    await _tryCreateTable(db, 'devices', '''
        CREATE TABLE IF NOT EXISTS devices (
          id TEXT PRIMARY KEY, workspace_id TEXT NOT NULL,
          name TEXT NOT NULL DEFAULT '', platform TEXT DEFAULT '',
          app_version TEXT DEFAULT '', ip_address TEXT DEFAULT '',
          port INTEGER DEFAULT 0, last_seen_at TEXT DEFAULT '',
          last_sync_at TEXT DEFAULT '', pair_token TEXT DEFAULT '',
          pair_token_exp TEXT DEFAULT '', auth_secret TEXT DEFAULT '',
          revoked_at TEXT DEFAULT '', user_id INTEGER, paired_by INTEGER,
          is_paired INTEGER NOT NULL DEFAULT 1, is_owner INTEGER NOT NULL DEFAULT 0,
          created_at TEXT NOT NULL, updated_at TEXT NOT NULL
        )''');
    await _tryCreateTable(db, 'operations', '''
        CREATE TABLE IF NOT EXISTS operations (
          id TEXT PRIMARY KEY, device_id TEXT NOT NULL, workspace_id TEXT NOT NULL,
          user_id INTEGER, entity_type TEXT NOT NULL, entity_id TEXT NOT NULL,
          op_type TEXT NOT NULL, version INTEGER NOT NULL DEFAULT 1,
          parent_op_id TEXT DEFAULT '', payload TEXT NOT NULL,
          device_time TEXT NOT NULL, server_time TEXT DEFAULT '',
          timestamp TEXT NOT NULL, synced INTEGER NOT NULL DEFAULT 0
        )''');
    await _tryCreateTable(db, 'sync_queue', '''
        CREATE TABLE IF NOT EXISTS sync_queue (
          id INTEGER PRIMARY KEY AUTOINCREMENT, operation_id TEXT NOT NULL,
          status TEXT NOT NULL DEFAULT 'pending', target TEXT NOT NULL DEFAULT 'cloud',
          attempts INTEGER NOT NULL DEFAULT 0, last_error TEXT DEFAULT '',
          next_try_at TEXT DEFAULT '', created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
          UNIQUE(operation_id, target)
        )''');
    await _tryCreateTable(db, 'google_auth', '''
        CREATE TABLE IF NOT EXISTS google_auth (
          id INTEGER PRIMARY KEY CHECK (id = 1), google_id TEXT DEFAULT '',
          email TEXT DEFAULT '', display_name TEXT DEFAULT '', photo_url TEXT DEFAULT '',
          id_token TEXT DEFAULT '', signed_in_at TEXT DEFAULT '', updated_at TEXT DEFAULT ''
        )''');
    // تأكد من وجود Workspace افتراضي.
    final wsExists = await db.rawQuery('SELECT id FROM workspaces WHERE id = ?', [defaultWorkspaceIdConst]);
    if (wsExists.isEmpty) {
      final now = DateTime.now().toIso8601String();
      await db.insert('workspaces', {
        'id': defaultWorkspaceIdConst,
        'name': 'متجري',
        'owner_google_id': '', 'owner_email': '', 'owner_name': '',
        'created_at': now, 'updated_at': now,
      });
    }
    // تأكد من وجود صف schemaVersion.
    final sv = await db.rawQuery('SELECT value FROM sync_meta WHERE key = ?', ['schemaVersion']);
    if (sv.isEmpty) {
      await db.insert('sync_meta', {'key': 'schemaVersion', 'value': '$_version'});
    }
  }

  static Future<void> _tryCreateTable(Database db, String name, String sql) async {
    final rows = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name = ?", [name]);
    if (rows.isEmpty) await db.execute(sql);
  }

  static Future<void> _migrate(Database db, int from, int to) async {
    // هذا يُصلح الحالات التي كانت فيها قواعد البيانات القديمة مفقودة لبعض الجداول
    // (مثل sync_meta) بسبب نسخ سابقة من التطبيق.
    await _ensureCoreSyncTables(db);

    if (from < 2) {
      await db.execute(createItemsSql);
      await db.execute(createStockSql);
      await db.execute('CREATE INDEX idx_stock_item ON stock_moves(item_id)');
      await _addColumn(db, 'transactions', 'image', "TEXT DEFAULT ''");
      await _addColumn(db, 'users', 'password', "TEXT DEFAULT ''");
    }
    if (from < 3) {
      await db.execute(createTransactionItemsSql);
      await db.execute('CREATE INDEX idx_tx_items_tx ON transaction_items(tx_id)');
    }
    if (from < 4) {
      await db.execute(createItemCategoriesSql);
      await db.execute(
          'CREATE UNIQUE INDEX idx_item_categories_name ON item_categories(name COLLATE NOCASE)');
      await _addColumn(db, 'items', 'category_id', 'INTEGER');
      final now = DateTime.now().toIso8601String();
      await db.execute('''
        INSERT OR IGNORE INTO item_categories (name, created_at, updated_at)
        SELECT DISTINCT TRIM(category), '$now', '$now'
        FROM items
        WHERE TRIM(COALESCE(category, '')) <> ''
      ''');
      await db.execute('''
        UPDATE items
        SET category_id = (
          SELECT c.id
          FROM item_categories c
          WHERE c.name = TRIM(items.category) COLLATE NOCASE
        )
        WHERE TRIM(COALESCE(category, '')) <> ''
      ''');
    }
    // ====== Migration v4 -> v5: بنية Local-First Sync ======
    if (from < 5) {
      await _migrate4to5(db);
    }
    // ====== v6: إضافة auth_secret للأجهزة (للتحقق من هوية الجهاز المرسل في LAN) ======
    if (from < 6) {
      await _addColumn(db, 'devices', 'auth_secret', "TEXT DEFAULT ''");
    }
    // ====== v7: إضافة أعمدة لمنع الأجهزة الملغاة + معرفات مرجعية ======
    if (from < 7) {
      await _addColumn(db, 'devices', 'revoked_at', "TEXT DEFAULT ''");
    }
    // ====== v8: فهارس إضافية لتحسين أداء sync_queue + operations ======
    if (from < 8) {
      await _tryCreateIndex(db, 'idx_queue_target_status',
          'CREATE INDEX IF NOT EXISTS idx_queue_target_status ON sync_queue(target, status, next_try_at)');
      await _tryCreateIndex(db, 'idx_ops_ws_time',
          'CREATE INDEX IF NOT EXISTS idx_ops_ws_time ON operations(workspace_id, timestamp)');
    }
    // ====== v9: حقل last_synced_op في sync_meta للمزامنة التزايدية ======
    if (from < 9) {
      // لا شيء — sync_meta موجود بالفعل، ونستخدمه كـ key-value عادي.
      await _ensureCoreSyncTables(db);
      await db.insert('sync_meta', {'key': 'schemaVersion', 'value': '9'},
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    // ====== v10: حماية دفاعية للتأكد من وجود sync_meta وجداول المزامنة (إصلاح عاجل). ======
    if (from < 10) {
      await _ensureCoreSyncTables(db);
      // تأكد من وجود أعمدة v6/v7 في devices إن كانت ناقصة.
      await _addColumn(db, 'devices', 'auth_secret', "TEXT DEFAULT ''");
      await _addColumn(db, 'devices', 'revoked_at', "TEXT DEFAULT ''");
      // تأكد من وجود فهارس v8.
      await _tryCreateIndex(db, 'idx_queue_target_status',
          'CREATE INDEX IF NOT EXISTS idx_queue_target_status ON sync_queue(target, status, next_try_at)');
      await _tryCreateIndex(db, 'idx_ops_ws_time',
          'CREATE INDEX IF NOT EXISTS idx_ops_ws_time ON operations(workspace_id, timestamp)');
      await db.insert('sync_meta', {'key': 'schemaVersion', 'value': '10'},
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    // ====== v11: عمود قناة الإشعار لكل حساب (واتساب/رسالة نصية/بدون). ======
    if (from < 11) {
      await _addColumn(db, 'accounts', 'notify_channel',
          "TEXT NOT NULL DEFAULT 'whatsapp'");
      await db.insert('sync_meta', {'key': 'schemaVersion', 'value': '11'},
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    // ====== v12: إدارة الأجهزة: ربط كل جهاز بمستخدم + من قام بمنح الصلاحية. ======
    if (from < 12) {
      await _addColumn(db, 'devices', 'user_id', 'INTEGER');
      await _addColumn(db, 'devices', 'paired_by', 'INTEGER');
      // الجهاز الحالي (هذا الهاتف) يُربط بالمستخدم 'أنا' (المدير افتراضياً).
      try {
        final me = await db.query('users',
            where: 'is_me = 1 AND COALESCE(deleted_at, "") = ""',
            limit: 1);
        if (me.isNotEmpty) {
          final myUid = me.first['id'];
          await db.update('devices',
              {'user_id': myUid, 'paired_by': myUid, 'is_paired': 1},
              where: "auth_secret <> '' AND revoked_at = ''");
        }
      } catch (_) {}
      await db.insert('sync_meta', {'key': 'schemaVersion', 'value': '12'},
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    // ====== v13: وضع المساحة (مستقل/مرتبط) + is_owner للجهاز المالك ======
    if (from < 13) {
      await _addColumn(db, 'devices', 'is_owner',
          "INTEGER NOT NULL DEFAULT 0");
      // في الوضع المستقل (قبل أي اقتران)، الجهاز المحلي هو المالك.
      final localDev = await db.query('devices',
          where: "auth_secret <> '' AND COALESCE(revoked_at,'') = ''",
          orderBy: 'created_at ASC',
          limit: 1);
      if (localDev.isNotEmpty) {
        final ownerDeviceId = localDev.first['id'];
        final anyPeer = await db.query('devices',
            where: 'id <> ? AND is_paired = 1 AND COALESCE(revoked_at,"") = ""',
            whereArgs: [ownerDeviceId],
            limit: 1);
        // إذا لا يوجد جهاز آخر فهذا الجهاز هو المالك (وضع مستقل).
        if (anyPeer.isEmpty) {
          await db.update('devices', {'is_owner': 1},
              where: 'id = ?', whereArgs: [ownerDeviceId]);
          await db.insert('sync_meta',
              {'key': 'workspaceMode', 'value': 'standalone'},
              conflictAlgorithm: ConflictAlgorithm.replace);
        }
      }
      await db.insert('sync_meta', {'key': 'schemaVersion', 'value': '13'},
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }

  /// Migration v4 → v5: إضافة جداول المزامنة + أعمدة workspace/deleted للجداول القديمة.
  static Future<void> _migrate4to5(Database db) async {
    // 1) إنشاء الجداول الجديدة (workspaces, devices, operations, sync_queue, sync_meta, google_auth).
    await db.execute(createSyncSchemaSql);

    // 2) Workspace افتراضي.
    final now = DateTime.now().toIso8601String();
    await db.insert('workspaces', {
      'id': 'default',
      'name': 'متجري',
      'owner_google_id': '',
      'owner_email': '',
      'owner_name': '',
      'created_at': now,
      'updated_at': now,
    });

    // 3) إضافة أعمدة workspace_id / deleted_at للجداول الموجودة (إن لم تكن موجودة).
    const entityTables = [
      'accounts',
      'transactions',
      'vouchers',
      'currencies',
      'categories',
      'item_categories',
      'items',
      'stock_moves',
      'transaction_items',
      'users',
      'conversations',
      'messages',
      'activity',
    ];
    for (final t in entityTables) {
      await _addColumn(db, t, 'workspace_id', "TEXT NOT NULL DEFAULT 'default'");
      if (t != 'activity' && t != 'conversations' && t != 'messages' && t != 'categories' && t != 'transaction_items') {
        await _addColumn(db, t, 'deleted_at', "TEXT DEFAULT ''");
        await _addColumn(db, t, 'deleted_by', "INTEGER");
        await _addColumn(db, t, 'restore_op_id', "TEXT DEFAULT ''");
      }
    }
    // transaction_items & conversations/messages/activity لا تحتاج soft-delete مستقل (تتبع والديها).

    // 4) فهارس إضافية للأعمدة الجديدة.
    for (final t in ['accounts', 'transactions', 'vouchers', 'items', 'stock_moves', 'users', 'currencies']) {
      await _tryCreateIndex(db, 'idx_${t}_ws', 'CREATE INDEX IF NOT EXISTS idx_${t}_ws ON $t(workspace_id)');
      await _tryCreateIndex(db, 'idx_${t}_del', 'CREATE INDEX IF NOT EXISTS idx_${t}_del ON $t(deleted_at)');
    }

    // 5) إدراج sync_meta مبدئي.
    await db.insert('sync_meta', {'key': 'schemaVersion', 'value': '5'},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<void> _tryCreateIndex(Database db, String name, String sql) async {
    // IF NOT EXISTS يجعل العملية آمنة.
    final safe = sql.contains('IF NOT EXISTS') ? sql : sql.replaceFirst('CREATE INDEX', 'CREATE INDEX IF NOT EXISTS');
    await db.execute(safe);
  }

  /// إضافة عمود إن لم يكن موجودًا — آمنة للتكرار.
  static Future<void> _addColumn(
      Database db, String table, String column, String type) async {
    final cols = await db.rawQuery('PRAGMA table_info($table)');
    if (cols.any((c) => c['name'] == column)) return;
    await db.execute('ALTER TABLE $table ADD COLUMN $column $type');
  }

  /// البيانات الأولية: العملات الثلاث ومستخدم المدير.
  static Future<void> _seed(Database db) async {
    final now = DateTime.now().toIso8601String();
    for (final c in const [
      ['YER', 'الريال اليمني', 'ر.ي', 0],
      ['USD', 'الدولار الأمريكي', r'$', 2],
      ['SAR', 'الريال السعودي', 'ر.س', 2],
    ]) {
      await db.insert('currencies', {
        'code': c[0],
        'name': c[1],
        'symbol': c[2],
        'decimal': c[3],
        'rate': 1.0,
      });
    }
    await db.insert('users', {
      'name': 'المدير',
      'role': 'manager',
      'is_me': 1,
      'active': 1,
      'created_at': now,
      'updated_at': now,
    });
  }
}
