// (معمارية حساب Google) عزل مساحات العمل بمعرف المستخدم (UID).
//
// الفكرة: حساب Google هو هوية المؤسسة الدائمة — أثبت من أي بصمة عتاد:
//  - مساحة عمل المؤسسة القياسية: WS-{uid}.
//  - فهرس سحابي /workspaces/_registry/accounts_index/{uid} يربط الحساب
//    بمساحته الفعلية (يستوعب المساحات القديمة غير المطابقة للنمط).
//  - على جهاز جديد/بعد مسح البيانات: تسجيل الدخول بنفس الحساب يستعيد
//    المساحة والدور (مالك) والبيانات المالية من النسخة الصامتة فوراً.
//  - انضمام الموظفين يبقى كما هو عبر QR/PIN — لا يحتاجون حساب Google.
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../cloud_sync.dart';
import '../repository.dart';
import 'device_id.dart';
import 'device_registry.dart';
import 'firebase_auth_service.dart';
import 'workspace_recovery.dart';

/// نتيجة تبنّي/استرداد مساحة الحساب بعد تسجيل الدخول.
enum AccountLinkOutcome {
  /// استُعيدت مساحة سابقة كاملة بالبيانات — «عدت كما كنت».
  recovered,

  /// أول دخول: رُحّلت المساحة الحالية إلى WS-{uid} وسُجّل الربط.
  migrated,

  /// جهاز عضو في مجموعة — لا تغيير على مساحته (يتبع مديره).
  memberUntouched,

  /// تعذر الإكمال (شبكة/إعدادات).
  failed,
}

class AccountWorkspace {
  AccountWorkspace._();

  static String _indexPath(String base, String uid) =>
      '${base.replaceAll(RegExp(r'/+$'), '')}/workspaces/_registry/'
      'accounts_index/${Uri.encodeComponent(uid)}.json';

  /// مساحة العمل القياسية لحساب — WS-{uid}.
  static String workspaceIdForUid(String uid) => 'WS-$uid';

  /// قراءة مساحة الحساب من الفهرس — '' إن لم تُسجَّل بعد.
  static Future<String> lookup({
    required String backendUrl,
    required String uid,
  }) async {
    try {
      final res = await http
          .get(Uri.parse(_indexPath(backendUrl, uid)))
          .timeout(const Duration(seconds: 15));
      if (res.statusCode < 200 || res.statusCode >= 300) return '';
      final body = utf8.decode(res.bodyBytes).trim();
      if (body.isEmpty || body == 'null') return '';
      final m = jsonDecode(body);
      if (m is! Map) return '';
      return '${m['workspaceId'] ?? ''}'.trim();
    } catch (_) {
      return '';
    }
  }

  /// تسجيل ربط الحساب بمساحته (لا يُستبدل ربط قائم إلا بـ force).
  static Future<void> bind({
    required String backendUrl,
    required String uid,
    required String workspaceId,
    String email = '',
    bool force = false,
  }) async {
    try {
      if (!force) {
        final existing = await lookup(backendUrl: backendUrl, uid: uid);
        if (existing.isNotEmpty && existing != workspaceId) return;
      }
      await http
          .put(
            Uri.parse(_indexPath(backendUrl, uid)),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'workspaceId': workspaceId,
              'email': email,
              'updated_at': {'.sv': 'timestamp'},
            }),
          )
          .timeout(const Duration(seconds: 15));
    } catch (_) {}
  }

  /// بعد تسجيل دخول ناجح: تبنّي مساحة الحساب أو استردادها.
  ///
  ///  1) عضو مجموعة؟ لا نلمس مساحته — هويته تتبع مدير مجموعته.
  ///  2) الفهرس يعرف الحساب؟ استرداد مساحته المسجلة كاملة بالبيانات
  ///     (جهاز جديد/بعد مسح البيانات) — يستعيد صلاحية المالك فوراً.
  ///  3) نمط WS-{uid} له نسخة سحابية؟ استردادها كذلك.
  ///  4) أول دخول: ترحيل المساحة المحلية الحالية إلى WS-{uid} —
  ///     البيانات المحلية كلها تبقى وتُرفع نسختها الصامتة للمسار الجديد.
  static Future<AccountLinkOutcome> adoptOrRecover(
    Repo repo, {
    required String backendUrl,
    required FirebaseAccount account,
  }) async {
    if (backendUrl.isEmpty || account.uid.isEmpty) {
      return AccountLinkOutcome.failed;
    }
    try {
      final mode = await repo.workspaceMode();
      if (mode == 'member') return AccountLinkOutcome.memberUntouched;

      final current = repo.requireWorkspaceId;
      final canonical = workspaceIdForUid(account.uid);

      // (2) ربط مسجل في الفهرس؟
      final indexed =
          await lookup(backendUrl: backendUrl, uid: account.uid);
      if (indexed.isNotEmpty) {
        if (indexed == current) {
          // نفس المساحة أصلاً — تثبيت الربط فقط.
          await _afterLink(repo, backendUrl, account, current);
          return AccountLinkOutcome.migrated;
        }
        final ok = await WorkspaceRecovery.manualRestore(repo,
            backendUrl: backendUrl, workspaceId: indexed);
        if (ok) {
          await _afterLink(repo, backendUrl, account, indexed);
          return AccountLinkOutcome.recovered;
        }
        // نسخة غائبة: نتبنى المساحة المسجلة معرفاً على الأقل —
        // العمليات السحابية القادمة عبر المزامنة تكمل الباقي.
        await _swapTo(repo, indexed);
        await _afterLink(repo, backendUrl, account, indexed);
        return AccountLinkOutcome.recovered;
      }

      // (3) نسخة سحابية على النمط القياسي WS-{uid}؟
      if (canonical != current) {
        final pulled = await CloudSync.pullWorkspaceBackup(repo,
            backendUrl: backendUrl, workspaceId: canonical);
        if (pulled != null) {
          final ok = await WorkspaceRecovery.manualRestore(repo,
              backendUrl: backendUrl, workspaceId: canonical);
          if (ok) {
            await _afterLink(repo, backendUrl, account, canonical);
            return AccountLinkOutcome.recovered;
          }
        }
      }

      // (4) أول دخول لهذا الحساب: ترحيل المساحة الحالية إلى WS-{uid}.
      if (canonical != current) {
        await _swapTo(repo, canonical);
      }
      await _afterLink(repo, backendUrl, account, canonical);
      // نسخة صامتة فورية للمسار الجديد — البيانات المالية تُؤمَّن حالاً.
      try {
        await CloudSync.silentWorkspaceBackup(repo);
      } catch (_) {}
      return AccountLinkOutcome.migrated;
    } catch (_) {
      return AccountLinkOutcome.failed;
    }
  }

  /// تبديل معرف المساحة المحلية (كل الجداول) إلى المعرف المستهدف.
  static Future<void> _swapTo(Repo repo, String target) async {
    final db = await repo.database;
    final current = repo.requireWorkspaceId;
    if (current == target) return;
    await WorkspaceRecovery.swapWorkspaceId(db, from: current, to: target);
    await repo.setSetting('sync.workspaceId', target);
    repo.debugSetWorkspaceId(target);
  }

  /// تثبيت الربط بعد أي مسار ناجح: جلسة + فهرس الحساب + فهرس البصمة +
  /// ربط الـ workspace بحساب Google في الجدول المحلي.
  static Future<void> _afterLink(Repo repo, String backendUrl,
      FirebaseAccount account, String workspaceId) async {
    await FirebaseAuthRest.saveSession(repo, account);
    await bind(
      backendUrl: backendUrl,
      uid: account.uid,
      workspaceId: workspaceId,
      email: account.email,
      force: true,
    );
    try {
      await DeviceRegistry.upsertBinding(repo,
          backendUrl: backendUrl, force: true);
    } catch (_) {}
    try {
      final db = await repo.database;
      await db.update(
        'workspaces',
        {
          'owner_google_id': account.uid,
          'owner_email': account.email,
          'owner_name': account.displayName,
          'updated_at': DateTime.now().toIso8601String(),
        },
        where: 'id = ?',
        whereArgs: [workspaceId],
      );
    } catch (_) {}
    // معرف الجهاز يبقى كما هو — الربط بالحساب لا يغيّر هوية الجهاز.
    await ensureDeviceId(repo);
  }
}
