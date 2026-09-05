// قسم "المزامنة والنسخ الاحتياطي" في الإعدادات.
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../data/providers.dart';
import '../data/repository.dart';
import '../data/sync/backup_service.dart';
import '../data/sync/device_id.dart';
import '../data/sync/google_auth_service.dart';
import '../data/sync/lan_http_transport.dart';
import '../data/sync/qr_pairing.dart';
import '../data/sync/sync_engine.dart';
import '../core/sfx.dart';
import '../data/sync/sync_service.dart';
import 'qr_pair_scanner.dart';

class SyncSettingsSection extends ConsumerStatefulWidget {
  const SyncSettingsSection({super.key});

  @override
  ConsumerState<SyncSettingsSection> createState() => _SyncSettingsSectionState();
}

class _SyncSettingsSectionState extends ConsumerState<SyncSettingsSection> {
  SyncStatusInfo? _info;
  String? _deviceId;
  GoogleUser? _googleUser;
  List<Map<String, Object?>> _pairedDevices = [];
  bool _busy = false;
  late TextEditingController _cloudUrlCtrl;
  late TextEditingController _lanPortCtrl;
  late TextEditingController _pairIpCtrl;
  late TextEditingController _pairTokenCtrl;
  late TextEditingController _pairTokenPortCtrl;
  bool _autoSync = true;
  bool _lanEnabled = true;

  @override
  @override
  void initState() {
    super.initState();
    _cloudUrlCtrl = TextEditingController();
    _lanPortCtrl = TextEditingController(text: '43053');
    _pairIpCtrl = TextEditingController();
    _pairTokenCtrl = TextEditingController();
    _pairTokenPortCtrl = TextEditingController(text: '43053');
    _refresh();
  }

  @override
  void dispose() {
    _cloudUrlCtrl.dispose();
    _lanPortCtrl.dispose();
    _pairIpCtrl.dispose();
    _pairTokenCtrl.dispose();
    _pairTokenPortCtrl.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    final repo = ref.read(repoProvider);
    _deviceId = await getDeviceIdCached(repo) ?? '';
    final db = await repo.database;
    final auth = GoogleAuthService(db);
    final gu = await auth.currentUserFromDb();
    final st = await repo.settings();
    _cloudUrlCtrl.text = st['cloudBackendUrl'] ?? '';
    _autoSync = (st['cloudAutoSync'] ?? '1') != '0';
    _lanEnabled = (st['lanSyncEnabled'] ?? '0') == '1';
    _lanPortCtrl.text = st['lanSyncPort'] ?? '43053';
    final engine = ref.read(syncEngineProvider);
    final svc = SyncService(repo: repo, engine: engine);
    final info = await svc.status();
    final paired = await db.query('devices',
        where: "is_paired = 1 AND ip_address <> ''",
        orderBy: 'last_seen_at DESC');
    if (!mounted) return;
    setState(() {
      _info = info;
      _googleUser = gu;
      _pairedDevices = paired;
    });
  }

  Future<String?> _localIp() async {
    try {
      for (final iface in await NetworkInterface.list(
          includeLoopback: false, type: InternetAddressType.IPv4)) {
        for (final a in iface.addresses) {
          if (!a.isLoopback && a.type == InternetAddressType.IPv4) return a.address;
        }
      }
    } catch (_) {}
    return null;
  }

  Future<void> _saveCloudConfig() async {
    setState(() => _busy = true);
    try {
      final url = _cloudUrlCtrl.text.trim();
      if (url.isNotEmpty) {
        final u = Uri.tryParse(url);
        if (u == null || !u.hasScheme || !u.isScheme('https')) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('⚠️ رابط Firebase غير صالح — يجب أن يبدأ بـ https://'),
              backgroundColor: Colors.orange,
            ),
          );
          return;
        }
      }
      final repo = ref.read(repoProvider);
      await repo.setSetting('cloudBackendUrl', url);
      await repo.setSetting('cloudAutoSync', _autoSync ? '1' : '0');
      final engine = ref.read(syncEngineProvider);
      if (engine.hasStarted) {
        try {
          await engine.reconfigureAll();
          await engine.forceSyncNow();
        } catch (e) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('⚠️ تعذر الاتصال بالسحابة: $e'), backgroundColor: Colors.orange),
          );
        }
      }
      bump(ref);
      await _refresh();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('✅ تم حفظ إعدادات المزامنة السحابية')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _signIn() async {
    setState(() => _busy = true);
    try {
      final repo = ref.read(repoProvider);
      final db = await repo.database;
      final res = await GoogleAuthService(db).signIn();
      if (!mounted) return;
      if (!res.ok) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(res.error ?? 'فشل'), backgroundColor: Colors.orange),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('✅ تم تسجيل الدخول: ${res.user?.email ?? ''}')),
        );
      }
      bump(ref);
      await _refresh();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _signOut() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('تسجيل الخروج'),
        content: const Text('لن يتم حذف البيانات المحلية. سيتم إيقاف المزامنة السحابية فقط.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('تسجيل الخروج')),
        ],
      ),
    );
    if (confirm != true) return;
    setState(() => _busy = true);
    try {
      final repo = ref.read(repoProvider);
      final db = await repo.database;
      await GoogleAuthService(db).signOut();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تم تسجيل الخروج')));
      bump(ref);
      await _refresh();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _createLocalBackup() async {
    setState(() => _busy = true);
    try {
      final repo = ref.read(repoProvider);
      final db = await repo.database;
      final svc = BackupService(db);
      final dir = await getApplicationDocumentsDirectory();
      final ts = DateTime.now().toIso8601String().replaceAll(':', '-').split('.').first;
      final f = File(p.join(dir.path, 'nexora-backup-$ts.nexora'));
      await svc.exportToFile(f);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('✅ تم حفظ النسخة الاحتياطية في:\n${f.path}')),
      );
      // Share option
      Share.shareXFiles([XFile(f.path)], text: 'نسخة نكسورا الاحتياطية');
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('❌ فشل النسخ الاحتياطي: $e'), backgroundColor: Colors.red),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _scanAndPair() async {
    final data = await scanQrPair(context);
    if (data == null || !mounted) return;
    _pairIpCtrl.text = data.ip;
    _pairTokenCtrl.text = data.tok;
    _pairTokenPortCtrl.text = '${data.port}';
    setState(() {});
    await _pairWithRemote();
  }

  Future<void> _removeDevice(String devId) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('إلغاء الجهاز'),
        content: const Text('سيتم رفض أي مزامنة قادمة من هذا الجهاز حتى تتم إعادة اقترانه. هل تريد المتابعة؟'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('إلغاء الجهاز'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    setState(() => _busy = true);
    try {
      final db = await ref.read(repoProvider).database;
      // نستخدم soft-revoke (set revoked_at) بدلاً من الحذف النهائي لتبقى الأثر ويُرفض الجهاز.
      await db.update('devices', {
        'revoked_at': DateTime.now().toIso8601String(),
        'is_paired': 0,
        'auth_secret': '',
        'updated_at': DateTime.now().toIso8601String(),
      }, where: 'id = ?', whereArgs: [devId]);
      bump(ref);
      await _refresh();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('✅ تم إلغاء الجهاز؛ لن تتم مزامنته بعد الآن')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveNetworkConfig() async {
    setState(() => _busy = true);
    try {
      final repo = ref.read(repoProvider);
      await repo.setSetting('lanSyncEnabled', _lanEnabled ? '1' : '0');
      await repo.setSetting('lanSyncPort', _lanPortCtrl.text.trim());
      final engine = ref.read(syncEngineProvider);
      if (engine.hasStarted) {
        await engine.reconfigureAll();
      }
      bump(ref);
      await _refresh();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_lanEnabled
            ? '✅ تم تشغيل خادم المزامنة المحلي على المنفذ ${_lanPortCtrl.text}'
            : '✅ تم إيقاف خادم المزامنة المحلي')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _ensureCanHost() async {
    final repo = ref.read(repoProvider);
    final mode = await repo.workspaceMode();
    final isOwner = await repo.isWorkspaceOwner();
    if (mode == 'member' || !isOwner) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('لا يمكنك إنشاء رمز اقتران لأنك عضو في مجموعة وليس مديراً.'),
            backgroundColor: Colors.red,
          ),
        );
      }
      return false;
    }
    return true;
  }

  Future<void> _createPairQr() async {
    if (!await _ensureCanHost()) return;
    setState(() => _busy = true);
    try {
      final repo = ref.read(repoProvider);
      final db = await repo.database;
      final wsId = (await repo.settings())['sync.workspaceId'] ?? 'default';
      final port = int.tryParse(_lanPortCtrl.text.trim()) ?? 43053;
      final ip = await _localIp();
      final ourId = await ensureDeviceId(repo);
      // تأكد من وجود سجل الجهاز في devices (لضمان وجود port/auth_secret).
      final devRows = await db.query('devices', where: 'id = ?', whereArgs: [ourId], limit: 1);
      if (devRows.isEmpty) {
        final now = DateTime.now().toIso8601String();
        await db.insert('devices', {
          'id': ourId,
          'workspace_id': wsId,
          'name': 'جهاز نكسورا',
          'platform': Platform.operatingSystem,
          'port': port,
          'is_paired': 1,
          'auth_secret': '',
          'revoked_at': '',
          'ip_address': ip ?? '',
          'created_at': now,
          'updated_at': now,
        });
      }
      final svc = QrPairingService(db: db, ourDeviceId: ourId);
      final info = await svc.createPairingToken(
        workspaceId: wsId,
        port: port,
        ipAddress: ip,
      );
      _pairTokenCtrl.text = info.token;
      _pairIpCtrl.text = ip ?? '';
      if (!mounted) return;
      setState(() {});
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('رمز الاقتران'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('QR Content (امسحه بالجهاز الآخر عبر زر مسح QR):'),
              const SizedBox(height: 8),
              SelectableText(
                info.qrContent,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
              ),
              const SizedBox(height: 8),
              Text('ينتهي في: ${info.expiresAt.toLocal().toString().split('.').first}',
                  style: const TextStyle(color: Colors.grey, fontSize: 11)),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إغلاق')),
          ],
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pairWithRemote() async {
    setState(() => _busy = true);
    try {
      final ip = _pairIpCtrl.text.trim();
      final hostPort = int.tryParse(_pairTokenPortCtrl.text.trim()) ?? 43053;
      final ourPort = int.tryParse(_lanPortCtrl.text.trim()) ?? kDefaultLanPort;
      final tok = _pairTokenCtrl.text.trim();
      if (ip.isEmpty || tok.isEmpty) {
        Sfx.reject();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('أدخل IP ورمز الاقتران')),
        );
        return;
      }
      final repo = ref.read(repoProvider);
      final db = await repo.database;
      final ourId = await ensureDeviceId(repo);
      final lan = LanSyncService(
        repo: repo,
        dbProvider: () async => db,
        ourDeviceId: ourId,
        port: ourPort,
      );
      // تحذير للمستخدم قبل الانضمام: سيتم مسح البيانات المحلية.
      final confirmJoin = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('تأكيد الانضمام إلى المجموعة'),
          content: const Text(
            'سيتم حذف جميع البيانات والسجلات المحلية في هذا الجهاز '
            'واستبدالها بنسخة كاملة من بيانات المجموعة على الجهاز المضيف.\n\n'
            'هذا الإجراء لا يمكن التراجع عنه.\n\n'
            'هل تريد المتابعة؟',
            style: TextStyle(height: 1.6),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('إلغاء')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('انضمام ومسح البيانات'),
            ),
          ],
        ),
      );
      if (confirmJoin != true) return;

      final result = await lan.pairWith(ip, hostPort, tok, ourPort: ourPort);
      if (!mounted) return;
      if (!result.ok) {
        Sfx.error();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('❌ فشل الربط: ${result.error ?? "تأكد من الرمز والشبكة"}'),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }

      // بعد الاقتران نستبدل البيانات المحلية بلقطة المضيف.
      if (result.snapshot != null) {
        try {
          await LanSyncService.applySnapshot(() async => db, ourId, result.snapshot!);
        } catch (e) {
          if (mounted) {
            Sfx.error();
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('تم الربط لكن تعذر نسخ البيانات: $e'),
                backgroundColor: Colors.red,
              ),
            );
            return;
          }
        }
      }
      if (mounted) {
        if (result.snapshot == null) {
          Sfx.warning();
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'تم الاقتران ✅ لكن تعذّر استلام نسخة البيانات من المضيف. '
                'تأكد من أن كلا الجهازين على نفس شبكة Wi-Fi وأعد المحاولة.',
              ),
              backgroundColor: Colors.orange,
              duration: Duration(seconds: 5),
            ),
          );
        } else {
          Sfx.pair(); // نمط احتفالي عند نجاح الانضمام الكامل.
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                '✅ تم الانضمام إلى المجموعة وحُذفت البيانات المحلية واستُبدلت بنسخة المضيف.\n'
                'أنت الآن عضو؛ سيقوم المدير بتعيين صلاحياتك من شاشة إدارة الأجهزة.',
              ),
              duration: Duration(seconds: 4),
            ),
          );
        }
        bump(ref);
        await Future.delayed(const Duration(milliseconds: 300));
        if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ملاحظة: لم يعد الأعضاء قادرين على الخروج من المجموعة من تلقاء أنفسهم (زر الخروج استُبدل برسالة إرشادية).
  // الخروج ممكن فقط بطرد المدير للجهاز، أو بحذف التطبيق.


  Future<void> _restoreBackup() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('تأكيد استعادة نسخة احتياطية'),
        content: const Text(
          'سيتم استبدال البيانات الحالية بمحتوى النسخة المختارة.\n'
          'ننصح بإنشاء نسخة احتياطية حالية قبل المتابعة.\n\n'
          'هل تريد المتابعة؟',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('استعادة')),
        ],
      ),
    );
    if (confirm != true) return;

    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['nexora', 'json'],
    );
    if (picked == null || picked.files.isEmpty) return;
    final path = picked.files.single.path;
    if (path == null) return;

    setState(() => _busy = true);
    try {
      // في المرحلة الحالية: إعادة تشغيل التطبيق مطلوبة بعد استعادة كاملة لأن
      // الـ database مفتوحة بالفعل. نعرض رسالة تطلب إعادة التشغيل.
      final repo = ref.read(repoProvider);
      final db = await repo.database;
      final svc = BackupService(db);
      final counts = await svc.inspect(File(path));
      if (!mounted) return;
      final summary = counts.entries.map((e) => '• ${e.key}: ${e.value}').join('\n');
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('النسخة تحتوي على:'),
          content: Text('$summary\n\nسيتم إغلاق التطبيق بعد الاستعادة. أعد تشغيله يدويًا.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')),
            FilledButton(onPressed: () async {
              Navigator.pop(ctx);
              // نُعيد هنا فقط للسجل؛ الاستعادة الكاملة ستُنفذ في مرحلة لاحقة.
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                content: Text('⚠️ تم تحضير النسخة. سيتم دعم الاستعادة الكاملة آليًا في التحديث القادم.'),
              ));
            }, child: const Text('متابعة')),
          ],
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('❌ $e'), backgroundColor: Colors.red),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _syncNow() async {
    setState(() => _busy = true);
    try {
      final engine = ref.read(syncEngineProvider);
      await engine.forceSyncNow();
      await _refresh();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('🔄 جرت محاولة المزامنة الآن')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final info = _info;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(4, 18, 0, 8),
          child: Text('المزامنة والنسخ الاحتياطي',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                Row(
                  children: [
                    const Icon(Icons.devices, size: 20),
                    const SizedBox(width: 8),
                    Expanded(child: Text('معرّف الجهاز: $_deviceId')),
                  ],
                ),
                const Divider(height: 20),
                Row(
                  children: [
                    const Icon(Icons.cloud, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        info == null
                            ? '...'
                            : switch (info.state) {
                                SyncState.synced => '🟢 متزامن',
                                SyncState.syncing => '🟡 جاري المزامنة',
                                SyncState.pending => '🟠 عمليات معلقة (${info.pending})',
                                SyncState.failed => '🔴 فشل (${info.failed})',
                                SyncState.offline => '⚪ المزامنة السحابية غير مُفعّلة',
                              },
                      ),
                    ),
                  ],
                ),
                if (info != null && info.lastSyncAt != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text('آخر مزامنة: ${info.lastSyncAt}',
                          style: const TextStyle(fontSize: 12, color: Colors.grey)),
                    ),
                  ),
                const SizedBox(height: 10),
                // جلسة Google
                const Divider(height: 12),
                if (_googleUser != null)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.account_circle_outlined),
                    title: Text(_googleUser!.displayName?.isNotEmpty == true
                        ? _googleUser!.displayName!
                        : _googleUser!.email),
                    subtitle: Text(_googleUser!.email),
                    trailing: TextButton.icon(
                      onPressed: _busy ? null : _signOut,
                      icon: const Icon(Icons.logout, size: 16),
                      label: const Text('خروج'),
                    ),
                  )
                else
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.login),
                    title: const Text('تسجيل الدخول بحساب Google'),
                    subtitle: Text(
                      isPlatformSupportingGoogleSignIn()
                          ? 'لربط Workspace وتمكين المزامنة السحابية بين الأجهزة'
                          : 'متاح على أندرويد فقط في هذه المرحلة',
                    ),
                    trailing: FilledButton.icon(
                      onPressed: _busy || !isPlatformSupportingGoogleSignIn() ? null : _signIn,
                      icon: const Icon(Icons.login, size: 16),
                      label: const Text('دخول'),
                    ),
                  ),
                const Divider(height: 12),
                // إعدادات Cloud
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 6),
                  child: Text('المزامنة السحابية (Firebase)',
                      style: TextStyle(fontWeight: FontWeight.w700)),
                ),
                TextField(
                  controller: _cloudUrlCtrl,
                  enabled: !_busy,
                  decoration: const InputDecoration(
                    labelText: 'رابط قاعدة البيانات السحابية',
                    hintText: 'https://my-project-default-rtdb.firebaseio.com',
                    prefixIcon: Icon(Icons.cloud_outlined),
                    isDense: true,
                  ),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('مزامنة تلقائية'),
                  subtitle: const Text('رفع العمليات الجديدة للسحابة عند توفر الإنترنت'),
                  value: _autoSync,
                  onChanged: _busy
                      ? null
                      : (v) => setState(() => _autoSync = v),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : _saveCloudConfig,
                    icon: const Icon(Icons.save, size: 16),
                    label: const Text('حفظ ومزامنة الآن'),
                  ),
                ),
                if (_info?.cloudConfigured != true && _cloudUrlCtrl.text.trim().isEmpty)
                  const Padding(
                    padding: EdgeInsets.only(top: 6),
                    child: Text(
                      'حتى تُفعَّل المزامنة السحابية: أنشئ مشروع Firebase، فعّل Realtime Database، والصق رابط القاعدة هنا.',
                      style: TextStyle(fontSize: 11, color: Colors.grey),
                    ),
                  ),
                const Divider(height: 12),
                // LAN Sync
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 6),
                  child: Text('المزامنة المحلية (شبكة Wi-Fi نفسها)',
                      style: TextStyle(fontWeight: FontWeight.w700)),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('تشغيل خادم المزامنة المحلي'),
                  subtitle: const Text('يسمح للأجهزة على نفس الشبكة بالاتصال بهذا الجهاز'),
                  value: _lanEnabled,
                  onChanged: _busy ? null : (v) => setState(() => _lanEnabled = v),
                ),
                Row(children: [
                  Expanded(
                    child: TextField(
                      controller: _lanPortCtrl,
                      enabled: !_busy,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'المنفذ المحلي',
                        prefixIcon: Icon(Icons.router_outlined),
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _saveNetworkConfig,
                    icon: const Icon(Icons.save, size: 16),
                    label: const Text('حفظ'),
                  ),
                ]),
                const SizedBox(height: 6),
                Text(
                  'IP المحلي: ${(Uri.base.scheme == "file") ? "(يعرض وقت التشغيل)" : "—"}',
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                ),
                const SizedBox(height: 8),
                // QR Pairing (يُعطّل تلقائياً للأعضاء الذين لا يمكنهم استضافة مجموعات).
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: const EdgeInsets.only(bottom: 8),
                  title: const Text('ربط جهاز جديد عبر QR'),
                  leading: const Icon(Icons.qr_code_2_outlined),
                  children: [
                    Row(children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _busy ? null : _createPairQr,
                          icon: const Icon(Icons.qr_code, size: 16),
                          label: const Text('إنشاء QR للاقتران'),
                        ),
                      ),
                    ]),
                    if (_pairIpCtrl.text.isNotEmpty || _pairTokenCtrl.text.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: SelectableText(
                          'IP: ${_pairIpCtrl.text}   منفذ المضيف: ${_pairTokenPortCtrl.text}   الرمز: ${_pairTokenCtrl.text}',
                          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                        ),
                      ),
                    const Divider(height: 16),
                    Row(children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _busy ? null : _scanAndPair,
                          icon: const Icon(Icons.camera_alt, size: 16),
                          label: const Text('مسح QR بالكاميرا وربط'),
                        ),
                      ),
                    ]),
                    const SizedBox(height: 8),
                    const Text('أو أدخل بيانات الجهاز الرئيسي يدويًا:'),
                    Row(children: [
                      Expanded(
                        flex: 3,
                        child: TextField(
                          controller: _pairIpCtrl,
                          enabled: !_busy,
                          decoration: const InputDecoration(
                            labelText: 'IP الجهاز الرئيسي',
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      SizedBox(
                        width: 80,
                        child: TextField(
                          controller: _pairTokenPortCtrl,
                          enabled: !_busy,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'المنفذ',
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        flex: 2,
                        child: TextField(
                          controller: _pairTokenCtrl,
                          enabled: !_busy,
                          decoration: const InputDecoration(
                            labelText: 'الرمز',
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      FilledButton(
                        onPressed: _busy ? null : _pairWithRemote,
                        child: const Text('ربط'),
                      ),
                    ]),
                  ],
                ),
                if (_pairedDevices.isNotEmpty) ...[
                  const Divider(height: 16),
                  const Align(
                    alignment: Alignment.centerRight,
                    child: Text('الأجهزة المقترنة:', style: TextStyle(fontWeight: FontWeight.w700)),
                  ),
                  const SizedBox(height: 6),
                  ...List.generate(_pairedDevices.length, (i) {
                    final d = _pairedDevices[i];
                    final name = (d['name'] as String?) ?? 'جهاز';
                    final ip = (d['ip_address'] as String?) ?? '';
                    final port = (d['port'] as int?) ?? 43053;
                    final devId = (d['id'] as String?) ?? '';
                    final lastSeen = (d['last_seen_at'] as String?) ?? '';
                    final isSelf = devId == _deviceId;
                    return Card(
                      margin: const EdgeInsets.symmetric(vertical: 3),
                      child: ListTile(
                        dense: true,
                        leading: const Icon(Icons.devices),
                        title: Text('$name ${isSelf ? "(هذا الجهاز)" : ""}'),
                        subtitle: Text('$ip:$port${lastSeen.isNotEmpty ? " — آخر ظهور: ${lastSeen.substring(0,16)}" : ""}',
                            style: const TextStyle(fontSize: 11)),
                        trailing: isSelf ? null : IconButton(
                          icon: const Icon(Icons.delete_outline, color: Colors.red),
                          onPressed: _busy ? null : () => _removeDevice(devId),
                        ),
                      ),
                    );
                  }),
                ],
                const Divider(height: 12),
                // ملاحظة للأعضاء: لا يمكن الخروج من المجموعة إلا بطرد المدير.
                Consumer(builder: (ctx, rref, _) {
                  final modeAsync = rref.watch(workspaceModeProvider);
                  final mode = modeAsync.valueOrNull ?? 'standalone';
                  if (mode != 'member') return const SizedBox.shrink();
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.amber.withOpacity(.12),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: Colors.amber.withOpacity(.3)),
                      ),
                      child: const Row(children: [
                        Icon(Icons.info_outline, size: 18, color: Colors.orange),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'أنت عضو في هذه المجموعة. لا يمكن الخروج إلا بطرد المدير، '
                            'أو بحذف التطبيق وإعادة تثبيته.',
                            style: TextStyle(fontSize: 11, height: 1.4),
                          ),
                        ),
                      ]),
                    ),
                  );
                }),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _syncNow,
                    icon: const Icon(Icons.sync, size: 18),
                    label: const Text('مزامنة الآن'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _createLocalBackup,
                    icon: const Icon(Icons.save_alt, size: 18),
                    label: const Text('نسخة احتياطية محلية'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _restoreBackup,
                    icon: const Icon(Icons.restore, size: 18),
                    label: const Text('استعادة نسخة'),
                  ),
                ]),
                const Padding(
                  padding: EdgeInsets.only(top: 10),
                  child: Text(
                    'ملاحظة: QR للاقتران يُظهر رمزًا مؤقتًا (5 دقائق) ولا يحتوي أسرارًا دائمة. يتطلب كاميرا لمسح QR على الجهاز الآخر.',
                    style: TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
