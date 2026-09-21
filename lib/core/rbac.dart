// (3.70 — المرحلة 4) الصلاحيات المحلية RBAC.
//
// المرجع الحصري للملكية والصلاحيات: **user_email + store_id** — لا بصمة
// جهاز ولا معرّف عتاد. الفحص محلي فوري (Offline-Ready): تُحجب أزرار الخصم
// والحذف والتقارير والأصناف عن الكاشير دون انتظار أي شبكة، وكل تعديل على
// الجدول يُصعد تلقائياً عبر sync_queue (EntityKind.userPermission).
import 'models.dart';

/// الأعلام النافذة للمستخدم الحالي — تُبنى من جدول user_permissions أو
/// تُشتق من الدور/الصلاحيات القديمة كجسر توافق.
class EffectivePermissions {
  final String email;
  final String role;
  final bool canDiscount;
  final bool canDeleteTx;
  final bool canViewReports;
  final bool canManageItems;
  final bool isActive;
  final bool isAdmin;

  const EffectivePermissions({
    required this.email,
    required this.role,
    required this.canDiscount,
    required this.canDeleteTx,
    required this.canViewReports,
    required this.canManageItems,
    required this.isActive,
    required this.isAdmin,
  });

  /// مدير/وكيل/حساب فردي: كل شيء مفتوح.
  factory EffectivePermissions.full(String email) => EffectivePermissions(
        email: email,
        role: 'admin',
        canDiscount: true,
        canDeleteTx: true,
        canViewReports: true,
        canManageItems: true,
        isActive: true,
        isAdmin: true,
      );

  /// مستخدم غير معروف في مؤسسة: أصفار (fail-closed) — الحساب يبقى نشطاً
  /// لكن بلا أي صلاحية حساسة حتى يُمنح صراحة.
  factory EffectivePermissions.none(String email) => EffectivePermissions(
        email: email,
        role: 'cashier',
        canDiscount: false,
        canDeleteTx: false,
        canViewReports: false,
        canManageItems: false,
        isActive: true,
        isAdmin: false,
      );

  factory EffectivePermissions.fromRow(Map<String, Object?> r) {
    final role = '${r['role'] ?? ''}';
    final admin = role == 'admin' || role == 'agent';
    int flag(String k) => (r[k] as int?) ?? 0;
    return EffectivePermissions(
      email: '${r['user_email'] ?? ''}',
      role: role,
      canDiscount: admin || flag('can_discount') == 1,
      canDeleteTx: admin || flag('can_delete_tx') == 1,
      canViewReports: admin || flag('can_view_reports') == 1,
      canManageItems: admin || flag('can_manage_items') == 1,
      isActive: flag('is_active') == 1,
      isAdmin: admin,
    );
  }
}

/// اشتقاق الأعلام من دور + قائمة صلاحيات النموذج القديم (جسر توافق).
EffectivePermissions deriveFromRolePerms(
    String email, String roleCode, String permsCsv) {
  final perms = permsCsv.split(',').map((e) => e.trim()).toSet();
  final advanced = roleGrantsAdvancedCode(roleCode);
  final admin = roleCode == 'admin' || roleCode == 'agent';
  return EffectivePermissions(
    email: email,
    role: roleCode,
    canDiscount: advanced,
    canDeleteTx: perms.contains('delete_tx'),
    canViewReports: perms.contains('view_reports'),
    canManageItems: advanced,
    isActive: true,
    isAdmin: admin,
  );
}

bool roleGrantsAdvancedCode(String code) =>
    code == 'admin' || code == 'agent' || code == 'accountant';

bool roleGrantsAdvanced(UserRole r) => roleGrantsAdvancedCode(r.code);
