// (دفعة 58) تطبيق لقطة الانضمام — استُخرجت من LanSyncService المحذوف.
// تُستخدم حصرياً في مسار الانضمام السحابي (CloudJoin.join/completeApprovedJoin):
// تمسح بيانات الجهاز المحلية كاملة وتستبدلها بنسخة المجموعة.
import 'package:sqflite/sqflite.dart';

import '../../core/secret_store.dart';

class SnapshotApply {
  /// يُطبّق لقطة البيانات القادمة من المضيف على الجهاز العضو (يمسح القديم ويستبدله).
  static Future<void> applySnapshot(
    Future<Database> Function() dbProvider,
    String ourDeviceId,
    Map<String, Object?> snap,
  ) async {
    final db = await dbProvider();
    await db.transaction((txn) async {
      final knownDevices =
          await txn.query('devices', columns: ['id', 'auth_secret']);
      final knownSecrets = {
        for (final d in knownDevices) d['id']: d['auth_secret']
      };
      // 1) مسح البيانات المحلية (نُبقي devices/workspaces/sync_meta جزئياً).
      // «حذف كامل»: يشمل أيضاً القوالب والإشعارات وإعدادات العمل القديمة —
      // لا يبقى من بيانات الجهاز القديمة أي أثر بعد الانضمام.
      const clearTables = [
        'templates',
        'notifications',
        'accounts',
        'transactions',
        'transaction_items',
        'vouchers',
        'currencies',
        'categories',
        'item_categories',
        'items',
        'stock_moves',
        'conversations',
        'messages',
        'users',
        'trash',
        'activity',
        'operations',
        'sync_queue',
      ];
      for (final t in clearTables) {
        await txn.delete(t);
      }
      // نحذف سجلات الأجهزة الأخرى ونُبقي سجلنا وسجل المضيف.
      await txn.delete('devices', where: 'id <> ?', whereArgs: [ourDeviceId]);

      // 2) نسخ الجداول من اللقطة.
      Future<void> insertAll(String table) async {
        final raw = snap[table];
        if (raw is! List) return;
        for (final r in raw) {
          if (r is! Map) continue;
          try {
            final map = <String, Object?>{};
            r.forEach((k, v) {
              if (k is String) map[k] = v as Object?;
            });
            if (table == 'devices') {
              // (دفعة 58) أعمدة LAN أُسقطت من المخطط — لقطات المضيفين
              // الأقدم قد ما تزال تحملها فتُسقط قبل الإدراج.
              map.remove('ip_address');
              map.remove('port');
              if (map['id'] == ourDeviceId ||
                  (map['auth_secret'] as String? ?? '').isEmpty) {
                // سرّنا لا يُكتب أبداً من لقطة واردة؛ وعند غياب السر في
                // اللقطة نحتفظ بما تعلمناه سابقاً عبر الاقتران.
                map['auth_secret'] = knownSecrets[map['id']] ?? '';
              } else {
                // (دفعة 57) سر قرين وارد صريحاً في اللقطة — يُعمّى
                // بمفتاحنا المحلي قبل أن يلمس القرص.
                map['auth_secret'] = await SecretStore.protect(
                    (map['auth_secret'] as String?) ?? '');
              }
              if (map['id'] == ourDeviceId) {
                // سجلنا كما يعرفه المضيف — لسنا مالكين.
                map['is_owner'] = 0;
              } else if ((map['is_owner'] ?? 0) == 1) {
                // تأكد من أن سجل المضيف يظل is_owner=1 (المالك الشرعي).
                map['is_owner'] = 1;
              }
            }
            if (table == 'users') {
              // العضو لا يملك أي مستخدم محلي كـ "أنا"؛ الهوية تأتي من
              // devices.user_id التي يعيّنها المدير لاحقاً.
              map['is_me'] = 0;
            }
            await txn.insert(
              table,
              map,
              conflictAlgorithm: ConflictAlgorithm.replace,
            );
          } catch (_) {}
        }
      }

      await insertAll('workspaces');
      await insertAll('users');
      await insertAll('devices');
      await insertAll('accounts');
      await insertAll('transactions');
      await insertAll('transaction_items');
      await insertAll('vouchers');
      await insertAll('currencies');
      await insertAll('categories');
      await insertAll('item_categories');
      await insertAll('items');
      await insertAll('stock_moves');
      await insertAll('conversations');
      await insertAll('messages');
      await insertAll('trash');
      await insertAll('activity');

      // 2ب) إعدادات المؤسسة: تُمسح إعدادات العمل القديمة على الجهاز المنضم
      // (اسم المؤسسة/العنوان/التذييل/الشعار القديم...) وتُستبدل بإعدادات
      // المجموعة القادمة في اللقطة — فلا يبقى اسم مؤسسته القديمة على السندات.
      const orgKeys = [
        'businessName',
        'businessNameEn',
        'address',
        'phone',
        'whatsapp',
        'email',
        'managerName',
        'voucherFooter',
        'defaultVoucherNotes',
        'logo',
      ];
      for (final k in orgKeys) {
        await txn.delete('settings', where: 'key = ?', whereArgs: [k]);
      }
      final orgSettings = snap['orgSettings'];
      if (orgSettings is Map) {
        for (final e in orgSettings.entries) {
          final k = '${e.key}';
          // الشعار ملف محلي على جهاز المضيف — لا معنى لمساره هنا.
          if (k == 'logo' || !orgKeys.contains(k)) continue;
          await txn.insert(
              'settings', {'key': k, 'value': '${e.value ?? ''}'},
              conflictAlgorithm: ConflictAlgorithm.replace);
        }
      }

      // 3) جهازنا الآن عضو (ليس مالكًا).
      await txn.update(
        'devices',
        {'is_owner': 0, 'is_paired': 1},
        where: 'id = ?',
        whereArgs: [ourDeviceId],
      );
      // 4) ضبط وضع المساحة على "عضو".
      await txn.insert(
          'sync_meta',
          {
            'key': 'workspaceMode',
            'value': 'member',
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }

}
