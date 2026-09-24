// تطبيق المدير المستقل — لوحة تفعيل تراخيص Nexora (مالك النظام فقط).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:url_launcher/url_launcher.dart';

import 'rtdb.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('ar');
  await Rtdb.instance.load();
  runApp(const AdminApp());
}

/// (إصلاح 2026-09-23) نبضة تحديث عامة: كل تفعيل/تمديد يُبلغ شاشة
/// «سجل المشتركين» فتُعيد التحميل — كانت الشاشة تُبنى مرة واحدة عند الإقلاع
/// فتظل قائمتها قديمة بعد كل تفعيل جديد (يبدو كأن التفعيل لم يُسجَّل).
final ValueNotifier<int> adminRefreshTick = ValueNotifier<int>(0);

class AdminApp extends StatelessWidget {
  const AdminApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'مدير التراخيص — Nexora',
      debugShowCheckedModeBanner: false,
      locale: const Locale('ar'),
      builder: (context, child) =>
          Directionality(textDirection: TextDirection.rtl, child: child!),
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF7C3AED),
        fontFamily: 'Roboto',
        inputDecorationTheme: InputDecorationTheme(
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          isDense: true,
        ),
      ),
      home: const HomeScreen(),
    );
  }
}

String fmtDate(int ms, {bool lifetime = false}) {
  if (lifetime || ms > DateTime(2090).millisecondsSinceEpoch) return 'دائم ∞';
  if (ms <= 0) return '—';
  return DateFormat('yyyy/MM/dd — hh:mm a', 'ar')
      .format(DateTime.fromMillisecondsSinceEpoch(ms));
}

/// نسخ نص إلى الحافظة مع إشعار خفيف — يُستخدم لمعرفات المساحات والأجهزة
/// (المالك ينسخها من رسائل الواتساب ويبحث بها).
Future<void> copyText(BuildContext context, String label, String value) async {
  if (value.isEmpty) return;
  await Clipboard.setData(ClipboardData(text: value));
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text('نُسخ $label ✓'), behavior: SnackBarBehavior.floating),
  );
}

/// فتح تطبيق الهاتف للاتصال المباشر برقم العميل.
Future<void> callPhone(BuildContext context, String phone) async {
  final clean = phone.replaceAll(RegExp(r'[\s\-\(\)]'), '');
  if (clean.isEmpty) return;
  final uri = Uri.parse('tel:$clean');
  try {
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    } else {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تعذّر فتح تطبيق الهاتف: $e')),
      );
    }
  }
}

/// فتح تطبيق واتساب لمراسلة العميل بنقرة واحدة.
Future<void> openWhatsApp(BuildContext context, String phone,
    {String? msg}) async {
  final clean = phone.replaceAll(RegExp(r'[^0-9]'), '');
  if (clean.isEmpty) return;
  final text = msg != null ? Uri.encodeComponent(msg) : '';
  final direct = Uri.parse('whatsapp://send?phone=$clean&text=$text');
  final web = Uri.parse('https://wa.me/$clean?text=$text');
  try {
    if (await canLaunchUrl(direct)) {
      if (await launchUrl(direct, mode: LaunchMode.externalApplication)) return;
    }
  } catch (_) {}
  try {
    if (await launchUrl(web, mode: LaunchMode.externalApplication)) return;
  } catch (_) {}
  try {
    await launchUrl(web);
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تعذّر فتح تطبيق واتساب: $e')),
      );
    }
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('🔑 مدير التراخيص',
            style: TextStyle(fontWeight: FontWeight.w800)),
        actions: [
          IconButton(
            tooltip: 'إعدادات الاتصال بقاعدة البيانات',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () async {
              await showDialog<void>(
                  context: context, builder: (_) => const _ConfigDialog());
              if (mounted) setState(() {});
            },
          ),
        ],
      ),
      body: IndexedStack(
        index: _tab,
        children: const [ActivationScreen(), SubscribersScreen()],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(
              icon: Icon(Icons.verified_outlined),
              selectedIcon: Icon(Icons.verified),
              label: 'تفعيل حساب'),
          NavigationDestination(
              icon: Icon(Icons.people_outline),
              selectedIcon: Icon(Icons.people),
              label: 'سجل المشتركين'),
        ],
      ),
    );
  }
}

// ==================== إعدادات الاتصال ====================

class _ConfigDialog extends StatefulWidget {
  const _ConfigDialog();
  @override
  State<_ConfigDialog> createState() => _ConfigDialogState();
}

class _ConfigDialogState extends State<_ConfigDialog> {
  late final _url = TextEditingController(text: Rtdb.instance.baseUrl);
  late final _auth = TextEditingController(text: Rtdb.instance.authToken);
  late final _admin = TextEditingController(
      text: Rtdb.instance.adminRefreshToken);
  bool _busy = false;

  @override
  void dispose() {
    // (إصلاح) إفلات المتحكمات — كانت تُترك معلّقة بعد كل فتح للحوار.
    _url.dispose();
    _auth.dispose();
    _admin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('⚙️ الاتصال بقاعدة البيانات'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _url,
            textDirection: TextDirection.ltr,
            decoration: const InputDecoration(
              labelText: 'رابط Firebase RTDB',
              hintText: kOfficialRtdbUrl,
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _auth,
            textDirection: TextDirection.ltr,
            decoration: const InputDecoration(
              labelText: 'مفتاح المصادقة (اختياري)',
              hintText: 'تلقائي — هوية مجهولة تُنشأ عند الحاجة',
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _admin,
            textDirection: TextDirection.ltr,
            maxLines: 2,
            minLines: 1,
            decoration: const InputDecoration(
              labelText: 'رمز هوية المدير (اختياري الآن — لازم بعد التشديد)',
              hintText: 'AMf-uB… (يُلصق مرة واحدة)',
              prefixIcon: Icon(Icons.admin_panel_settings_outlined),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            Rtdb.instance.adminUid.isEmpty
                ? 'بدونه يعمل التطبيق بهوية مجهولة (قراءة فقط بعد تشديد '
                    'قواعد قاعدة البيانات).'
                : 'الهوية الحالية: ${Rtdb.instance.adminUid}',
            style: const TextStyle(fontSize: 11, color: Colors.grey),
          ),
          const SizedBox(height: 6),
          const Text(
            'نفس الرابط المستخدم في تطبيق مدير الحسابات — '
            'الرابط وهوية المدير يُحفظان محلياً على هذا الهاتف فقط.',
            style: TextStyle(fontSize: 11, color: Colors.grey),
          ),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('إلغاء')),
        FilledButton(
          onPressed: _busy
              ? null
              : () async {
                  setState(() => _busy = true);
                  await Rtdb.instance.save(_url.text, _auth.text);
                  await Rtdb.instance.saveAdminRefreshToken(_admin.text);
                  if (!context.mounted) return;
                  Navigator.pop(context);
                },
          child: const Text('حفظ'),
        ),
      ],
    );
  }
}

// ==================== بطاقات الإحصائيات ====================

class MetricsBoard extends StatefulWidget {
  const MetricsBoard({super.key});
  @override
  State<MetricsBoard> createState() => _MetricsBoardState();
}

class _MetricsBoardState extends State<MetricsBoard> {
  AdminMetrics? _m;
  bool _busy = false;
  String _err = '';

  @override
  void initState() {
    super.initState();
    _load(); // تلقائياً فور فتح التطبيق.
    // (إصلاح) تحديث الأرقام بعد كل تفعيل/تمديد بدل انتظار إعادة الفتح.
    adminRefreshTick.addListener(_load);
  }

  @override
  void dispose() {
    adminRefreshTick.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    if (!Rtdb.instance.configured || _busy) return;
    if (!mounted) return;
    setState(() {
      _busy = true;
      _err = '';
    });
    try {
      final m = await Rtdb.instance.metrics();
      if (mounted) setState(() => _m = m);
    } catch (e) {
      if (mounted) setState(() => _err = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _card(String title, String emoji, int? value, Color color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 6),
        decoration: BoxDecoration(
          color: color.withValues(alpha: .08),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: color.withValues(alpha: .25)),
        ),
        child: Column(
          children: [
            Text(emoji, style: const TextStyle(fontSize: 18)),
            const SizedBox(height: 4),
            value == null
                ? SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: color))
                : Text('$value',
                    style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w900,
                        color: color)),
            const SizedBox(height: 2),
            Text(title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 10.5, fontWeight: FontWeight.w700)),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!Rtdb.instance.configured) return const SizedBox.shrink();
    final m = _m;
    return Column(
      children: [
        Row(
          children: [
            const Text('📊 نظرة عامة',
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
            const Spacer(),
            IconButton(
              tooltip: 'تحديث الأرقام',
              visualDensity: VisualDensity.compact,
              icon: _busy
                  ? const SizedBox(
                      width: 15,
                      height: 15,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.refresh, size: 18),
              onPressed: _busy ? null : _load,
            ),
          ],
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            _card('إجمالي المساحات', '📱', m?.totalWorkspaces,
                const Color(0xFF2563EB)),
            const SizedBox(width: 7),
            _card('مشتركون مدفوعون', '💎', m?.activePaid,
                const Color(0xFF16A34A)),
            const SizedBox(width: 7),
            _card('فترة تجريبية', '⏳', m?.activeTrials,
                const Color(0xFFEA580C)),
            const SizedBox(width: 7),
            _card('منتهية / مجانية', '🔒', m?.expired,
                const Color(0xFFDC2626)),
          ],
        ),
        // الفرق بين الإجمالي ومجموع البطاقات كان يبدو كخطأ في الأرقام:
        // نوضّح صراحةً أن باقي المساحات لم تبدأ تجربة أصلاً.
        if (m != null && m.noPlan > 0)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'منها ${m.noPlan} مساحة بلا اشتراك بعد (لم تُفعّل تجربة).',
              style: const TextStyle(fontSize: 10.5, color: Colors.grey),
            ),
          ),
        if (_err.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text('تعذّر تحميل الإحصائيات: $_err',
                style: const TextStyle(fontSize: 11, color: Color(0xFFDC2626))),
          ),
        const SizedBox(height: 14),
      ],
    );
  }
}

// ==================== شاشة التفعيل ====================

class ActivationScreen extends StatefulWidget {
  const ActivationScreen({super.key});
  @override
  State<ActivationScreen> createState() => _ActivationScreenState();
}

class _ActivationScreenState extends State<ActivationScreen> {
  final _id = TextEditingController();
  final _storeName = TextEditingController();
  final _clientName = TextEditingController();
  final _phone = TextEditingController();
  final _licenseKey = TextEditingController();

  String _plan = 'individual';
  PlanDuration _duration = PlanDuration.month;
  final _seats = TextEditingController(text: '5');
  bool _busy = false;
  bool _lookingUp = false;

  @override
  void dispose() {
    _id.dispose();
    _storeName.dispose();
    _clientName.dispose();
    _phone.dispose();
    _licenseKey.dispose();
    _seats.dispose();
    super.dispose();
  }

  Future<void> _lookupClientData() async {
    final input = _id.text.trim();
    if (input.isEmpty) return;
    setState(() => _lookingUp = true);
    try {
      final rtdb = Rtdb.instance;
      // 1) فحص /trials
      final trials = await rtdb.getJson('trials');
      if (trials is Map) {
        for (final v in trials.values) {
          if (v is! Map) continue;
          final match = asStr(v['device_id']).toLowerCase() == input.toLowerCase() ||
              asStr(v['deviceId']).toLowerCase() == input.toLowerCase() ||
              asStr(v['licenseKey']).toLowerCase() == input.toLowerCase() ||
              asStr(v['workspace_id']).toLowerCase() == input.toLowerCase();
          if (match) {
            if (_storeName.text.isEmpty) {
              _storeName.text = asStr(v['storeName'] ?? v['store_name']);
            }
            if (_clientName.text.isEmpty) {
              _clientName.text = asStr(v['clientName'] ?? v['client_name']);
            }
            if (_phone.text.isEmpty) {
              _phone.text = asStr(v['phone'] ?? v['whatsapp']);
            }
            if (_licenseKey.text.isEmpty) {
              _licenseKey.text = asStr(v['licenseKey'] ?? v['license_key']);
            }
            break;
          }
        }
      }

      // 2) فحص عقدة subscription إن عرفنا المساحة
      try {
        final ws = await rtdb.resolveWorkspaceId(input);
        final enc = Uri.encodeComponent(ws);
        final sub = await rtdb.getJson('workspaces/$enc/subscription');
        if (sub is Map) {
          if (_storeName.text.isEmpty) {
            _storeName.text = asStr(sub['storeName'] ?? sub['store_name']);
          }
          if (_clientName.text.isEmpty) {
            _clientName.text = asStr(sub['clientName'] ?? sub['client_name']);
          }
          if (_phone.text.isEmpty) {
            _phone.text = asStr(sub['phone'] ?? sub['whatsapp']);
          }
          if (_licenseKey.text.isEmpty) {
            _licenseKey.text = asStr(sub['licenseKey'] ?? sub['license_key']);
          }
        }
      } catch (_) {}

      if (_licenseKey.text.isEmpty && input.isNotEmpty) {
        _licenseKey.text = generateLicenseKey(input);
      }
      if (mounted) setState(() {});
    } catch (_) {
    } finally {
      if (mounted) setState(() => _lookingUp = false);
    }
  }

  Future<void> _activate() async {
    final rtdb = Rtdb.instance;
    if (!rtdb.configured) {
      _snack('اضبط رابط قاعدة البيانات أولاً من ⚙️ الإعدادات', error: true);
      return;
    }
    final input = _id.text.trim();
    if (input.isEmpty) {
      _snack('ألصق معرف الجهاز أو بصمة التفعيل أولاً', error: true);
      return;
    }
    final seats = int.tryParse(_seats.text.trim()) ?? 0;
    if (_plan == 'enterprise' && seats < 2) {
      _snack('حدد سعة أجهزة صحيحة (2 فأكثر) لباقة المؤسسات', error: true);
      return;
    }
    setState(() => _busy = true);
    try {
      final r = await rtdb.activate(
        rawInput: input,
        planType: _plan,
        duration: _duration,
        maxDevices: seats,
        clientName: _clientName.text.trim(),
        storeName: _storeName.text.trim(),
        phone: _phone.text.trim(),
        licenseKey: _licenseKey.text.trim().isNotEmpty
            ? _licenseKey.text.trim()
            : null,
      );
      if (!mounted) return;
      // السجل والإحصائيات يتجددان فوراً بعد التفعيل.
      adminRefreshTick.value++;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: const Icon(Icons.check_circle,
              color: Color(0xFF16A34A), size: 52),
          title: const Text('✅ تم التفعيل بنجاح',
              style: TextStyle(color: Color(0xFF16A34A))),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (r.storeName.isNotEmpty) _row('اسم المنشأة', r.storeName),
                if (r.clientName.isNotEmpty) _row('اسم المسؤول', r.clientName),
                if (r.phone.isNotEmpty) _row('رقم الهاتف', r.phone),
                _row('كود الترخيص', r.licenseKey),
                if (r.deviceId.isNotEmpty) _row('معرف الجهاز', r.deviceId),
                _row('مساحة العمل', r.workspaceId),
                _row('الخطة',
                    r.planType == 'enterprise' ? 'مؤسسة 🏢' : 'فردي 👤'),
                if (r.planType == 'enterprise')
                  _row('سعة الأجهزة', '${r.maxDevices} أجهزة'),
                _row('ينتهي في', fmtDate(r.expiresAtMs, lifetime: r.lifetime)),
                const SizedBox(height: 8),
                const Text(
                  'سيلمس العميل التفعيل فوراً عند ضغطه «تأكيد عملية الشراء» '
                  'أو خلال دقائق تلقائياً — دون مسح بيانات.',
                  style: TextStyle(fontSize: 12, height: 1.6),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => copyText(context, 'كود الترخيص', r.licenseKey),
              child: const Text('نسخ الترخيص'),
            ),
            TextButton(
              onPressed: () => copyText(context, 'معرف المساحة', r.workspaceId),
              child: const Text('نسخ المساحة'),
            ),
            FilledButton(
                onPressed: () => Navigator.pop(ctx), child: const Text('تم')),
          ],
        ),
      );
      if (!mounted) return;
      _id.clear();
      _storeName.clear();
      _clientName.clear();
      _phone.clear();
      _licenseKey.clear();
    } catch (e) {
      _snack('$e', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _row(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          Text('$k: ', style: const TextStyle(fontWeight: FontWeight.w800)),
          Expanded(child: Text(v, textDirection: TextDirection.ltr)),
        ]),
      );

  void _snack(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor:
          error ? const Color(0xFFDC2626) : const Color(0xFF16A34A),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // 📊 البطاقات الإحصائية — تُحمَّل تلقائياً فور فتح التطبيق.
        const MetricsBoard(),
        if (!Rtdb.instance.configured)
          Card(
            color: const Color(0xFFFFF7ED),
            child: ListTile(
              leading: const Icon(Icons.warning_amber, color: Color(0xFFEA580C)),
              title: const Text('لم يُضبط الاتصال بعد',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14)),
              subtitle: const Text('اضغط ⚙️ أعلى الشاشة وألصق رابط RTDB.'),
            ),
          ),
        const SizedBox(height: 4),
        const Text('1️⃣ هوية العميل والمنشأة',
            style: TextStyle(fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        TextField(
          controller: _id,
          textDirection: TextDirection.ltr,
          onChanged: (_) {
            if (_id.text.isNotEmpty && _licenseKey.text.isEmpty) {
              _licenseKey.text = generateLicenseKey(_id.text);
            }
          },
          decoration: InputDecoration(
            labelText: 'معرف الجهاز / بصمة التفعيل / معرف مساحة العمل',
            hintText: 'ألصق ما وصلك في رسالة واتساب من العميل',
            prefixIcon: const Icon(Icons.fingerprint),
            suffixIcon: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: 'جلب بيانات العميل المسجلة',
                  icon: _lookingUp
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.download_outlined, size: 20),
                  onPressed: _lookingUp ? null : _lookupClientData,
                ),
                IconButton(
                  tooltip: 'مسح',
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () => _id.clear(),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _storeName,
                decoration: const InputDecoration(
                  labelText: 'اسم المنشأة / المحل',
                  hintText: 'مثال: مركز الأمل التجاري',
                  prefixIcon: Icon(Icons.storefront_outlined),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _clientName,
                decoration: const InputDecoration(
                  labelText: 'اسم العميل / المسؤول',
                  hintText: 'مثال: أحمد علي',
                  prefixIcon: Icon(Icons.person_outline),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _phone,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(
                  labelText: 'رقم الهاتف / الواتساب',
                  hintText: 'مثال: 771234567',
                  prefixIcon: Icon(Icons.phone_outlined),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _licenseKey,
                textDirection: TextDirection.ltr,
                decoration: const InputDecoration(
                  labelText: 'كود الترخيص',
                  hintText: 'NX-XXXX-XXXX',
                  prefixIcon: Icon(Icons.key_outlined),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 18),
        const Text('2️⃣ نوع الخطة',
            style: TextStyle(fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(
                value: 'individual',
                label: Text('👤 مستخدم فردي'),
                icon: Icon(Icons.person_outline)),
            ButtonSegment(
                value: 'enterprise',
                label: Text('🏢 مؤسسة / مجموعة'),
                icon: Icon(Icons.business_outlined)),
          ],
          selected: {_plan},
          onSelectionChanged: (s) => setState(() => _plan = s.first),
        ),
        if (_plan == 'enterprise') ...[
          const SizedBox(height: 12),
          TextField(
            controller: _seats,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'سعة الأجهزة (max_devices)',
              hintText: 'مثال: 5 — الحد الأدنى 2',
              prefixIcon: Icon(Icons.devices_other),
            ),
          ),
        ] else ...[
          const SizedBox(height: 8),
          const Text('👤 الخطة الفردية: جهاز واحد (بلا ربط أجهزة).',
              style: TextStyle(fontSize: 11.5, color: Colors.grey)),
        ],
        const SizedBox(height: 18),
        const Text('3️⃣ المدة الزمنية',
            style: TextStyle(fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        RadioGroup<PlanDuration>(
          groupValue: _duration,
          onChanged: (v) {
            if (v != null) setState(() => _duration = v);
          },
          child: Column(
            children: [
              for (final d in PlanDuration.values)
                RadioListTile<PlanDuration>(
                  value: d,
                  title: Text(d.label, style: const TextStyle(fontSize: 14)),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                ),
            ],
          ),
        ),
        const SizedBox(height: 22),
        SizedBox(
          height: 58,
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF16A34A),
              textStyle:
                  const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
            ),
            onPressed: _busy ? null : _activate,
            icon: _busy
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                        strokeWidth: 2.5, color: Colors.white))
                : const Icon(Icons.rocket_launch),
            label: Text(_busy ? 'جارٍ التفعيل…' : 'تفعيل وترقية الحساب'),
          ),
        ),
        const SizedBox(height: 10),
        const Text(
          'يُحسب تاريخ الانتهاء بساعة خادم فيربيس حصراً (server_ts + المدة). '
          'التفعيل يحدث عقدة workspaces/…/subscription في المكان ويفتح كل '
          'المزايا فوراً دون أي تدخل يدوي.',
          style: TextStyle(fontSize: 11.5, color: Colors.grey, height: 1.6),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

// ==================== سجل المشتركين ====================

class SubscribersScreen extends StatefulWidget {
  const SubscribersScreen({super.key});
  @override
  State<SubscribersScreen> createState() => _SubscribersScreenState();
}

class _SubscribersScreenState extends State<SubscribersScreen> {
  final _search = TextEditingController();
  late Future<List<SubscriberEntry>> _future = _load();
  int _serverNow = 0;

  @override
  void initState() {
    super.initState();
    adminRefreshTick.addListener(_onTick);
    _loadServerClock();
  }

  @override
  void dispose() {
    adminRefreshTick.removeListener(_onTick);
    _search.dispose();
    super.dispose();
  }

  void _onTick() => _refresh();

  /// (إصلاح) حالة الانتهاء تُحسب بساعة الخادم لا ساعة الهاتف — ساعة
  /// الهاتف المتقدّمة/المتأخرة كانت تُظهر مشتركاً منتهياً فعّالاً والعكس.
  Future<void> _loadServerClock() async {
    try {
      final now = await Rtdb.instance.serverNowMs();
      if (mounted) setState(() => _serverNow = now);
    } catch (_) {
      // بلا شبكة: الساعة المحلية احتياط مقبول للعرض فقط.
      if (mounted) {
        setState(
            () => _serverNow = DateTime.now().millisecondsSinceEpoch);
      }
    }
  }

  Future<List<SubscriberEntry>> _load() =>
      Rtdb.instance.configured
          ? Rtdb.instance.recentSubscribers()
          : Future.value(const []);

  Future<void> _refresh() async {
    await _loadServerClock();
    if (!mounted) return;
    setState(() => _future = _load());
  }

  Future<void> _extend(SubscriberEntry s) async {
    final d = await showModalBottomSheet<PlanDuration>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(14),
              child: Text('⏳ تمديد الاشتراك — اختر المدة',
                  style: TextStyle(fontWeight: FontWeight.w800)),
            ),
            ...PlanDuration.values.map((x) => ListTile(
                  leading: const Icon(Icons.add_alarm),
                  title: Text(x.label),
                  onTap: () => Navigator.pop(ctx, x),
                )),
          ],
        ),
      ),
    );
    if (d == null || !mounted) return;
    try {
      final r = await Rtdb.instance.activate(
        rawInput: s.workspaceId.isNotEmpty ? s.workspaceId : s.deviceId,
        planType: s.planType,
        duration: d,
        maxDevices: s.maxDevices,
        extend: true, // يبني فوق المتبقي الحالي.
        clientName: s.clientName,
        storeName: s.storeName,
        phone: s.phone,
        licenseKey: s.licenseKey,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: const Color(0xFF16A34A),
        content: Text(
            '✅ مُدِّد حتى ${fmtDate(r.expiresAtMs, lifetime: r.lifetime)}'),
      ));
      // السجل والإحصائيات يتجددان فوراً.
      adminRefreshTick.value++;
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          backgroundColor: const Color(0xFFDC2626), content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: _refresh,
      child: FutureBuilder<List<SubscriberEntry>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return ListView(children: [
              Padding(
                padding: const EdgeInsets.all(30),
                child: Text('تعذّر التحميل: ${snap.error}',
                    textAlign: TextAlign.center),
              ),
            ]);
          }
          final all = snap.data ?? const [];
          final q = _search.text.trim().toLowerCase();
          final qPhone = q.replaceAll(RegExp(r'[\s\-\(\)\+]'), '');

          // توسيع نطاق البحث: اسم المنشأة + اسم المستخدم + رقم الهاتف + Device ID + كود الترخيص
          final list = q.isEmpty
              ? all
              : all.where((s) {
                  final matchStore = s.storeName.toLowerCase().contains(q);
                  final matchUser = s.clientName.toLowerCase().contains(q);
                  final cleanSPhone =
                      s.phone.replaceAll(RegExp(r'[\s\-\(\)\+]'), '');
                  final matchPhone =
                      qPhone.isNotEmpty && cleanSPhone.contains(qPhone);
                  final matchDevice = s.deviceId.toLowerCase().contains(q) ||
                      s.deviceRef.toLowerCase().contains(q);
                  final matchKey = s.licenseKey.toLowerCase().contains(q);
                  final matchWs = s.workspaceId.toLowerCase().contains(q);

                  return matchStore ||
                      matchUser ||
                      matchPhone ||
                      matchDevice ||
                      matchKey ||
                      matchWs;
                }).toList();

          final nowMs = _serverNow > 0
              ? _serverNow
              : DateTime.now().millisecondsSinceEpoch;
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
                child: TextField(
                  controller: _search,
                  decoration: InputDecoration(
                    labelText:
                        'بحث بالمنشأة، العميل، الهاتف، المعرف، أو كود الترخيص',
                    hintText: 'ابحث باسم المتجر، المسؤول، رقم الهاتف...',
                    prefixIcon: const Icon(Icons.search, size: 18),
                    suffixIcon: _search.text.isEmpty
                        ? null
                        : IconButton(
                            tooltip: 'مسح البحث',
                            icon: const Icon(Icons.close, size: 18),
                            onPressed: () {
                              _search.clear();
                              setState(() {});
                            },
                          ),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              Expanded(child: _buildList(list, nowMs)),
            ],
          );
        },
      ),
    );
  }

  Widget _buildList(List<SubscriberEntry> list, int nowMs) {
    if (list.isEmpty) {
      return ListView(children: const [
        Padding(
          padding: EdgeInsets.all(40),
          child: Column(children: [
            Icon(Icons.inbox_outlined, size: 56, color: Colors.grey),
            SizedBox(height: 10),
            Text('لا توجد تفعيلات مسجلة بعد',
                textAlign: TextAlign.center,
                style: TextStyle(fontWeight: FontWeight.w700)),
            Text('كل تفعيل من الشاشة الأولى سيظهر هنا.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: Colors.grey)),
          ]),
        ),
      ]);
    }
    return ListView.separated(
      padding: const EdgeInsets.all(12),
      itemCount: list.length,
      separatorBuilder: (_, i) => const SizedBox(height: 10),
      itemBuilder: (context, i) {
        final s = list[i];
        return SubscriberCard(
          entry: s,
          nowMs: nowMs,
          onExtend: () => _extend(s),
        );
      },
    );
  }
}

/// بطاقة المشترك في لوحة إدارة التراخيص.
class SubscriberCard extends StatelessWidget {
  final SubscriberEntry entry;
  final VoidCallback onExtend;
  final int? nowMs;

  const SubscriberCard({
    super.key,
    required this.entry,
    required this.onExtend,
    this.nowMs,
  });

  @override
  Widget build(BuildContext context) {
    final s = entry;
    final currentMs = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final lifetime = s.expiresAtMs > DateTime(2090).millisecondsSinceEpoch;
    final expired = !lifetime && s.expiresAtMs <= currentMs;
    final color = expired
        ? const Color(0xFFDC2626)
        : (lifetime ? const Color(0xFF7C3AED) : const Color(0xFF16A34A));

    final statusText = expired
        ? 'منتهي'
        : (lifetime
            ? 'دائم ∞'
            : (s.status == 'trial' ? 'تجريبي' : 'فعّال'));

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: color.withValues(alpha: .35), width: 1.2),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ===== الترويسة العلوية للبطاقة =====
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(9),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: .12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(Icons.storefront_rounded,
                      size: 24, color: color),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // اسم المنشأة بخط عريض وواضح بحجم بارز بجانب أيقونة المتجر
                      Text(
                        s.storeName.isNotEmpty
                            ? s.storeName
                            : (s.workspaceId.isNotEmpty
                                ? s.workspaceId
                                : 'منشأة غير مسمّاة'),
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w900,
                          letterSpacing: -0.2,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 3),
                      // اسم المسؤول ورقم الهاتف مباشرة تحته
                      Row(
                        children: [
                          const Icon(Icons.person_outline,
                              size: 14, color: Colors.grey),
                          const SizedBox(width: 4),
                          Flexible(
                            child: Text(
                              s.clientName.isNotEmpty
                                  ? s.clientName
                                  : 'مسؤول غير محدد',
                              style: const TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600,
                                color: Colors.black87,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (s.phone.isNotEmpty) ...[
                            const Text('  •  ',
                                style: TextStyle(color: Colors.grey)),
                            Directionality(
                              textDirection: TextDirection.ltr,
                              child: Text(
                                s.phone,
                                style: const TextStyle(
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w700,
                                  color: Color(0xFF2563EB),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
                // شارة حالة الاشتراك
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 9, vertical: 4),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: .14),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: color.withValues(alpha: .3)),
                  ),
                  child: Text(
                    statusText,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      color: color,
                    ),
                  ),
                ),
              ],
            ),

            // أزرار التواصل السريع بجانب رقم الهاتف (اتصال سريع + واتساب بنقرة)
            if (s.phone.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    ActionChip(
                      avatar: const Icon(Icons.phone_in_talk,
                          size: 14, color: Color(0xFF2563EB)),
                      label: const Text('اتصال سريع',
                          style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFF2563EB))),
                      backgroundColor:
                          const Color(0xFF2563EB).withValues(alpha: .08),
                      side: BorderSide(
                          color: const Color(0xFF2563EB)
                              .withValues(alpha: .2)),
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      visualDensity: VisualDensity.compact,
                      onPressed: () => callPhone(context, s.phone),
                    ),
                    ActionChip(
                      avatar: const Icon(Icons.chat_bubble_outline,
                          size: 14, color: Color(0xFF16A34A)),
                      label: const Text('واتساب بنقرة',
                          style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFF16A34A))),
                      backgroundColor:
                          const Color(0xFF16A34A).withValues(alpha: .08),
                      side: BorderSide(
                          color: const Color(0xFF16A34A)
                              .withValues(alpha: .2)),
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      visualDensity: VisualDensity.compact,
                      onPressed: () => openWhatsApp(
                        context,
                        s.phone,
                        msg:
                            'مرحباً ${s.clientName.isNotEmpty ? s.clientName : ''}، بخصوص اشتراكك في تطبيق مدير الحسابات Nexora',
                      ),
                    ),
                  ],
                ),
              ),

            const SizedBox(height: 10),
            const Divider(height: 1),
            const SizedBox(height: 10),

            // كود الترخيص مع زر النسخ المباشر
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: Colors.grey.withValues(alpha: .06),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  const Icon(Icons.key, size: 15, color: Color(0xFF7C3AED)),
                  const SizedBox(width: 6),
                  const Text('كود الترخيص: ',
                      style: TextStyle(
                          fontSize: 11.5, fontWeight: FontWeight.w700)),
                  Expanded(
                    child: Text(
                      s.licenseKey,
                      textDirection: TextDirection.ltr,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        fontFamily: 'monospace',
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    tooltip: 'نسخ كود الترخيص',
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints:
                        const BoxConstraints(minWidth: 28, minHeight: 28),
                    icon: const Icon(Icons.copy, size: 14),
                    onPressed: () =>
                        copyText(context, 'كود الترخيص', s.licenseKey),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 5),

            // معرف الجهاز مع زر النسخ المباشر
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: Colors.grey.withValues(alpha: .06),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  const Icon(Icons.devices, size: 15, color: Colors.grey),
                  const SizedBox(width: 6),
                  const Text('معرف الجهاز: ',
                      style: TextStyle(
                          fontSize: 11.5, fontWeight: FontWeight.w700)),
                  Expanded(
                    child: Text(
                      s.deviceId.isNotEmpty ? s.deviceId : s.deviceRef,
                      textDirection: TextDirection.ltr,
                      style: const TextStyle(
                          fontSize: 11.5, color: Colors.black87),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    tooltip: 'نسخ معرف الجهاز',
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints:
                        const BoxConstraints(minWidth: 28, minHeight: 28),
                    icon: const Icon(Icons.copy, size: 14),
                    onPressed: () => copyText(
                        context,
                        'معرف الجهاز',
                        s.deviceId.isNotEmpty ? s.deviceId : s.deviceRef),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 8),

            // حالة الاشتراك وتاريخ الانتهاء وعدد الأجهزة المصرحة
            Row(
              children: [
                Icon(
                  s.planType == 'enterprise'
                      ? Icons.business
                      : Icons.person,
                  size: 15,
                  color: Colors.grey.shade700,
                ),
                const SizedBox(width: 5),
                Text(
                  s.planType == 'enterprise'
                      ? 'باقة مؤسسة (${s.maxDevices} أجهزة مصرحة)'
                      : 'باقة فردية (جهاز واحد مصرح)',
                  style: const TextStyle(
                      fontSize: 11.5, fontWeight: FontWeight.w700),
                ),
                const Spacer(),
                Text(
                  'ينتهي: ${fmtDate(s.expiryDate, lifetime: lifetime)}',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w800,
                    color:
                        expired ? const Color(0xFFDC2626) : Colors.black87,
                  ),
                ),
              ],
            ),

            const SizedBox(height: 8),

            // زر تمديد بنقرة
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
                onPressed: onExtend,
                icon: const Icon(Icons.more_time, size: 16),
                label: const Text('تمديد بنقرة',
                    style: TextStyle(
                        fontSize: 12, fontWeight: FontWeight.w700)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
