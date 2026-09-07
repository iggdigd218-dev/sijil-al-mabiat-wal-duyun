import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/models.dart';
import '../core/app_version.dart';
import '../core/theme.dart';
import '../data/providers.dart';
import 'update_section.dart';
import 'account_form.dart';
import 'accounts_screen.dart';
import 'backup_screen.dart';
import 'chat_screen.dart';
import 'currencies_screen.dart';
import 'dashboard_screen.dart';
import 'inventory_screen.dart';

import 'dart:async';

import 'reports_screen.dart';
import 'settings_screen.dart';
import 'trash_screen.dart';
import 'transactions_screen.dart';
import 'tx_form.dart';
import 'vouchers_screen.dart';
import 'pos_screen.dart';
import 'sync_status_indicator.dart';
import '../data/sync/sync_service.dart';

import 'group_management_screen.dart';
import 'notifications_sheet.dart';

/// كل شاشات التطبيق الاثنتي عشرة.
enum AppScreen {
  dashboard('لوحة التحكم', Icons.dashboard_outlined, Icons.dashboard),
  pos('نقطة البيع (POS)', Icons.point_of_sale_outlined, Icons.point_of_sale),
  accounts('الحسابات', Icons.people_alt_outlined, Icons.people_alt),
  transactions('العمليات', Icons.receipt_long_outlined, Icons.receipt_long),
  vouchers('السندات', Icons.receipt_outlined, Icons.receipt),
  reports('التقارير', Icons.bar_chart_outlined, Icons.bar_chart),
  inventory('المخزون والأصناف', Icons.inventory_2_outlined, Icons.inventory_2),
  currencies(
    'العملات',
    Icons.currency_exchange_outlined,
    Icons.currency_exchange,
  ),
  chat('الدردشة', Icons.forum_outlined, Icons.forum),
  group('إدارة المجموعة', Icons.groups_outlined, Icons.groups),
  trash('سلة المهملات', Icons.delete_outline, Icons.delete),
  activity('سجل النشاط', Icons.history, Icons.history),
  settings('الإعدادات', Icons.settings_outlined, Icons.settings);

  const AppScreen(this.title, this.icon, this.activeIcon);
  final String title;
  final IconData icon;
  final IconData activeIcon;
}

class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  AppScreen _screen = AppScreen.dashboard;
  Future<SyncStatusInfo>? _syncFuture;
  Timer? _syncTimer;
  bool _updatePrompted = false;

  @override
  void initState() {
    super.initState();
    _refreshSync();
    _syncTimer = Timer.periodic(
      const Duration(seconds: 10),
      (_) => _refreshSync(),
    );
    _checkForUpdateOnStart();
  }

  /// فحص تحديث صامت عند الإقلاع: لا يزعج المستخدم إلا إذا وُجد تحديث فعلًا،
  /// ولا يظهر الحوار الاختياري أكثر من مرة واحدة في اليوم.
  Future<void> _checkForUpdateOnStart() async {
    if (_updatePrompted) return;
    _updatePrompted = true;
    try {
      final repo = ref.read(repoProvider);
      final info = await ref.read(updateServiceProvider).check();
      if (!mounted || !info.hasUpdate) return;
      if (!info.isMandatory) {
        // كتم الحوار الاختياري 24 ساعة بعد آخر عرض/تأجيل.
        final st = await repo.settings();
        final last = DateTime.tryParse(st['lastUpdatePrompt'] ?? '');
        if (last != null &&
            DateTime.now().difference(last) < const Duration(hours: 24)) {
          return;
        }
        await repo.setSetting(
            'lastUpdatePrompt', DateTime.now().toIso8601String());
      }
      if (!mounted) return;
      await showUpdateDialog(context, info);
    } catch (_) {
      // الفحص الصامت لا يجب أن يعطّل الإقلاع أبدًا.
    }
  }

  @override
  void dispose() {
    _syncTimer?.cancel();
    super.dispose();
  }

  void _refreshSync() {
    final repo = ref.read(repoProvider);
    final engine = ref.read(syncEngineProvider);
    if (!engine.hasStarted) engine.start();
    setState(() {
      _syncFuture = SyncService(repo: repo, engine: engine).status();
    });
  }

  /// الشاشات الثلاث في الشريط السفلي؛ الوجهة الرابعة «المزيد» تفتح القائمة
  /// الجانبية التي تضم كل الشاشات الأخرى (لا يُخفى أي قسم).
  static const _bottomTabs = [
    AppScreen.dashboard,
    AppScreen.pos,
    AppScreen.accounts,
  ];

  final _scaffoldKey = GlobalKey<ScaffoldState>();

  void _go(AppScreen s) => setState(() => _screen = s);

  Widget _body() => switch (_screen) {
        AppScreen.pos => const PosScreen(),
        AppScreen.dashboard => DashboardScreen(onOpen: _go),
        AppScreen.accounts => const AccountsScreen(),
        AppScreen.transactions => const TransactionsScreen(),
        AppScreen.vouchers => const VouchersScreen(),
        AppScreen.reports => const ReportsScreen(),
        AppScreen.inventory => const InventoryScreen(),
        AppScreen.currencies => const CurrenciesScreen(),
        AppScreen.chat => const ChatScreen(),
        AppScreen.group => const GroupManagementScreen(),
        AppScreen.trash => const TrashScreen(),
        AppScreen.activity => const ActivityScreen(),
        AppScreen.settings => const SettingsScreen(),
      };

  Widget? _fab() {
    final me = ref.watch(currentUserProvider).valueOrNull;
    bool can(String p) => me == null || me.can(p);
    final add = can('add_tx');
    return switch (_screen) {
      AppScreen.accounts => FloatingActionButton.extended(
          onPressed: add ? () => openAccountForm(context, ref) : null,
          icon: const Icon(Icons.add),
          label: const Text('حساب جديد'),
        ),
      AppScreen.transactions => FloatingActionButton.extended(
          onPressed: add
              ? () async {
                  final r = await openTxForm(context, ref);
                  if (r == 'open_pos' && mounted) _go(AppScreen.pos);
                }
              : null,
          icon: const Icon(Icons.add),
          label: const Text('تسجيل عملية'),
        ),
      AppScreen.vouchers => FloatingActionButton.extended(
          onPressed: add ? () => openVoucherForm(context, ref) : null,
          icon: const Icon(Icons.add),
          label: const Text('سند جديد'),
        ),
      AppScreen.inventory => FloatingActionButton.extended(
          onPressed: add ? () => openItemCategoryForm(context, ref) : null,
          icon: const Icon(Icons.create_new_folder_outlined),
          label: const Text('فئة جديدة'),
        ),
      _ => null,
    };
  }

  @override
  Widget build(BuildContext context) {
    final hidden = ref.watch(hideBalancesProvider);
    final tabIndex = _bottomTabs.indexOf(_screen);

    return Scaffold(
      key: _scaffoldKey,
      appBar: AppBar(
        title: Text(_screen == AppScreen.dashboard ? 'مدير الحسابات' : _screen.title),
        actions: [
          // شارة دور المستخدم الحالي (تظهر في الوضع المُدار فقط).
          Consumer(
            builder: (ctx, rref, _) {
              final modeAsync = rref.watch(workspaceModeProvider);
              final roleAsync = rref.watch(deviceRoleProvider);
              final mode = modeAsync.valueOrNull ?? 'standalone';
              if (mode == 'standalone') return const SizedBox.shrink();
              final role = roleAsync.valueOrNull;
              final (label, color, icon) = switch (role?.role) {
                UserRole.admin => (
                    'مدير',
                    Colors.amber.shade700,
                    Icons.security,
                  ),
                UserRole.accountant => ('محاسب', Colors.blue, Icons.calculate),
                UserRole.dataentry => ('إدخال', Colors.teal, Icons.edit_note),
                UserRole.viewer => (
                    'عرض فقط',
                    Colors.grey,
                    Icons.visibility_outlined,
                  ),
                _ => ('بلا صلاحية', Colors.red, Icons.block),
              };
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Tooltip(
                  message: mode == 'host'
                      ? 'أنت مدير هذه المجموعة'
                      : 'دورك في المجموعة: $label',
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: .12),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: color.withValues(alpha: .3)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(icon, size: 13, color: color),
                        const SizedBox(width: 4),
                        Text(
                          label,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: color,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
          // مؤشر المزامنة: يختفي في الوضع المستقل (جهاز واحد لا مجموعة).
          Consumer(
            builder: (ctx, rref, _) {
              final modeAsync = rref.watch(workspaceModeProvider);
              final isOwnerAsync = rref.watch(isOwnerProvider);
              final mode = modeAsync.valueOrNull ?? 'standalone';
              final isOwner = isOwnerAsync.valueOrNull ?? true;
              if (mode == 'standalone') return const SizedBox.shrink();
              return FutureBuilder<SyncStatusInfo>(
                future: _syncFuture,
                builder: (ctx, snap) {
                  if (!snap.hasData) return const SizedBox.shrink();
                  return SyncStatusBadge(
                    info: snap.data!,
                    onTap: () =>
                        _go(isOwner ? AppScreen.group : AppScreen.settings),
                  );
                },
              );
            },
          ),
          // جرس الإشعارات الداخلية مع شارة العدد غير المقروء.
          Consumer(
            builder: (ctx, rref, _) {
              final unread = rref.watch(unreadCountProvider).valueOrNull ?? 0;
              return IconButton(
                tooltip: 'الإشعارات',
                icon: Badge(
                  isLabelVisible: unread > 0,
                  label: Text('$unread'),
                  child: const Icon(Icons.notifications_outlined),
                ),
                onPressed: () => openNotifications(context, ref),
              );
            },
          ),
          IconButton(
            tooltip: hidden ? 'إظهار الأرصدة' : 'إخفاء الأرصدة',
            icon: Icon(
              hidden
                  ? Icons.visibility_off_outlined
                  : Icons.visibility_outlined,
            ),
            onPressed: () =>
                ref.read(hideBalancesProvider.notifier).state = !hidden,
          ),
        ],
      ),
      drawer: _Drawer(current: _screen, onSelect: _go),
      body: _body(),
      floatingActionButton: _fab(),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tabIndex < 0 ? 0 : tabIndex,
        onDestinationSelected: (i) {
          if (i < _bottomTabs.length) {
            _go(_bottomTabs[i]);
          } else {
            // وجهة «المزيد» — تفتح القائمة الجانبية بكل الأقسام.
            _scaffoldKey.currentState?.openDrawer();
          }
        },
        destinations: [
          NavigationDestination(
            icon: const Icon(Icons.home_outlined),
            selectedIcon: const Icon(Icons.home_rounded),
            label: 'الرئيسية',
          ),
          NavigationDestination(
            icon: Icon(AppScreen.pos.icon),
            selectedIcon: Icon(AppScreen.pos.activeIcon),
            label: 'المبيعات',
          ),
          NavigationDestination(
            icon: Icon(AppScreen.accounts.icon),
            selectedIcon: Icon(AppScreen.accounts.activeIcon),
            label: 'الحسابات',
          ),
          const NavigationDestination(
            icon: Icon(Icons.apps_rounded),
            selectedIcon: Icon(Icons.grid_view_rounded),
            label: 'المزيد',
          ),
        ],
      ),
    );
  }
}

class _Drawer extends ConsumerWidget {
  final AppScreen current;
  final void Function(AppScreen) onSelect;
  const _Drawer({required this.current, required this.onSelect});

  /// لون مميز لكل قسم (كما في التصميم المرجعي).
  Color _colorOf(AppScreen s) => switch (s) {
        AppScreen.dashboard => const Color(0xFF2563EB),
        AppScreen.transactions => const Color(0xFF0EA5E9),
        AppScreen.accounts => const Color(0xFF2563EB),
        AppScreen.reports => const Color(0xFF6366F1),
        AppScreen.settings => const Color(0xFF64748B),
        AppScreen.inventory => const Color(0xFF8B5CF6),
        AppScreen.currencies => const Color(0xFF0D9488),
        AppScreen.vouchers => const Color(0xFFF59E0B),
        AppScreen.pos => const Color(0xFF16A34A),
        AppScreen.chat => const Color(0xFF22C55E),
        AppScreen.group => const Color(0xFF8B5CF6),
        AppScreen.trash => const Color(0xFFE11D48),
        AppScreen.activity => const Color(0xFF64748B),
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider).valueOrNull;
    final isOwner = ref.watch(isOwnerProvider).valueOrNull ?? true;
    final items = _DrawerItems.of(user: user, isOwner: isOwner);
    final dark = Theme.of(context).brightness == Brightness.dark;

    return Drawer(
      backgroundColor: AppColors.surfaceOf(context),
      child: SafeArea(
        child: Column(
          children: [
            // ---------- ترويسة الملف الشخصي ----------
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(16, 18, 16, 16),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFF1E3A5F), Color(0xFF0F766E)],
                ),
                borderRadius: const BorderRadius.only(
                  bottomLeft: Radius.circular(22),
                  bottomRight: Radius.circular(22),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 54,
                        height: 54,
                        decoration: BoxDecoration(
                          color: Colors.white24,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white38, width: 2),
                        ),
                        child: const Icon(Icons.person,
                            color: Colors.white, size: 30),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              user?.name ?? 'مدير الحسابات',
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w800,
                                fontSize: 16,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 2),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: .18),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Text(
                                user == null ? 'المدير' : '${user.role.icon} ${user.role.label}',
                                style: const TextStyle(
                                    color: Colors.white, fontSize: 11),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            // ---------- عناصر القائمة ----------
            Expanded(
              child: ListView(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                children: [
                  // اختصار الرئيسية دائمًا في الأعلى (كما الصورة).
                  if (!items.contains(AppScreen.dashboard))
                    _DrawerTile(
                      screen: AppScreen.dashboard,
                      active: current == AppScreen.dashboard,
                      color: _colorOf(AppScreen.dashboard),
                      dark: dark,
                      onTap: () {
                        Navigator.pop(context);
                        scheduleMicrotask(
                            () => onSelect(AppScreen.dashboard));
                      },
                    ),
                  for (final s in items)
                    _DrawerTile(
                      screen: s,
                      active: current == s,
                      color: _colorOf(s),
                      dark: dark,
                      onTap: () {
                        Navigator.pop(context);
                        scheduleMicrotask(() => onSelect(s));
                      },
                    ),
                ],
              ),
            ),
            const Divider(height: 1),
            // ---------- خدمة العملاء (واتساب) ----------
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
              child: Material(
                color: const Color(0xFFE7F7EE),
                borderRadius: BorderRadius.circular(14),
                child: InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: () async {
                    final uri = Uri.parse(
                      'https://wa.me/967774190040?text=${Uri.encodeComponent('السلام عليكم، أحتاج الدعم الفني لتطبيق مدير الحسابات.')}',
                    );
                    final ok = await canLaunchUrl(uri);
                    if (ok) {
                      await launchUrl(uri,
                          mode: LaunchMode.externalApplication);
                    }
                  },
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                    child: Row(
                      children: [
                        Container(
                          width: 38,
                          height: 38,
                          decoration: BoxDecoration(
                            color: const Color(0xFF25D366),
                            borderRadius: BorderRadius.circular(11),
                          ),
                          child: const Icon(Icons.support_agent_rounded,
                              color: Colors.white, size: 22),
                        ),
                        const SizedBox(width: 12),
                        const Expanded(
                          child: Text(
                            'خدمة العملاء',
                            style: TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 14,
                              color: Color(0xFF128C4B),
                            ),
                          ),
                        ),
                        const Icon(Icons.chat_bubble_outline_rounded,
                            color: Color(0xFF128C4B), size: 20),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            // ---------- تسجيل الخروج ----------
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Material(
                color: AppColors.dangerSoftOf(context),
                borderRadius: BorderRadius.circular(14),
                child: InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: () => Navigator.pop(context),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                    child: Row(
                      children: [
                        Icon(Icons.logout_rounded,
                            color: AppColors.dangerOf(context), size: 22),
                        const SizedBox(width: 12),
                        Text(
                          'تسجيل الخروج',
                          style: TextStyle(
                            color: AppColors.dangerOf(context),
                            fontWeight: FontWeight.w800,
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(appVersionLabel,
                  style: TextStyle(
                      fontSize: 10.5, color: AppColors.text3Of(context))),
            ),
          ],
        ),
      ),
    );
  }
}

/// صف عنصر في القائمة الجانبية بتصميم البطاقة النشطة.
class _DrawerTile extends StatelessWidget {
  final AppScreen screen;
  final bool active;
  final Color color;
  final bool dark;
  final VoidCallback onTap;
  const _DrawerTile({
    required this.screen,
    required this.active,
    required this.color,
    required this.dark,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Material(
        color: active
            ? AppColors.infoSoftOf(context)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: active
                  ? Border.all(color: AppColors.infoOf(context), width: 1.4)
                  : null,
            ),
            child: Row(
              children: [
                Icon(active ? screen.activeIcon : screen.icon,
                    color: active ? AppColors.infoOf(context) : color,
                    size: 22),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    screen.title,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: active ? FontWeight.w800 : FontWeight.w700,
                      color: active
                          ? AppColors.infoOf(context)
                          : AppColors.textOf(context),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// عناصر الدرج: كل الشاشات ما عدا الموجودة في الشريط السفلي، حتى لا تتكرر
/// الأيقونة نفسها في مكانين. إدارة المجموعة للمدير فقط.
class _DrawerItems {
  static List<AppScreen> of({AppUser? user, required bool isOwner}) =>
      AppScreen.values
          .where((s) => !_HomeShellState._bottomTabs.contains(s))
          .where((s) {
        if (s == AppScreen.group) return isOwner;
        return true;
      }).toList();
}
