// (3.70 — المرحلة 1.3) فحص ترخيص الأجهزة: الاستخدام **الوحيد** المشروع
// لبصمة/هوية الجهاز خارج بروتوكول المزامنة — مطابقة عدد الأجهزة المتصلة
// مع الحد الأقصى المسموح في خطة الاشتراك والترخيص.
//
// معزول تماماً: لا يربط ملكية أي بيانات أو فواتير أو عمليات حسابية
// بالجهاز أو بمعرّف العتاد — الملكية حصراً store_id + user_email.
import '../core/cloud_config.dart';
import 'repository.dart';
import 'sync/subscription_guard.dart';

class DeviceLicenseStatus {
  /// عدد الأجهزة المتصلة فعلياً (غير ملغاة ولا مطرودة) في المساحة.
  final int connectedDevices;

  /// مقاعد الخطة (من عقدة الاشتراك السحابية، أو الافتراضي دون شبكة).
  final int maxSeats;

  final bool withinPlan;

  const DeviceLicenseStatus({
    required this.connectedDevices,
    required this.maxSeats,
    required this.withinPlan,
  });
}

class DeviceLicense {
  DeviceLicense._();

  /// الفحص المعزول الوحيد المسموح له بقراءة هوية الأجهزة لأغراض الترخيص.
  static Future<DeviceLicenseStatus> check(Repo repo) async {
    final db = await repo.database;
    final ws = repo.requireWorkspaceId;
    final rows = await db.query(
      'devices',
      columns: ['id'],
      where: "workspace_id = ? "
          "AND (revoked_at IS NULL OR revoked_at = '') "
          "AND (expelled_at IS NULL OR expelled_at = '')",
      whereArgs: [ws],
    );
    final connected = rows.length;
    var seats = kDefaultEnterpriseSeats;
    try {
      final st = await repo.settings();
      final url = effectiveBackendUrl(st['cloudBackendUrl']);
      if (url.isNotEmpty) {
        final sub = await SubscriptionGuard.check(repo,
            backendUrl: url, workspaceId: ws);
        if (sub.maxDevices > 0) seats = sub.maxDevices;
      }
    } catch (_) {}
    return DeviceLicenseStatus(
      connectedDevices: connected,
      maxSeats: seats,
      withinPlan: connected <= seats,
    );
  }
}
