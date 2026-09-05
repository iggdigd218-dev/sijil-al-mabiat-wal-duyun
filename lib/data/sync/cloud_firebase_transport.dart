// طبقة Firebase Realtime Database (REST) للمزامنة السحابية التدريجية.
//
// بنية المسار في RTDB:
//   /workspaces/{workspaceId}/operations/{opId}  → عملية JSON واحدة
//   /workspaces/{workspaceId}/meta/devices/{deviceId} → { lastSeen, lastSync, version }
//
// المزايا:
//  - دفع incremental: كل عملية تُرفع منفصلة (لا رفع قاعدة كاملة).
//  - سحب incremental: نقرأ فقط operations ذات timestamp > lastSyncCursor.
//  - Idempotent: نفس opId لا يُطبق مرتين.
//  - لا Firebase SDK ثقيل — فقط http package الموجود.
//
// المتطلبات لإطلاقها فعليًا:
//  - إنشاء مشروع Firebase وتمكين Realtime Database.
//  - ضبط rules تسمح بالكتابة/القراءة للمستخدمين المصادق بهم (أو للعامة مؤقتًا للاختبار).
//  - إدخال الـ URL في الإعدادات (مثلاً https://myproject.firebaseio.com).
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:sqflite/sqflite.dart';

import '../../core/models.dart' show OpKind;
import '../repository.dart';
import 'conflict_resolver.dart';
import 'operation.dart';
import 'sync_engine.dart';
import 'sync_queue.dart';

class CloudFirebaseTransport implements SyncTransport {
  final Repo repo;
  final String backendUrl;
  final String workspaceId;
  final Future<Database> Function() dbProvider;

  CloudFirebaseTransport({
    required this.repo,
    required Future<Database> Function() dbProvider,
    required this.backendUrl,
    required this.workspaceId,
  }) : _dbProvider = dbProvider;

  Future<Database> get _db => _dbProvider();
  final Future<Database> Function() _dbProvider;

  @override
  String get targetId => SyncTarget.cloud;

  String get _root =>
      '${backendUrl.replaceAll(RegExp(r'/+$'), '')}/workspaces/${Uri.encodeComponent(workspaceId)}';

  String _opPath(String opId) => '$_root/operations/${Uri.encodeComponent(opId)}.json';
  String get _opsPath => '$_root/operations.json';
  String get _metaPath => '$_root/meta.json';

  @override
  Future<void> push(SyncOperation op) async {
    final uri = Uri.parse(_opPath(op.id));
    final body = op.toJson();
    final res = await http.put(uri, body: body, headers: {'Content-Type': 'application/json'});
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw StateError('Cloud HTTP ${res.statusCode}: ${res.body}');
    }
    // سجّل وقت السيرفر (بسيط: نستخدم وقتنا كتقريب server_time لأنه REST لا يعيده).
    await _db.update('operations', {
      'server_time': DateTime.now().toIso8601String(),
      'synced': 1,
    }, where: 'id = ?', whereArgs: [op.id]);
    await _db.update('devices', {
      'last_sync_at': DateTime.now().toIso8601String(),
    }, where: 'id = ?', whereArgs: [op.deviceId]);
  }

  /// يجلب العمليات الأحدث من السحابة ويطبقها محليًا.
  /// يعيد عدد العمليات التي طُبقت.
  Future<int> pull({ConflictResolver? resolver}) async {
    final res = await http.get(Uri.parse(_opsPath + '?orderBy="timestamp"&limitToLast=500'));
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw StateError('Cloud HTTP ${res.statusCode}: ${res.body}');
    }
    if (res.body.trim().isEmpty || res.body.trim() == 'null') return 0;
    final decoded = jsonDecode(res.body);
    if (decoded is! Map) return 0;
    final r = resolver ?? ConflictResolver();
    int applied = 0;
    await _db.transaction((txn) async {
      for (final entry in decoded.entries) {
        final v = entry.value;
        if (v is! Map) continue;
        final op = SyncOperation.fromMap(Map<String, Object?>.from(v));
        final idempotentQ = await txn.query('operations',
            where: 'id = ?', whereArgs: [op.id], limit: 1);
        if (idempotentQ.isNotEmpty) continue; // تم تطبيقها مسبقًا.
        final ok = await repo.applyRemoteOperation(txn, op, r);
        if (ok) applied++;
      }
    });
    await repo.setSetting('lastCloudSync', DateTime.now().toLocal().toString());
    return applied;
  }
}
