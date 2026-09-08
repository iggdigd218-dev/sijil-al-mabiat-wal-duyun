import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/chat_media.dart';
import '../core/format.dart';
import '../core/keep_alive_service.dart';
import '../core/models.dart';
import '../core/sfx.dart';
import '../core/theme.dart';
import '../data/providers.dart';
import 'group_chat_screen.dart';
import 'widgets.dart';

/// الدردشة — محادثة لكل حساب، مع إرسال كشف الحساب ومشاركة عبر واتساب.
/// نقل شاشة `chat.js`.
class ChatScreen extends ConsumerWidget {
  const ChatScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accounts = ref.watch(accountsProvider);
    final mode = ref.watch(workspaceModeProvider).valueOrNull ?? 'standalone';
    final peers = ref.watch(groupPeersProvider).valueOrNull ?? const [];
    final online = peers.where((p) => p.online).length;

    // بطاقة دردشة المجموعة — تظهر فقط في الوضع المُدار (host/member).
    final groupTile = mode == 'standalone'
        ? null
        : Card(
            color: AppColors.primarySoftOf(context),
            child: ListTile(
              leading: CircleAvatar(
                backgroundColor: AppColors.primaryOf(context),
                child: const Icon(Icons.groups, color: Colors.white),
              ),
              title: const Text(
                'دردشة المجموعة',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
              subtitle: Text(
                'بين أجهزة المجموعة فقط · $online/${peers.length} متصل',
                style: const TextStyle(fontSize: 12),
              ),
              trailing: const Icon(Icons.chevron_left),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const GroupChatScreen()),
              ),
            ),
          );

    return accounts.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => EmptyState(
        icon: Icons.error_outline,
        title: 'تعذّر تحميل المحادثات',
        message: '$e',
      ),
      data: (list) {
        if (list.isEmpty && groupTile == null) {
          return const EmptyState(
            icon: Icons.forum_outlined,
            title: 'لا توجد محادثات',
            message: 'أضف حسابًا لتبدأ محادثة معه.',
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 96),
          itemCount: list.length + (groupTile == null ? 0 : 1),
          separatorBuilder: (_, __) => const SizedBox(height: 8),
          itemBuilder: (context, i) {
            if (groupTile != null) {
              if (i == 0) return groupTile;
              i -= 1;
            }
            final a = list[i].account;
            return Card(
              child: ListTile(
                leading: CircleAvatar(
                  backgroundColor: AppColors.primarySoftOf(context),
                  child: Text(a.kind.icon),
                ),
                title: Text(
                  a.name,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                subtitle: Text(
                  a.contactNumber.isEmpty
                      ? a.kind.label
                      : '${a.kind.label} · ${a.contactNumber}',
                  style: const TextStyle(fontSize: 12),
                ),
                trailing: const Icon(Icons.chevron_left),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ChatThreadScreen(account: a),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class ChatThreadScreen extends ConsumerStatefulWidget {
  final Account account;
  const ChatThreadScreen({super.key, required this.account});

  @override
  ConsumerState<ChatThreadScreen> createState() => _ChatThreadScreenState();
}

class _ChatThreadScreenState extends ConsumerState<ChatThreadScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  int? _convId;
  bool _sending = false;
  bool _recording = false;
  String? _recordingPath;
  DateTime? _recordingStart;

  @override
  void initState() {
    super.initState();
    _open();
  }

  Future<void> _open() async {
    final id = await ref.read(repoProvider).conversationFor(widget.account);
    if (mounted) setState(() => _convId = id);
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send(String body, {String kind = 'text'}) async {
    if (body.trim().isEmpty || _convId == null) return;
    await ref.read(repoProvider).sendMessage(
          ChatMessage(
            conversationId: _convId!,
            sender: 'me',
            body: body.trim(),
            kind: kind,
            createdAt: DateTime.now(),
          ),
        );
    _input.clear();
    bump(ref);
    await _scrollToEnd();
  }

  /// قائمة المرفقات: صورة / فيديو / ملف من أي نوع (محلي فقط —
  /// المحادثات الفردية خارج نطاق المزامنة).
  Future<void> _pickAttachment() async {
    if (_convId == null) return;
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            ListTile(
              leading: Icon(Icons.image_outlined,
                  color: AppColors.greenOf(context)),
              title: const Text('صورة'),
              onTap: () => Navigator.pop(context, 'image'),
            ),
            ListTile(
              leading: Icon(Icons.videocam_outlined,
                  color: AppColors.violetOf(context)),
              title: const Text('فيديو'),
              onTap: () => Navigator.pop(context, 'video'),
            ),
            ListTile(
              leading:
                  Icon(Icons.attach_file, color: AppColors.infoOf(context)),
              title: const Text('ملف (جميع الأنواع)'),
              onTap: () => Navigator.pop(context, 'file'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    try {
      final res = await FilePicker.platform.pickFiles(
        type: switch (choice) {
          'image' => FileType.image,
          'video' => FileType.video,
          _ => FileType.any,
        },
        withData: true,
      );
      if (res == null || res.files.isEmpty || !mounted) return;
      final f = res.files.single;
      final bytes = f.bytes ??
          (f.path != null ? await File(f.path!).readAsBytes() : null);
      if (bytes == null) {
        if (mounted) showSnack(context, 'تعذّر قراءة الملف', error: true);
        return;
      }
      setState(() => _sending = true);
      await ref.read(repoProvider).sendConversationAttachment(
            conversationId: _convId!,
            bytes: bytes,
            name: f.name,
            kind: choice == 'file' ? attachmentKindFromName(f.name) : choice,
            caption: _input.text.trim(),
          );
      _input.clear();
      Sfx.success();
      bump(ref);
      _scrollToEnd();
    } catch (e) {
      if (mounted) showSnack(context, 'تعذّر الإرسال: $e', error: true);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// يبدأ/يوقف تسجيل رسالة صوتية (زر الميكروفون).
  Future<void> _toggleRecording() async {
    if (_recording) {
      final ok = await ChatMedia.stopRecording();
      final path = _recordingPath;
      final started = _recordingStart;
      setState(() {
        _recording = false;
        _recordingPath = null;
        _recordingStart = null;
      });
      if (!ok || path == null || _convId == null) return;
      final f = File(path);
      if (!await f.exists() || await f.length() == 0) return;
      // تسجيلات أقصر من ثانية غالباً ضغطة خاطئة.
      if (started != null &&
          DateTime.now().difference(started) < const Duration(seconds: 1)) {
        try {
          await f.delete();
        } catch (_) {}
        return;
      }
      try {
        setState(() => _sending = true);
        final bytes = await f.readAsBytes();
        await ref.read(repoProvider).sendConversationAttachment(
              conversationId: _convId!,
              bytes: bytes,
              name: 'voice_${DateTime.now().millisecondsSinceEpoch}.m4a',
              kind: 'audio',
            );
        Sfx.success();
        bump(ref);
        _scrollToEnd();
      } catch (e) {
        if (mounted) showSnack(context, 'تعذّر إرسال التسجيل: $e', error: true);
      } finally {
        if (mounted) setState(() => _sending = false);
      }
      return;
    }
    // بدء التسجيل: إذن الميكروفون بنافذة النظام الرسمية أولاً.
    if (!await NexKeepAlive.hasPermission(NexKeepAlive.permRecordAudio)) {
      final granted =
          await NexKeepAlive.requestPermission(NexKeepAlive.permRecordAudio);
      if (!granted) {
        if (mounted) {
          showSnack(context, 'لم يُمنح إذن الميكروفون', error: true);
        }
        return;
      }
    }
    final dir = await getApplicationDocumentsDirectory();
    final folder = Directory('${dir.path}/chat_media');
    await folder.create(recursive: true);
    final path =
        '${folder.path}/rec_${DateTime.now().millisecondsSinceEpoch}.m4a';
    final started = await ChatMedia.startRecording(path);
    if (!started) {
      if (mounted) showSnack(context, 'تعذّر بدء التسجيل', error: true);
      return;
    }
    Sfx.click();
    setState(() {
      _recording = true;
      _recordingPath = path;
      _recordingStart = DateTime.now();
    });
  }

  Future<void> _scrollToEnd() async {
    await Future<void>.delayed(const Duration(milliseconds: 120));
    if (_scroll.hasClients) {
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    }
  }

  /// يبني نص كشف الحساب ويرسله في المحادثة.
  Future<void> _sendStatement() async {
    final repo = ref.read(repoProvider);
    final bal = await repo.balanceOf(widget.account);
    final txs = await repo.transactions(accountId: widget.account.id);
    final label = bal > 0 ? 'عليه' : (bal < 0 ? 'له' : 'متساوٍ');
    final b = StringBuffer()
      ..writeln('📊 كشف حساب: ${widget.account.name}')
      ..writeln('الرصيد الحالي: ${Fmt.money(bal.abs())} ($label)')
      ..writeln('عدد العمليات: ${txs.length}')
      ..writeln('التاريخ: ${Fmt.date(DateTime.now())}');
    await _send(b.toString(), kind: 'statement');
  }

  Future<void> _shareWhatsApp() async {
    final number = Fmt.waNumber(widget.account.contactNumber);
    if (number.isEmpty) {
      showSnack(context, 'لا يوجد رقم واتساب لهذا الحساب', error: true);
      return;
    }
    final repo = ref.read(repoProvider);
    final bal = await repo.balanceOf(widget.account);
    final label = bal > 0 ? 'عليه' : (bal < 0 ? 'له' : 'متساوٍ');
    final text = 'مرحبًا ${widget.account.name}\n'
        'الرصيد الحالي: ${Fmt.money(bal.abs())} ($label)';
    final uri = Uri.parse(
      'https://wa.me/$number?text=${Uri.encodeComponent(text)}',
    );
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.account;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(a.name, style: const TextStyle(fontSize: 16)),
            Text(
              a.kind.label,
              style: TextStyle(fontSize: 11, color: AppColors.text3Of(context)),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'إرسال كشف الحساب',
            onPressed: _sendStatement,
            icon: const Icon(Icons.description_outlined),
          ),
          IconButton(
            tooltip: 'مشاركة عبر واتساب',
            onPressed: _shareWhatsApp,
            icon: const Icon(Icons.share_outlined),
          ),
        ],
      ),
      body: _convId == null
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Expanded(
                  child: ref.watch(messagesProvider(_convId!)).when(
                        loading: () =>
                            const Center(child: CircularProgressIndicator()),
                        error: (e, _) => Center(child: Text('$e')),
                        data: (msgs) {
                          if (msgs.isEmpty) {
                            return const EmptyState(
                              icon: Icons.chat_bubble_outline,
                              title: 'ابدأ المحادثة',
                              message: 'اكتب رسالة أو أرسل كشف الحساب مباشرة.',
                            );
                          }
                          return ListView.builder(
                            controller: _scroll,
                            padding: const EdgeInsets.all(14),
                            itemCount: msgs.length,
                            itemBuilder: (context, i) =>
                                _Bubble(message: msgs[i]),
                          );
                        },
                      ),
                ),
                SafeArea(
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                    color: AppColors.surfaceOf(context),
                    child: Row(
                      children: [
                        IconButton(
                          tooltip: 'إرفاق ملف',
                          onPressed:
                              _sending || _recording ? null : _pickAttachment,
                          icon: Icon(Icons.attach_file,
                              color: AppColors.infoOf(context)),
                        ),
                        IconButton(
                          tooltip: _recording
                              ? 'إيقاف التسجيل وإرساله'
                              : 'تسجيل رسالة صوتية',
                          onPressed: _sending ? null : _toggleRecording,
                          icon: Icon(
                            _recording ? Icons.stop_circle : Icons.mic_none,
                            color: _recording
                                ? AppColors.dangerOf(context)
                                : AppColors.primaryOf(context),
                          ),
                        ),
                        Expanded(
                          child: TextField(
                            controller: _input,
                            decoration: InputDecoration(
                              hintText: _recording
                                  ? 'جارٍ التسجيل… 🎙️'
                                  : 'اكتب رسالة...',
                              isDense: true,
                            ),
                            onSubmitted: _send,
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton.filled(
                          onPressed: _sending || _recording
                              ? null
                              : () => _send(_input.text),
                          icon: _sending
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2),
                                )
                              : const Icon(Icons.send, size: 20),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

class _Bubble extends StatelessWidget {
  final ChatMessage message;
  const _Bubble({required this.message});

  @override
  Widget build(BuildContext context) {
    final mine = message.isMine;
    final isStatement = message.kind == 'statement';
    final isVoucher = message.kind == 'voucher';
    final isAttachment =
        const {'image', 'video', 'audio', 'file'}.contains(message.kind);
    final isImage = isVoucher &&
        message.payload.trim().isNotEmpty &&
        File(message.payload).existsSync();

    return Align(
      alignment: mine ? Alignment.centerLeft : Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * .76,
        ),
        decoration: BoxDecoration(
          color: isStatement || isVoucher
              ? AppColors.infoSoftOf(context)
              : (mine
                  ? AppColors.primarySoftOf(context)
                  : AppColors.surface2Of(context)),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.borderOf(context)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (isStatement)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Pill('كشف حساب', color: AppColors.infoOf(context)),
              ),
            if (isVoucher && !isImage)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Pill('سند / إشعار', color: AppColors.infoOf(context)),
              ),
            if (isImage)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Image.file(
                    File(message.payload),
                    fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) =>
                        const Text('تعذّر عرض الصورة'),
                  ),
                ),
              ),
            if (isAttachment) AttachmentView(message: message),
            if (message.body.trim().isNotEmpty)
              Text(
                message.body,
                style: const TextStyle(fontSize: 13.5, height: 1.5),
              ),
            const SizedBox(height: 4),
            Text(
              Fmt.dateTime(message.createdAt),
              style: TextStyle(fontSize: 10, color: AppColors.text3Of(context)),
            ),
          ],
        ),
      ),
    );
  }
}
