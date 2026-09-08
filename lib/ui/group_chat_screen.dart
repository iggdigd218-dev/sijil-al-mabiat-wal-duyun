// دردشة المجموعة: قناة تواصل بين أجهزة المجموعة فقط (وليس مع العملاء).
//
//  - متاحة لكل جهاز مقترن حتى بلا صلاحيات — يتواصل بها العضو مع المدير
//    وبقية الأجهزة (ملاحظة دائمة أعلى الشاشة توضح ذلك).
//  - أعلى الشاشة شريط بأسماء الأجهزة بخط صغير وبجانب كل اسم شارة ملونة:
//    أخضر = متصل، رمادي = غير متصل، أحمر = موقوف من المدير،
//    برتقالي = حسابه معلق (لم يعين له المدير مستخدماً بعد).
//  - الأجهزة المطرودة تُخفى نهائياً من الشريط والدردشة.
//  - الرسائل تُزامن فورياً عبر LAN مثل أي عملية (EntityKind.message).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/format.dart';
import '../core/models.dart';
import '../core/sfx.dart';
import '../core/theme.dart';
import '../data/providers.dart';
import '../data/sync/sync_activity.dart';
import 'widgets.dart';

class GroupChatScreen extends ConsumerStatefulWidget {
  const GroupChatScreen({super.key});

  @override
  ConsumerState<GroupChatScreen> createState() => _GroupChatScreenState();
}

class _GroupChatScreenState extends ConsumerState<GroupChatScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  Timer? _ticker;
  StreamSubscription<int>? _bus;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    // تحديث دوري + فوري عند أي نشاط مزامنة (وصول رسالة من جهاز آخر).
    _ticker = Timer.periodic(const Duration(seconds: 4), (_) => _refresh());
    _bus = SyncActivityBus.instance.stream.listen((_) => _refresh());
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _bus?.cancel();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _refresh() {
    if (!mounted) return;
    ref.invalidate(groupMessagesProvider);
    ref.invalidate(groupPeersProvider);
  }

  Future<void> _send() async {
    final body = _input.text.trim();
    if (body.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      await ref.read(repoProvider).sendGroupMessage(body);
      _input.clear();
      Sfx.click();
      _refresh();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
        );
      }
    } catch (e) {
      if (mounted) showSnack(context, 'تعذّر الإرسال: $e', error: true);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final peersAsync = ref.watch(groupPeersProvider);
    final msgsAsync = ref.watch(groupMessagesProvider);
    final peers = peersAsync.valueOrNull ?? const <GroupPeer>[];
    // أسماء كل الأجهزة (حتى المطرودة): رسائل من غادر تبقى منسوبة لاسمه.
    final allNames =
        ref.watch(allDeviceNamesProvider).valueOrNull ?? const <String, String>{};
    final names = {...allNames, for (final p in peers) p.deviceId: p.name};
    final ourId = peers
        .where((p) => p.isSelf)
        .map((p) => p.deviceId)
        .firstOrNull;

    return Scaffold(
      appBar: AppBar(
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('دردشة المجموعة', style: TextStyle(fontSize: 16)),
            Text(
              'للتواصل بين أجهزة المجموعة فقط',
              style: TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ],
        ),
        // شريط الأجهزة: أسماء بخط صغير + شارة حالة ملونة لكل جهاز.
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(40),
          child: Container(
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: peers.isEmpty
                ? const SizedBox.shrink()
                : ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: peers.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 8),
                    itemBuilder: (_, i) => _PeerChip(peer: peers[i]),
                  ),
          ),
        ),
      ),
      body: Column(
        children: [
          // ملاحظة دائمة: نطاق الدردشة داخلي فقط.
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            color: AppColors.infoSoftOf(context),
            child: Row(
              children: [
                Icon(Icons.info_outline,
                    size: 16, color: AppColors.infoOf(context)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'هذه الدردشة للتواصل بين أجهزة المجموعة فقط، ومتاحة '
                    'للجميع حتى بدون صلاحيات — تواصل مع المدير وبقية الأجهزة.',
                    style: TextStyle(
                      fontSize: 11.5,
                      height: 1.5,
                      color: AppColors.infoOf(context),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: msgsAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('$e')),
              data: (msgs) {
                if (msgs.isEmpty) {
                  return const EmptyState(
                    icon: Icons.groups_outlined,
                    title: 'ابدأ محادثة المجموعة',
                    message:
                        'رسائلك تصل فورياً إلى كل أجهزة المجموعة المتصلة.',
                  );
                }
                return ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.all(14),
                  itemCount: msgs.length,
                  itemBuilder: (context, i) {
                    final m = msgs[i];
                    final mine = m.sender == ourId || m.sender == 'me';
                    // من غادر المجموعة تبقى رسائله باسمه (يُوسم «غادر»).
                    final inGroup = peers.any((p) => p.deviceId == m.sender);
                    final known = names[m.sender];
                    return _GroupBubble(
                      message: m,
                      mine: mine,
                      senderName: mine
                          ? 'أنا'
                          : known == null
                              ? 'جهاز غادر المجموعة'
                              : inGroup
                                  ? known
                                  : '$known (غادر المجموعة)',
                    );
                  },
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
                  Expanded(
                    child: TextField(
                      controller: _input,
                      decoration: const InputDecoration(
                        hintText: 'اكتب رسالة للمجموعة...',
                        isDense: true,
                      ),
                      onSubmitted: (_) => _send(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: _sending ? null : _send,
                    icon: _sending
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
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

/// اسم جهاز بخط صغير + شارة حالة ملونة:
/// أخضر = متصل، رمادي = غير متصل، أحمر = موقوف، برتقالي = حساب معلق.
class _PeerChip extends StatelessWidget {
  final GroupPeer peer;
  const _PeerChip({required this.peer});

  @override
  Widget build(BuildContext context) {
    final (color, tip) = peer.suspended
        ? (Colors.red, 'موقوف من المدير')
        : peer.pendingUser
            ? (Colors.orange, 'حسابه معلق — بانتظار تعيين المدير')
            : peer.online
                ? (Colors.green, 'متصل الآن')
                : (Colors.grey, 'غير متصل');
    // ألوان متوافقة مع الثيم: شريط التطبيق فاتح فكان النص الأبيض غير مرئي.
    final onBar = AppColors.textOf(context);
    return Tooltip(
      message: tip,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: AppColors.surface2Of(context),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.borderOf(context)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 9,
              height: 9,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 5),
            Text(
              peer.isSelf ? '${peer.name} (أنا)' : peer.name,
              style: TextStyle(
                fontSize: 11,
                color: onBar,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (peer.isOwner) ...[
              const SizedBox(width: 3),
              const Icon(Icons.security, size: 11, color: Colors.amber),
            ],
          ],
        ),
      ),
    );
  }
}

class _GroupBubble extends StatelessWidget {
  final ChatMessage message;
  final bool mine;
  final String senderName;
  const _GroupBubble({
    required this.message,
    required this.mine,
    required this.senderName,
  });

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: mine ? Alignment.centerLeft : Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * .76,
        ),
        decoration: BoxDecoration(
          color: mine
              ? AppColors.primarySoftOf(context)
              : AppColors.surface2Of(context),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.borderOf(context)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              senderName,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w800,
                color: mine
                    ? AppColors.primaryOf(context)
                    : AppColors.infoOf(context),
              ),
            ),
            const SizedBox(height: 3),
            Text(
              message.body,
              style: const TextStyle(fontSize: 13.5, height: 1.5),
            ),
            const SizedBox(height: 4),
            Text(
              Fmt.dateTime(message.createdAt),
              style: TextStyle(
                fontSize: 10,
                color: AppColors.text3Of(context),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
