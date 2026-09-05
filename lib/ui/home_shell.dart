import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/accounting.dart';
import '../core/models.dart';
import '../core/theme.dart';
import '../data/providers.dart';
import 'account_form.dart';
import 'accounts_screen.dart';
import 'backup_screen.dart';
import 'chat_screen.dart';
import 'currencies_screen.dart';
import 'devices_screen.dart';
import 'dashboard_screen.dart';
import 'inventory_screen.dart';
import 'dart:async';
import 'reports_screen.dart';
import 'settings_screen.dart';
import 'trash_screen.dart';
import 'transactions_screen.dart';
import 'tx_form.dart';
import 'users_screen.dart';
import 'vouchers_screen.dart';
import 'pos_screen.dart';
import 'sync_status_indicator.dart';
import '../data/sync/sync_service.dart';

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
      'العملات', Icons.currency_exchange_outlined, Icons.currency_exchange),
  chat('الدردشة', Icons.forum_outlined, Icons.forum),
  users('المستخدمون والصلاحيات', Icons.manage_accounts_outlined,
      Icons.manage_accounts),
  devices('الأجهزة المرتبطة', Icons.devices, Icons.devices),
  backup('النسخ الاحتياطي', Icons.backup_outlined, Icons.backup),
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

  @override
  void initState() {
    super.initState();
    _refreshSync();
    _syncTimer = Timer.periodic(const Duration(seconds: 10), (_) => _refreshSync());
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

  /// الشاشات الخمس في الشريط السفلي؛ الباقي من القائمة الجانبية.
  static const _tabs = [
    AppScreen.dashboard,
    AppScreen.accounts,
    AppScreen.transactions,
    AppScreen.vouchers,
    AppScreen.reports,
  ];

  /// الشاشات الإضافية المجمّعة في قائمة «ثلاث نقاط» أعلى الواجهة.
  static const _moreItems = [
    AppScreen.pos,
    AppScreen.inventory,
    AppScreen.currencies,
    AppScreen.chat,
    AppScreen.users,
    AppScreen.backup,
    AppScreen.activity,
    AppScreen.trash,
    AppScreen.settings,
  ];

  void _go(AppScreen s) => setState(() => _screen = s);

  /// قائمة زر الإضافة الكبير: فاتورة مبيعات (قَبض/إيراد) أو عملية أخرى.
  Future<void> _showAddTxMenu(BuildContext context, WidgetRef ref) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text('إضافة عملية جديدة',
                  style: Theme.of(ctx).textTheme.titleMedium),
            ),
            ListTile(
              leading: const Icon(Icons.point_of_sale, color: AppColors.primary),
              title: const Text('فاتورة مبيعات (قبض)',
                  style: TextStyle(fontWeight: FontWeight.w800)),
              subtitle: const Text('بيع نقداً أو قبض دفعة من عميل'),
              onTap: () {
                Navigator.pop(ctx);
                openTxForm(context, ref, presetType: OpType.inflow);
              },
            ),
            ListTile(
              leading: const Icon(Icons.receipt_long_outlined),
              title: const Text('عملية أخرى',
                  style: TextStyle(fontWeight: FontWeight.w800)),
              subtitle: const Text(
                  'صرف، دين عليه (آجل)، تسوية، تحويل، مصروف… مع كل الأنواع'),
              onTap: () {
                Navigator.pop(ctx);
                openTxForm(context, ref);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _body() => switch (_screen) {
        AppScreen.pos => const PosScreen(),
        AppScreen.dashboard => DashboardScreen(
            onNavigate: (i) => _go(_tabs[i.clamp(0, _tabs.length - 1)]),
          ),
        AppScreen.accounts => const AccountsScreen(),
        AppScreen.transactions => const TransactionsScreen(),
        AppScreen.vouchers => const VouchersScreen(),
        AppScreen.reports => const ReportsScreen(),
        AppScreen.inventory => const InventoryScreen(),
        AppScreen.currencies => const CurrenciesScreen(),
        AppScreen.chat => const ChatScreen(),
        AppScreen.users => const UsersScreen(),
        AppScreen.devices => const DevicesScreen(),
        AppScreen.backup => const BackupScreen(),
        AppScreen.trash => const TrashScreen(),
        AppScreen.activity => const ActivityScreen(),
        AppScreen.settings => const SettingsScreen(),
      };

  Widget? _fab() {
    final me = ref.watch(currentUserProvider).valueOrNull;
    final users = ref.watch(usersProvider).valueOrNull ?? const [];
    bool can(String p) => me == null || me.can(p);
    final add = can('add_tx');
    // إدارة المستخدمين للمدير فقط، إلا إذا لا يوجد أي مدير/لا مستخدمين بعد
    // (باب استرداد/بذرة) فيبقى الزر متاحاً لإنشاء مدير وإنقاذ النظام.
    final hasAdmin = users.any((u) => u.role == UserRole.admin);
    final manageUsers =
        can('manage_users') || !hasAdmin || users.isEmpty;
    final manageBackup = can('manage_backup');
    return switch (_screen) {
        AppScreen.accounts => FloatingActionButton.extended(
            onPressed: add ? () => openAccountForm(context, ref) : null,
            icon: const Icon(Icons.add),
            label: const Text('حساب جديد'),
          ),
        AppScreen.transactions => FloatingActionButton.extended(
            onPressed: add ? () => _showAddTxMenu(context, ref) : null,
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
        AppScreen.users => FloatingActionButton.extended(
            onPressed: manageUsers ? () => openUserForm(context, ref) : null,
            icon: const Icon(Icons.person_add_alt),
            label: const Text('مستخدم'),
          ),
        _ => null,
    };
  }

  @override
  Widget build(BuildContext context) {
    final hidden = ref.watch(hideBalancesProvider);
    final tabIndex = _tabs.indexOf(_screen);

    return Scaffold(
      appBar: AppBar(
        title: Text(_screen.title),
        actions: [
          FutureBuilder<SyncStatusInfo>(
            future: _syncFuture,
            builder: (ctx, snap) {
              if (!snap.hasData) return const SizedBox.shrink();
              return SyncStatusBadge(
                info: snap.data!,
                onTap: () => _go(AppScreen.settings),
              );
            },
          ),
          // قائمة «ثلاث نقاط» تجمع كل الشاشات/الاختصارات الإضافية (المدمجة)
          // حتى يبقى الشريط السفلي مرتّباً بالاختصارات الأساسية فقط.
          PopupMenuButton<AppScreen>(
            tooltip: 'كل الأقسام والاختصارات',
            icon: const Icon(Icons.more_vert),
            onSelected: (s) => _go(s),
            itemBuilder: (context) {
              final items = <PopupMenuEntry<AppScreen>>[];
              for (final s in _moreItems) {
                final active = s == _screen;
                items.add(PopupMenuItem(
                  value: s,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        active ? s.activeIcon : s.icon,
                        color: active
                            ? AppColors.primaryOf(context)
                            : AppColors.text2Of(context),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        s.title,
                        style: TextStyle(
                          fontWeight:
                              active ? FontWeight.w800 : FontWeight.w600,
                          color: active
                              ? AppColors.primaryOf(context)
                              : AppColors.textOf(context),
                        ),
                      ),
                    ],
                  ),
                ));
              }
              return items;
            },
          ),
          IconButton(
            tooltip: hidden ? 'إظهار الأرصدة' : 'إخفاء الأرصدة',
            icon: Icon(hidden
                ? Icons.visibility_off_outlined
                : Icons.visibility_outlined),
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
        onDestinationSelected: (i) => _go(_tabs[i]),
        destinations: _tabs
            .map((s) => NavigationDestination(
                  icon: Icon(s.icon),
                  selectedIcon: Icon(s.activeIcon),
                  label: s == AppScreen.dashboard ? 'الرئيسية' : s.title,
                ))
            .toList(),
      ),
    );
  }
}

class _Drawer extends ConsumerWidget {
  final AppScreen current;
  final void Function(AppScreen) onSelect;
  const _Drawer({required this.current, required this.onSelect});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider).valueOrNull;

    return Drawer(
      child: SafeArea(
        child: Column(
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(20),
              color: AppColors.primarySoftOf(context),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(14),
                        child: Image.asset('assets/images/logo.png',
                            width: 52, height: 52, fit: BoxFit.cover),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('إدارة البيانات',
                                style: TextStyle(
                                    fontWeight: FontWeight.w800,
                                    fontSize: 16,
                                    color: AppColors.primaryOf(context))),
                            Text(
                              user == null
                                  ? 'النظام المحاسبي'
                                  : '${user.role.icon} ${user.name}',
                              style: TextStyle(
                                  fontSize: 12,
                                  color: AppColors.text2Of(context)),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: 8),
                children: _DrawerItems.of(user: user).map((s) {
                  final active = s == current;
                  return ListTile(
                    leading: Icon(active ? s.activeIcon : s.icon,
                        color: active
                            ? AppColors.primaryOf(context)
                            : AppColors.text2Of(context)),
                    title: Text(
                      s.title,
                      style: TextStyle(
                        fontWeight: active ? FontWeight.w800 : FontWeight.w600,
                        fontSize: 14,
                        color: active
                            ? AppColors.primaryOf(context)
                            : AppColors.textOf(context),
                      ),
                    ),
                    selected: active,
                    selectedTileColor: AppColors.primarySoftOf(context),
                    onTap: () {
                      Navigator.pop(context);
                      // نؤجّل التبديل حتى يُغلق الدرج فلا تهتزّ الواجهة.
                      scheduleMicrotask(() => onSelect(s));
                    },
                  );
                }).toList(),
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                'الإصدار 3.4.0',
                style:
                    TextStyle(fontSize: 11, color: AppColors.text3Of(context)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// عناصر الدرج: كل الشاشات ما عدا الموجودة في الشريط السفلي، حتى لا تتكرر
/// الأيقونة نفسها في مكانين (البند ٥ من ملاحظات المستخدم).
class _DrawerItems {
  static List<AppScreen> of({AppUser? user}) => AppScreen.values
      .where((s) => !_HomeShellState._tabs.contains(s))
      // شاشتا المستخدمين والأجهزة محجوزتان لمن يملك صلاحية manage_users.
      .where((s) {
        if ((s == AppScreen.users || s == AppScreen.devices) &&
            user != null &&
            !user.can('manage_users')) {
          return false;
        }
        return true;
      })
      .toList();
}
