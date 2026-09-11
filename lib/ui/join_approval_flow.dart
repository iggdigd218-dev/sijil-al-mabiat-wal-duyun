// تدفق الانضمام بموافقة المدير (دفعة 51) — جهة الجهاز الجديد:
//   ١) تسمية الجهاز (إلزامي قبل فتح الكاميرا أو إدخال الرمز).
//   ٢) مسح QR أو إدخال PIN من 6 أرقام.
//   ٣) دفع طلب الانضمام + حالة «بانتظار موافقة المدير…» — حارس صارم:
//      لا سحب لللقطة ولا مساس بالبيانات المحلية قبل الموافقة.
//   ٤) عند الموافقة: ترطيب نظيف كامل ثم الانتقال للشاشة الرئيسية فوراً.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/sfx.dart';
import '../core/theme.dart';
import '../data/providers.dart';
import '../data/sync/cloud_join.dart';
import '../data/sync/device_id.dart';
import 'home_shell.dart';
import 'lock_gate.dart';
import 'qr_pair_scanner.dart' show scanQrPair;

/// نقطة الدخول: تفتح معالج الانضمام التفاعلي كاملاً.
Future<void> startJoinApprovalFlow(BuildContext context, WidgetRef ref) async {
  await Navigator.of(context).push(
    MaterialPageRoute(builder: (_) => const JoinApprovalScreen()),
  );
}

class JoinApprovalScreen extends ConsumerStatefulWidget {
  const JoinApprovalScreen({
    super.key,
    this.prefillUrl = '',
    this.prefillWs = '',
    this.prefillToken = '',
  });

  /// عند القدوم من مسح QR جاهز: بعد التسمية يُرسل الطلب مباشرة.
  final String prefillUrl;
  final String prefillWs;
  final String prefillToken;

  @override
  ConsumerState<JoinApprovalScreen> createState() =>
      _JoinApprovalScreenState();
}

enum _JoinStep { naming, method, waiting, done, rejected }

class _JoinApprovalScreenState extends ConsumerState<JoinApprovalScreen> {
  _JoinStep _step = _JoinStep.naming;
  final _nameCtrl = TextEditingController();
  final _urlCtrl = TextEditingController();
  final _pinCtrl = TextEditingController();
  String _error = '';
  bool _busy = false;
  Timer? _pollTimer;
  String _joinUrl = '';
  String _joinWs = 'default';
  String _joinToken = '';

  @override
  void dispose() {
    _pollTimer?.cancel();
    _nameCtrl.dispose();
    _urlCtrl.dispose();
    _pinCtrl.dispose();
    super.dispose();
  }

  // ---------- خطوة 2أ: مسح QR ----------
  Future<void> _scanQr() async {
    if (_busy) return;
    final data = await scanQrPair(context);
    if (data == null || !mounted) return;
    if (!data.isCloud || data.cloudUrl.isEmpty || data.tok.isEmpty) {
      setState(() => _error = 'رمز QR غير صالح — تأكد أنه رمز دعوة سحابية.');
      return;
    }
    await _sendRequest(
      url: data.cloudUrl,
      ws: data.ws.isEmpty ? 'default' : data.ws,
      tokenOrPin: data.tok,
    );
  }

  // ---------- خطوة 2ب: PIN يدوي ----------
  Future<void> _submitPin() async {
    final url = _urlCtrl.text.trim();
    final pin = _pinCtrl.text.trim();
    if (url.isEmpty || pin.isEmpty) {
      setState(() => _error = 'أدخل رابط المجموعة والرمز.');
      return;
    }
    await _sendRequest(url: url, ws: 'default', tokenOrPin: pin);
  }

  // ---------- خطوة 3: دفع الطلب والانتظار ----------
  Future<void> _sendRequest({
    required String url,
    required String ws,
    required String tokenOrPin,
  }) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      final repo = ref.read(repoProvider);
      await CloudJoin.requestJoin(
        repo,
        backendUrl: url,
        tokenOrPin: tokenOrPin,
        deviceName: _nameCtrl.text,
        workspaceId: ws,
      );
      _joinUrl = url;
      _joinWs = ws;
      Sfx.click();
      setState(() {
        _step = _JoinStep.waiting;
        _busy = false;
      });
      _startPolling();
    } catch (e) {
      setState(() {
        _busy = false;
        _error = e is CloudJoinException ? e.message : '$e';
      });
    }
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(
      const Duration(seconds: 4),
      (_) => _pollOnce(),
    );
    _pollOnce();
  }

  Future<void> _pollOnce() async {
    if (!mounted || _step != _JoinStep.waiting || _busy) return;
    try {
      final repo = ref.read(repoProvider);
      final ourId = await ensureDeviceId(repo);
      final st = await CloudJoin.pollJoinStatus(
        repo,
        backendUrl: _joinUrl,
        deviceId: ourId,
        workspaceId: _joinWs,
      );
      final status = st['status'];
      if (status == 'approved') {
        _pollTimer?.cancel();
        _joinToken = st['token'] ?? '';
        await _hydrate();
      } else if (status == 'rejected') {
        _pollTimer?.cancel();
        Sfx.error();
        if (mounted) setState(() => _step = _JoinStep.rejected);
      }
    } catch (_) {
      // شبكة متقطعة — المحاولة القادمة بعد 4 ثوانٍ.
    }
  }

  // ---------- خطوة 4: الترطيب النظيف ----------
  Future<void> _hydrate() async {
    if (_busy || !mounted) return;
    setState(() => _busy = true);
    final container = ProviderScope.containerOf(context, listen: false);
    try {
      final repo = container.read(repoProvider);
      await CloudJoin.completeApprovedJoin(
        repo,
        backendUrl: _joinUrl,
        token: _joinToken,
        workspaceId: _joinWs,
      );
      final engine = container.read(syncEngineProvider);
      engine.stop();
      await engine.start();
      container.read(refreshProvider.notifier).state++;
      Sfx.pair();
      if (!mounted) return;
      setState(() => _step = _JoinStep.done);
      await Future.delayed(const Duration(milliseconds: 900));
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const LockGate(child: HomeShell())),
        (_) => false,
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _step = _JoinStep.waiting;
          _error = 'تعذّر تنزيل نسخة المجموعة: $e — ستُعاد المحاولة.';
        });
        _startPolling();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('الانضمام إلى مجموعة')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: ListView(
              padding: const EdgeInsets.all(22),
              shrinkWrap: true,
              children: [
                switch (_step) {
                  _JoinStep.naming => _namingStep(),
                  _JoinStep.method => _methodStep(),
                  _JoinStep.waiting => _waitingStep(),
                  _JoinStep.done => _doneStep(),
                  _JoinStep.rejected => _rejectedStep(),
                },
                if (_error.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.red.withValues(alpha: .08),
                      borderRadius: BorderRadius.circular(10),
                      border:
                          Border.all(color: Colors.red.withValues(alpha: .3)),
                    ),
                    child: Text(_error,
                        style: const TextStyle(
                            color: Colors.red, fontSize: 12.5, height: 1.5)),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ═══════════ خطوة 1: تسمية الجهاز ═══════════
  Widget _namingStep() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Icon(Icons.badge_outlined,
              size: 52, color: AppColors.primaryOf(context)),
          const SizedBox(height: 14),
          const Text(
            'ما اسم هذا الجهاز؟',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          Text(
            'سيظهر هذا الاسم للمدير عند طلب الانضمام وفي قوائم الأجهزة '
            '(مثال: «كاشير الصالة»، «جوال المبيعات»).',
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 12.5, height: 1.6, color: AppColors.text2Of(context)),
          ),
          const SizedBox(height: 18),
          TextField(
            controller: _nameCtrl,
            textInputAction: TextInputAction.done,
            decoration: const InputDecoration(
              labelText: 'اسم الجهاز',
              prefixIcon: Icon(Icons.devices),
              border: OutlineInputBorder(),
            ),
            onSubmitted: (_) => _toMethod(),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _toMethod,
            icon: const Icon(Icons.arrow_back_ios_new, size: 15),
            label: const Text('متابعة'),
          ),
        ],
      );

  void _toMethod() {
    if (_nameCtrl.text.trim().isEmpty) {
      setState(() => _error = 'اسم الجهاز مطلوب قبل المتابعة.');
      return;
    }
    Sfx.click();
    setState(() => _error = '');
    // بيانات دعوة جاهزة (قادمة من QR ممسوح مسبقاً)؟ أرسل الطلب فوراً.
    if (widget.prefillUrl.isNotEmpty && widget.prefillToken.isNotEmpty) {
      _sendRequest(
        url: widget.prefillUrl,
        ws: widget.prefillWs.isEmpty ? 'default' : widget.prefillWs,
        tokenOrPin: widget.prefillToken,
      );
      return;
    }
    setState(() => _step = _JoinStep.method);
  }

  // ═══════════ خطوة 2: طريقة الاقتران ═══════════
  Widget _methodStep() {
    final mobile = Platform.isAndroid || Platform.isIOS;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Icon(Icons.qr_code_scanner,
            size: 52, color: AppColors.primaryOf(context)),
        const SizedBox(height: 14),
        Text(
          'كيف تريد الاقتران يا «${_nameCtrl.text.trim()}»؟',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 16.5, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 18),
        if (mobile) ...[
          FilledButton.icon(
            onPressed: _busy ? null : _scanQr,
            icon: const Icon(Icons.qr_code_scanner),
            label: const Text('مسح رمز QR'),
          ),
          const SizedBox(height: 12),
          const Row(children: [
            Expanded(child: Divider()),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 10),
              child: Text('أو', style: TextStyle(fontSize: 12)),
            ),
            Expanded(child: Divider()),
          ]),
          const SizedBox(height: 12),
        ],
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('إدخال رمز من 6 أرقام',
                    style:
                        TextStyle(fontSize: 14, fontWeight: FontWeight.w800)),
                const SizedBox(height: 12),
                TextField(
                  controller: _urlCtrl,
                  textDirection: TextDirection.ltr,
                  decoration: const InputDecoration(
                    labelText: 'رابط المجموعة (https://...)',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _pinCtrl,
                  textDirection: TextDirection.ltr,
                  keyboardType: TextInputType.number,
                  maxLength: 8,
                  decoration: const InputDecoration(
                    labelText: 'رمز الاقتران (6 أرقام أو رمز الدعوة)',
                    counterText: '',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: _busy ? null : _submitPin,
                  child: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('إرسال طلب الانضمام'),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ═══════════ خطوة 3: الانتظار ═══════════
  Widget _waitingStep() => Column(
        children: [
          const SizedBox(height: 20),
          SizedBox(
            width: 64,
            height: 64,
            child: CircularProgressIndicator(
              strokeWidth: 3,
              color: AppColors.primaryOf(context),
            ),
          ),
          const SizedBox(height: 22),
          const Text(
            'بانتظار موافقة المدير…',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 10),
          Text(
            'وصل طلبك إلى جهاز المدير. فور القبول سيُهيأ هذا الجهاز '
            'تلقائياً ببيانات المجموعة — لا تغلق هذه الشاشة.',
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 12.5, height: 1.7, color: AppColors.text2Of(context)),
          ),
        ],
      );

  Widget _doneStep() => const Column(
        children: [
          SizedBox(height: 20),
          Icon(Icons.check_circle, size: 64, color: Color(0xFF16A34A)),
          SizedBox(height: 18),
          Text('تمت الموافقة! جارٍ تجهيز الجهاز…',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
        ],
      );

  Widget _rejectedStep() => Column(
        children: [
          const SizedBox(height: 20),
          const Icon(Icons.cancel_outlined, size: 64, color: Colors.red),
          const SizedBox(height: 18),
          const Text('رفض المدير طلب الانضمام',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          Text(
            'لم يُمس أي شيء في هذا الجهاز — بياناتك المحلية كما هي. '
            'يمكنك المحاولة مجدداً برمز جديد من المدير.',
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 12.5, height: 1.6, color: AppColors.text2Of(context)),
          ),
          const SizedBox(height: 16),
          OutlinedButton(
            onPressed: () => setState(() {
              _error = '';
              _step = _JoinStep.method;
            }),
            child: const Text('إعادة المحاولة'),
          ),
        ],
      );
}
