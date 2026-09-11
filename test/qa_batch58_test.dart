// QA — دفعة 58: اجتثاث LAN + الحذف التلقائي للدردشة (24 ساعة).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexora_app/core/database.dart';
import 'package:nexora_app/data/repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  late Directory tmp;
  late Database db;
  late Repo repo;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('nexora_b58_');
    db = await databaseFactory.openDatabase('${tmp.path}/qa.db');
    await AppDatabase.createSchema(db);
    repo = Repo(databaseProvider: () async => db);
    await repo.initSyncInfra();
  });
  tearDown(() async {
    if (db.isOpen) await db.close();
    await tmp.delete(recursive: true);
  });

  test('B58-SCHEMA-01 لا جدول op_deliveries ولا أعمدة ip/port في devices',
      () async {
    final t = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='op_deliveries'");
    expect(t, isEmpty, reason: 'v22 يسقط op_deliveries نهائياً');
    final cols = await db.rawQuery('PRAGMA table_info(devices)');
    final names = cols.map((c) => '${c['name']}').toSet();
    expect(names.contains('ip_address'), isFalse);
    expect(names.contains('port'), isFalse);
  });

  test('B58-CHAT-01 رسائل أقدم من 24 ساعة تُحذف نهائياً والأحدث تبقى',
      () async {
    // محادثة المجموعة + رسالتان: قديمة (25 ساعة) وحديثة.
    final now = DateTime.now();
    await db.insert('conversations', {
      'id': Repo.groupConversationId,
      'workspace_id': 'default',
      'title': 'دردشة المجموعة',
      'created_at': now.toIso8601String(),
      'updated_at': now.toIso8601String(),
    });
    await db.insert('messages', {
      'conversation_id': Repo.groupConversationId,
      'workspace_id': 'default',
      'sender': 'DEV-A',
      'body': 'قديمة',
      'kind': 'text',
      'payload': '',
      'created_at':
          now.subtract(const Duration(hours: 25)).toIso8601String(),
    });
    await db.insert('messages', {
      'conversation_id': Repo.groupConversationId,
      'workspace_id': 'default',
      'sender': 'DEV-A',
      'body': 'حديثة',
      'kind': 'text',
      'payload': '',
      'created_at': now.toIso8601String(),
    });
    final purged = await repo.purgeExpiredChatMessages();
    expect(purged, 1);
    final left = await db.query('messages');
    expect(left, hasLength(1));
    expect(left.single['body'], 'حديثة');
  });

  test('B58-CHAT-02 عمليات message المرفوعة القديمة تُقلَّم مع التطهير',
      () async {
    final old = DateTime.now().subtract(const Duration(hours: 30));
    await db.insert('operations', {
      'id': 'OP-CHAT-OLD',
      'workspace_id': 'default',
      'device_id': 'DEV-A',
      'entity_type': 'message',
      'entity_id': '1',
      'op_type': 'create',
      'version': 1,
      'parent_op_id': '',
      'payload': '{"file_b64":"xxxx"}',
      'device_time': old.toIso8601String(),
      'timestamp': old.toIso8601String(),
      'synced': 1,
    });
    await repo.purgeExpiredChatMessages();
    final ops = await db.query('operations', where: "id = 'OP-CHAT-OLD'");
    expect(ops, isEmpty,
        reason: 'حمولة الدردشة المرفوعة الأقدم من المهلة تُحذف محلياً');
  });
}
