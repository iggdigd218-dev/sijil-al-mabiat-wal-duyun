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
      // نفس الإصدار من جهاز مختلف -> تعارض.
      return ConflictDecision.conflict(reason: 'same-version-different-device');
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
