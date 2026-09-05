// إدارة صف المزامنة (sync_queue).
// لا تقوم هذه الطبقة بأي اتصال شبكة فعلي — فقط تدير حالات الصفوف
// وجدولة إعادة المحاولة مع backoff متزايد.
import 'dart:convert';
import 'dart:math';

import 'package:sqflite/sqflite.dart';

import 'operation.dart';

class QueueItem {
  final int id;
  final String operationId;
  final SyncStatus status;
  final String target;
  final int attempts;
  final String lastError;
  final DateTime? nextTryAt;
  final DateTime createdAt;
  final DateTime updatedAt;

  const QueueItem({
    required this.id,
    required this.operationId,
    required this.status,
    required this.target,
    required this.attempts,
    required this.lastError,
    required this.nextTryAt,
    required this.createdAt,
    required this.updatedAt,
  });
}

class SyncQueueOps {
  final Database db;
  SyncQueueOps(this.db);

  Future<int> enqueue(String operationId, {String target = SyncTarget.cloud}) async {
    final now = DateTime.now().toIso8601String();
    // idempotent: إن كان الصف موجودًا للعملية والهدف فلا تكرره.
    final existing = await db.query('sync_queue',
        where: 'operation_id = ? AND target = ?',
        whereArgs: [operationId, target],
        limit: 1);
    if (existing.isNotEmpty) return existing.first['id'] as int;
    return db.insert('sync_queue', {
      'operation_id': operationId,
      'status': SyncStatus.pending.name,
      'target': target,
      'attempts': 0,
      'last_error': '',
      'next_try_at': '',
      'created_at': now,
      'updated_at': now,
    });
  }

  Future<void> markSyncing(int id) async {
    await db.update(
      'sync_queue',
      {
        'status': SyncStatus.syncing.name,
        'attempts': (await _incAttempts(id)),
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<int> _incAttempts(int id) async {
    final rows = await db
        .query('sync_queue', columns: ['attempts'], where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return 1;
    return (rows.first['attempts'] as int? ?? 0) + 1;
  }

  Future<void> markSynced(int id) async {
    final now = DateTime.now().toIso8601String();
    await db.update(
      'sync_queue',
      {'status': SyncStatus.synced.name, 'last_error': '', 'next_try_at': '', 'updated_at': now},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> markFailed(int id, Object error, {int maxAttempts = 12}) async {
    final now = DateTime.now();
    final rows = await db
        .query('sync_queue', columns: ['attempts'], where: 'id = ?', whereArgs: [id]);
    final attempts = rows.isEmpty ? 1 : ((rows.first['attempts'] as int?) ?? 0) + 1;
    final tooMany = attempts >= maxAttempts;
    final next = tooMany
        ? null
        : now.add(_backoffFor(attempts));
    await db.update(
      'sync_queue',
      {
        'status': tooMany ? SyncStatus.failed.name : SyncStatus.pending.name,
        'attempts': attempts,
        'last_error': '$error'.length > 500 ? '${'$error'.substring(0, 500)}…' : '$error',
        'next_try_at': next?.toIso8601String() ?? '',
        'updated_at': now.toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// يعيد قائمة الصفوف الجاهزة للإرسال (pending / failed مع انتهاء وقت إعادة المحاولة).
  Future<List<Map<String, Object?>>> pickPending({int limit = 20, String? target}) async {
    final now = DateTime.now().toIso8601String();
    final where = StringBuffer(
      "status IN (?, ?) AND (next_try_at = '' OR next_try_at <= ?)",
    );
    final args = <Object?>[SyncStatus.pending.name, SyncStatus.failed.name, now];
    if (target != null) {
      where.write(' AND target = ?');
      args.add(target);
    }
    return db.query(
      'sync_queue',
      where: where.toString(),
      whereArgs: args,
      orderBy: 'created_at ASC',
      limit: limit,
    );
  }

  Future<int> countPending() async {
    final r = await db.rawQuery(
        "SELECT COUNT(*) AS c FROM sync_queue WHERE status IN (?, ?)",
        [SyncStatus.pending.name, SyncStatus.syncing.name]);
    return (r.first['c'] as int?) ?? 0;
  }

  Future<int> countFailed() async {
    final r = await db.rawQuery(
        "SELECT COUNT(*) AS c FROM sync_queue WHERE status = ?", [SyncStatus.failed.name]);
    return (r.first['c'] as int?) ?? 0;
  }

  /// Exponential backoff: 5s, 30s, 2m, 10m, 1h, 4h, ثم ثابت عند 4 ساعات.
  static Duration _backoffFor(int attempt) {
    const table = [
      Duration(seconds: 5),
      Duration(seconds: 30),
      Duration(minutes: 2),
      Duration(minutes: 10),
      Duration(hours: 1),
    ];
    if (attempt - 1 < table.length) return table[attempt - 1];
    return const Duration(hours: 4);
  }
}

/// يولّد UUID v4 بسيط بدون حزم خارجية.
String uuid() {
  final r = Random.secure();
  final bytes = List<int>.generate(16, (_) => r.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
  bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant 10
  String hex(int b) => b.toRadixString(16).padLeft(2, '0');
  final chars = bytes.map(hex).join();
  return '${chars.substring(0, 8)}-${chars.substring(8, 12)}-${chars.substring(12, 16)}-${chars.substring(16, 20)}-${chars.substring(20)}';
}

/// يولّد سرًا عشوائيًا قصيرًا لمصادقة أجهزة LAN (يُشارك أثناء الاقتران).
String generateLanSecret() {
  final r = Random.secure();
  final bytes = List<int>.generate(24, (_) => r.nextInt(256));
  // Base64url بدون padding لتبسيط الإرسال.
  final b64 = base64Url.encode(bytes).replaceAll('=', '');
  return b64;
}
