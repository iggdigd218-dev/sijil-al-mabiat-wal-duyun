// تطبيق المدير المستقل — لوحة تفعيل تراخيص Nexora (مالك النظام فقط).
import 'package:flutter/material.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart' hide TextDirection;

import 'rtdb.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('ar');
  await Rtdb.instance.load();
  runApp(const AdminApp());
}

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
              setState(() {});
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
  bool _busy = false;

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
              hintText: 'https://xxxx-default-rtdb.firebaseio.com',
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _auth,
            textDirection: TextDirection.ltr,
            decoration: const InputDecoration(
              labelText: 'مفتاح المصادقة (اختياري)',
              hintText: 'Database Secret أو ID Token',
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'نفس الرابط المستخدم في تطبيق مدير الحسابات — '
            'يُحفظ محلياً على هذا الهاتف فقط.',
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
                  if (mounted) Navigator.pop(context);
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
  }

  Future<void> _load() async {
    if (!Rtdb.instance.configured || _busy) return;
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
            _card('إجمالي المساحات', '📱', _m?.totalWorkspaces,
                const Color(0xFF2563EB)),
            const SizedBox(width: 7),
            _card('مشتركون مدفوعون', '💎', _m?.activePaid,
                const Color(0xFF16A34A)),
            const SizedBox(width: 7),
            _card('فترة تجريبية', '⏳', _m?.activeTrials,
                const Color(0xFFEA580C)),
            const SizedBox(width: 7),
            _card('منتهية / مجانية', '🔒', _m?.expired,
                const Color(0xFFDC2626)),
          ],
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
  String _plan = 'individual';
  PlanDuration _duration = PlanDuration.month;
  final _seats = TextEditingController(text: '5');
  bool _busy = false;

  Future<void> _activate() async {
    final rtdb = Rtdb.instance;
    if (!rtdb.configured) {
      _snack('اضبط رابط قاعدة البيانات أولاً من ⚙️ الإعدادات', error: true);
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
        rawInput: _id.text,
        planType: _plan,
        duration: _duration,
        maxDevices: seats,
      );
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: const Icon(Icons.check_circle,
              color: Color(0xFF16A34A), size: 52),
          title: const Text('✅ تم التفعيل بنجاح',
              style: TextStyle(color: Color(0xFF16A34A))),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
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
          actions: [
            FilledButton(
                onPressed: () => Navigator.pop(ctx), child: const Text('تم')),
          ],
        ),
      );
      _id.clear();
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
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: error ? const Color(0xFFDC2626) : const Color(0xFF16A34A),
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
        const Text('1️⃣ معرف العميل',
            style: TextStyle(fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        TextField(
          controller: _id,
          textDirection: TextDirection.ltr,
          decoration: InputDecoration(
            labelText: 'معرف الجهاز / بصمة التفعيل / معرف مساحة العمل',
            hintText: 'ألصق ما وصلك في رسالة واتساب من العميل',
            prefixIcon: const Icon(Icons.fingerprint),
            suffixIcon: IconButton(
              tooltip: 'مسح',
              icon: const Icon(Icons.close, size: 18),
              onPressed: () => _id.clear(),
            ),
          ),
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
              hintText: 'مثال: 5',
              prefixIcon: Icon(Icons.devices_other),
            ),
          ),
        ],
        const SizedBox(height: 18),
        const Text('3️⃣ المدة الزمنية',
            style: TextStyle(fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        ...PlanDuration.values.map((d) => RadioListTile<PlanDuration>(
              value: d,
              groupValue: _duration,
              onChanged: (v) => setState(() => _duration = v!),
              title: Text(d.label, style: const TextStyle(fontSize: 14)),
              dense: true,
              contentPadding: EdgeInsets.zero,
            )),
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
  late Future<List<SubscriberEntry>> _future = _load();

  Future<List<SubscriberEntry>> _load() =>
      Rtdb.instance.configured
          ? Rtdb.instance.recentSubscribers()
          : Future.value(const []);

  Future<void> _refresh() async => setState(() => _future = _load());

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
        rawInput: s.workspaceId,
        planType: s.planType,
        duration: d,
        maxDevices: s.maxDevices,
        extend: true, // يبني فوق المتبقي الحالي.
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: const Color(0xFF16A34A),
        content: Text('✅ مُدِّد حتى ${fmtDate(r.expiresAtMs, lifetime: r.lifetime)}'),
      ));
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
          final list = snap.data ?? const [];
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
          final nowMs = DateTime.now().millisecondsSinceEpoch;
          return ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: list.length,
            separatorBuilder: (_, i) => const SizedBox(height: 8),
            itemBuilder: (context, i) {
              final s = list[i];
              final lifetime =
                  s.expiresAtMs > DateTime(2090).millisecondsSinceEpoch;
              final expired = !lifetime && s.expiresAtMs <= nowMs;
              final color = expired
                  ? const Color(0xFFDC2626)
                  : (lifetime
                      ? const Color(0xFF7C3AED)
                      : const Color(0xFF16A34A));
              return Card(
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                  side: BorderSide(color: color.withValues(alpha: .3)),
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Icon(
                            s.planType == 'enterprise'
                                ? Icons.business
                                : Icons.person,
                            size: 18,
                            color: color),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            s.workspaceId,
                            textDirection: TextDirection.ltr,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontWeight: FontWeight.w800, fontSize: 13),
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: color.withValues(alpha: .12),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            expired
                                ? 'منتهٍ'
                                : (lifetime ? 'دائم ∞' : 'فعّال'),
                            style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                                color: color),
                          ),
                        ),
                      ]),
                      const SizedBox(height: 6),
                      Text(
                        '${s.planType == 'enterprise' ? '🏢 مؤسسة — ${s.maxDevices} أجهزة' : '👤 فردي'}'
                        '   •   ينتهي: ${fmtDate(s.expiresAtMs, lifetime: lifetime)}',
                        style:
                            const TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                      if (s.deviceRef.isNotEmpty &&
                          s.deviceRef != s.workspaceId)
                        Text('الجهاز: ${s.deviceRef}',
                            textDirection: TextDirection.ltr,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 11, color: Colors.grey)),
                      const SizedBox(height: 6),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                              visualDensity: VisualDensity.compact),
                          onPressed: () => _extend(s),
                          icon: const Icon(Icons.more_time, size: 16),
                          label: const Text('تمديد بنقرة',
                              style: TextStyle(fontSize: 12)),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
