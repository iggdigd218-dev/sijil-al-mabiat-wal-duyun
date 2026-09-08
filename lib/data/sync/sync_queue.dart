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

  Future<int> enqueue(
    String operationId, {
    String target = SyncTarget.cloud,
  }) async {
    final now = DateTime.now().toIso8601String();
    // idempotent: إن كان الصف موجودًا للعملية والهدف فلا تكرره.
    final existing = await db.query(
      'sync_queue',
      where: 'operation_id = ? AND target = ?',
      whereArgs: [operationId, target],
      limit: 1,
    );
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
    final rows = await db.query(
      'sync_queue',
      columns: ['attempts'],
      where: 'id = ?',
      whereArgs: [id],
    );
    if (rows.isEmpty) return 1;
    return (rows.first['attempts'] as int? ?? 0) + 1;
  }

  Future<void> markSynced(int id) async {
    final now = DateTime.now().toIso8601String();
    await db.update(
      'sync_queue',
      {
        'status': SyncStatus.synced.name,
        'last_error': '',
        'next_try_at': '',
        'updated_at': now,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// تسجيل فشل مؤقت: لا توجد حالة "فشل نهائي" إطلاقًا — أي عملية تبقى
  /// في الانتظار (pending) وتُعاد جدولتها بمحاولة تالية حتى تنجح.
  /// الحقل last_error يحفظ آخر سبب فقط للعرض، دون إيقاف المحاولات.
  Future<void> markFailed(int id, Object error) async {
    final now = DateTime.now();
    final rows = await db.query(
      'sync_queue',
      columns: ['attempts'],
      where: 'id = ?',
      whereArgs: [id],
    );
    final attempts =
        rows.isEmpty ? 1 : max(1, (rows.first['attempts'] as int?) ?? 0);
    // Backoff متزايد لكنه مقيّد بسقف دقيقتين كحد أقصى، فتستمر المحاولات
    // للأبد (كل دقيقتين) حتى في حالات انقطاع الشبكة الطويلة.
    final next = now.add(_backoffFor(attempts));
    await db.update(
      'sync_queue',
      {
        'status': SyncStatus.pending.name,
        'attempts': attempts,
        'last_error':
            '$error'.length > 500 ? '${'$error'.substring(0, 500)}…' : '$error',
        'next_try_at': next.toIso8601String(),
        'updated_at': now.toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// هل توجد صفوف لها آخر خطأ (فشلت محاولتها الأخيرة) لكنها ما زالت ستُعاد.
  Future<int> countWithError() async {
    final r = await db.rawQuery(
      "SELECT COUNT(*) AS c FROM sync_queue "
      "WHERE status IN (?, ?) AND COALESCE(last_error,'') <> ''",
      [SyncStatus.pending.name, SyncStatus.syncing.name],
    );
    return (r.first['c'] as int?) ?? 0;
  }

  /// قائمة الصفوف ذات الأخطاء (للعرض في شاشة العمليات المتزامنة).
  Future<List<Map<String, Object?>>> rowsWithError({int limit = 50}) async {
    return db.query(
      'sync_queue',
      where:
          "status IN (?, ?) AND COALESCE(last_error,'') <> ''",
      whereArgs: [SyncStatus.pending.name, SyncStatus.syncing.name],
      orderBy: 'updated_at DESC',
      limit: limit,
    );
  }

  /// كل الصفوف غير المكتملة (معلّقة/قيد المزامنة/لها خطأ) — للعرض والإعادة.
  Future<List<Map<String, Object?>>> activeRows({int limit = 200}) async {
    return db.query(
      'sync_queue',
      where: 'status IN (?, ?, ?)',
      whereArgs: [
        SyncStatus.pending.name,
        SyncStatus.syncing.name,
        SyncStatus.failed.name,
      ],
      orderBy: 'updated_at DESC',
      limit: limit,
    );
  }

  /// إعادة محاولة يدوية فورية: تصفير وقت الانتظار والأخطاء لتُدفع الآن.
  Future<int> retryNow({int? id}) async {
    final now = DateTime.now().toIso8601String();
    final data = {
      'status': SyncStatus.pending.name,
      'next_try_at': '',
      'last_error': '',
      'updated_at': now,
    };
    if (id != null) {
      return db.update('sync_queue', data,
          where: 'id = ?', whereArgs: [id]);
    }
    return db.update('sync_queue', data,
        where: 'status IN (?, ?)',
        whereArgs: [SyncStatus.pending.name, SyncStatus.failed.name]);
  }

  /// Only scheduled pending rows are automatic retries; failed is terminal.
  Future<List<Map<String, Object?>>> pickPending({
    int limit = 20,
    String? target,
  }) async {
    final now = DateTime.now().toIso8601String();
    final where = StringBuffer(
      "status = ? AND (next_try_at = '' OR next_try_at <= ?)",
    );
    final args = <Object?>[
      SyncStatus.pending.name,
      now,
    ];
    if (target != null) {
      where.write(' AND target = ?');
      args.add(target);
    }
    // attempts ASC أولاً: العمليات الجديدة (0 محاولات) تُرسل قبل العالقة
    // المتكررة الفشل — يمنع «تجويع» العمليات الجديدة خلف طابور قديم معلّق.
    return db.query(
      'sync_queue',
      where: where.toString(),
      whereArgs: args,
      orderBy: 'attempts ASC, created_at ASC',
      limit: limit,
    );
  }

  /// A process can terminate after marking a row syncing but before an ack.
  Future<void> recoverInterrupted() async {
    await db.update(
        'sync_queue',
        {
          'status': SyncStatus.pending.name,
          'next_try_at': '',
          'updated_at': DateTime.now().toIso8601String(),
        },
        where: 'status = ?',
        whereArgs: [SyncStatus.syncing.name]);
  }

  /// إعادة محاولة فورية من المستخدم: تُعيد كل الصفوف غير المكتملة
  /// (بما فيها ذات الأخطار المؤقتة) لتُدفع الآن دون انتظار backoff.
  Future<void> retryFailed() async {
    await db.update(
      'sync_queue',
      {
        'status': SyncStatus.pending.name,
        'attempts': 0,
        'next_try_at': '',
        'last_error': '',
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'status IN (?, ?, ?)',
      whereArgs: [
        SyncStatus.pending.name,
        SyncStatus.syncing.name,
        SyncStatus.failed.name,
      ],
    );
  }

  Future<int> countPending() async {
    final r = await db.rawQuery(
      "SELECT COUNT(*) AS c FROM sync_queue WHERE status IN (?, ?)",
      [SyncStatus.pending.name, SyncStatus.syncing.name],
    );
    return (r.first['c'] as int?) ?? 0;
  }

  Future<int> countFailed() async {
    final r = await db.rawQuery(
      "SELECT COUNT(*) AS c FROM sync_queue WHERE status = ?",
      [SyncStatus.failed.name],
    );
    return (r.first['c'] as int?) ?? 0;
  }

  /// Backoff متزايد لكنه يصل إلى سقف دقيقتين ثم يثبت عليه، فلا تتوقف
  /// المحاولات أبدًا (إعادة كل دقيقتين حتى تُستأنف الشبكة وتنجح العملية).
  static Duration _backoffFor(int attempt) {
    const table = [
      Duration(seconds: 5),
      Duration(seconds: 10),
      Duration(seconds: 20),
      Duration(seconds: 45),
      Duration(minutes: 1),
    ];
    if (attempt - 1 < table.length) return table[attempt - 1];
    return const Duration(minutes: 2);
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
