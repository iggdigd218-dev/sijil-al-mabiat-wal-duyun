// تدفق الانضمام لمجموعة بعد مسح باركود الاقتران — منطق واحد مشترك
// تستدعيه شاشة إدارة المجموعة وشاشة إعدادات المزامنة، فلا يضيع المسح
// دون ربط فعلي (كان باركود إدارة المجموعة يفتح الكاميرا ويهمل النتيجة).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/sfx.dart';
import '../data/providers.dart';
import '../data/sync/device_id.dart';
import '../data/sync/lan_http_transport.dart';
import 'join_approval_flow.dart' show JoinApprovalScreen;
import 'qr_pair_scanner.dart' show PairingData;
import 'widgets.dart';

/// ينفّذ الانضمام الكامل لمجموعة انطلاقاً من بيانات باركود ممسوح:
/// تأكيد المستخدم ← اقتران ← استلام لقطة البيانات ← استبدال البيانات المحلية.
Future<void> joinGroupFromScan(
  BuildContext context,
  ProviderContainer container,
  PairingData data,
) async {
  // باركود دعوة سحابية؟ (دفعة 51) يمر عبر تدفق الموافقة الجديد:
  // تسمية الجهاز ← طلب انضمام ← انتظار موافقة المدير ← ترطيب نظيف.
  if (data.isCloud) {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => JoinApprovalScreen(
          prefillUrl: data.cloudUrl,
          prefillWs: data.ws.isEmpty ? 'default' : data.ws,
          prefillToken: data.tok,
        ),
      ),
    );
    return;
  }
  // 1) تأكيد صريح: الانضمام يمسح البيانات المحلية.
  final confirm = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('تأكيد الانضمام إلى المجموعة'),
      content: const Text(
        'سيتم حذف جميع البيانات المحلية في هذا الجهاز واستبدالها '
        'بنسخة كاملة من بيانات المجموعة على الجهاز المضيف.\n\n'
        'هذا الإجراء لا يمكن التراجع عنه.\n\nهل تريد المتابعة؟',
        style: TextStyle(height: 1.6),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('إلغاء'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Colors.red),
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('انضمام ومسح البيانات'),
        ),
      ],
    ),
  );
  if (confirm != true || !context.mounted) return;

  // 2) مؤشر تقدم أثناء الاقتران ونقل اللقطة.
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const AlertDialog(
      content: Row(
        children: [
          CircularProgressIndicator(),
          SizedBox(width: 16),
          Expanded(
            child: Text('جارٍ الربط ونقل البيانات من المضيف...',
                style: TextStyle(height: 1.5)),
          ),
        ],
      ),
    ),
  );

  String? failure;
  var gotSnapshot = false;
  try {
    final repo = container.read(repoProvider);
    final db = await repo.database;
    final st = await repo.settings();
    final ourPort =
        int.tryParse(st['lanSyncPort'] ?? '$kDefaultLanPort') ?? kDefaultLanPort;
    final ourId = await ensureDeviceId(repo);
    final lan = LanSyncService(
      repo: repo,
      dbProvider: () async => db,
      ourDeviceId: ourId,
      port: ourPort,
    );
    final result =
        await lan.pairWith(data.ip, data.port, data.tok, ourPort: ourPort);
    if (!result.ok) {
      failure = result.error ?? 'تأكد من الرمز والشبكة';
    } else if (result.snapshot != null) {
      await LanSyncService.applySnapshot(() async => db, ourId, result.snapshot!);
      gotSnapshot = true;
      // فعّل مزامنة LAN وأعد تشغيل المحرك بالحالة الجديدة (عضو).
      await repo.setSetting('lanSyncEnabled', '1');
      final engine = container.read(syncEngineProvider);
      engine.stop();
      await engine.start();
    }
  } catch (e) {
    failure = '$e';
  }

  if (!context.mounted) return;
  Navigator.of(context, rootNavigator: true).pop(); // أغلق مؤشر التقدم.

  if (failure != null) {
    Sfx.error();
    showSnack(context, '❌ فشل الانضمام: $failure', error: true);
    return;
  }
  if (!gotSnapshot) {
    Sfx.warning();
    showSnack(
      context,
      'تم الاقتران لكن تعذّر استلام نسخة البيانات — تأكد أن الجهازين '
      'على نفس شبكة Wi-Fi وأعد المحاولة.',
      error: true,
    );
    return;
  }
  Sfx.pair();
  container.read(refreshProvider.notifier).state++;
  showSnack(
    context,
    '✅ تم الانضمام إلى المجموعة واستلام نسخة البيانات كاملة. '
    'سيعين لك المدير الصلاحيات من شاشة إدارة المجموعة.',
  );
}
