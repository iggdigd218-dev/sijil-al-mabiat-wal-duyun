// كاشف/حلّال التعارضات الأساسي.
// في هذه المرحلة نكتشف التعارض ونُسجله؛ الحل التفاعلي يُضاف لاحقًا.
import 'operation.dart';

class ConflictInfo {
  final String entityType;
  final String entityId;
  final SyncOperation localOp;
  final SyncOperation remoteOp;
  const ConflictInfo({
    required this.entityType,
    required this.entityId,
    required this.localOp,
    required this.remoteOp,
  });
}

class ConflictResolver {
  /// يقرر هل تُطبَّق العملية الواردة على الكيان المحلي.
  /// يُعيد قرارًا: تطبيق / تجاهل / تعارض.
  ConflictDecision decide({
    required SyncOperation incoming,
    required bool exists,
    required int localVersion,
    required SyncOperation? localLatest,
  }) {
    // Idempotency: نفس operationId موجود محليًا -> تجاهل.
    if (localLatest != null && localLatest.id == incoming.id) {
      return ConflictDecision.ignore(reason: 'duplicate-id');
    }
    // الكيان غير موجود والعملية create -> تطبيق.
    if (!exists && incoming.opType == OpKind.create) {
      return ConflictDecision.apply();
    }
    if (!exists && incoming.opType != OpKind.create) {
      // العملية تشير إلى كيان غير موجود محليًا ولا يمكن إعادة بنائه إلا ب payload كامل.
      // إذا كانت payload كافية، نطبّق create محلي (حالة وصول جهاز جديد من الصفر).
      if (incoming.payload.isNotEmpty) return ConflictDecision.apply();
      return ConflictDecision.conflict(reason: 'entity-missing');
    }
    // الكيان موجود: نعتمد على version.
    if (incoming.version > localVersion) {
      return ConflictDecision.apply();
    }
    if (incoming.version == localVersion) {
      // نفس الإصدار:
      // - إذا كانت نفس العملية (نفس id) فتم التعامل معها أعلاه.
      // - إذا كان localLatest موجود وبنفس deviceId -> نفس المصدر نطبق (تكرار آمن).
      if (localLatest != null && localLatest.deviceId == incoming.deviceId) {
        return ConflictDecision.apply();
      }
      // كسر التعادل بشكل deterministic بناءً على:
      //   1) timestamp الأحدث يفوز.
      //   2) إذا التساوي، deviceId lexicographically الأصغر يفوز (ثابت عبر الأجهزة).
      // النتيجة ستكون نفسها على جميع الأجهزة.
      if (localLatest != null) {
        final tIn = DateTime.tryParse(incoming.timestamp)?.millisecondsSinceEpoch ?? 0;
        final tLocal = DateTime.tryParse(localLatest.timestamp)?.millisecondsSinceEpoch ?? 0;
        if (tIn > tLocal) return ConflictDecision.apply();
        if (tIn < tLocal) return ConflictDecision.ignore(reason: 'older-timestamp-tie');
        // نفس اللحظة: deviceId الأصغر يفوز.
        if (incoming.deviceId.compareTo(localLatest.deviceId) < 0) {
          return ConflictDecision.apply();
        }
        return ConflictDecision.ignore(reason: 'tiebreak-local-wins');
      }
      return ConflictDecision.conflict(reason: 'same-version-no-local-latest');
    }
    // incoming.version < localVersion -> قديم، نحتفظ بنسختنا.
    return ConflictDecision.ignore(reason: 'older-version');
  }
}

class ConflictDecision {
  final bool apply;
  final bool conflict;
  final String? reason;
  const ConflictDecision._(this.apply, this.conflict, this.reason);
  factory ConflictDecision.apply() => const ConflictDecision._(true, false, null);
  factory ConflictDecision.ignore({required String reason}) =>
      ConflictDecision._(false, false, reason);
  factory ConflictDecision.conflict({required String reason}) =>
      ConflictDecision._(false, true, reason);
}
