import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/format.dart';
import '../core/media_paths.dart';
import '../core/models.dart';
import '../core/theme.dart';
import '../data/providers.dart';
import 'barcode_scanner.dart';
import 'calculator.dart';
import 'widgets.dart';

/// شاشة بيانات الأصناف والفئات فقط.
///
/// تبدأ الفئات/الأقسام هنا أولًا. يمكن إنشاء عدد غير محدود من الفئات،
/// ثم إضافة الأصناف داخل كل فئة. لا تُسجّل هذه الشاشة شراءً أو بيعًا أو
/// مرتجعًا أو تسوية أو أي حركة مخزنية؛ فهي مخصّصة للبيانات الأساسية فقط.
// ══════════════════════════════════════════════════════════════════════════
// (2026-09-22) تطوير شاشة المخزون والأصناف
//   • شريط أدوات: بحث نصي لحظي + زر كاميرا لمسح الباركود.
//   • فلاتر شجرية: فئات رئيسية (Chips) ← فئات فرعية («الكل» + الأبناء).
//   • فرز متقدم بتسعة معايير، يُطبَّق محلياً فوراً بلا شبكة.
//   • نمطا عرض: قائمة تفصيلية / شبكة بطاقات، مع حفظ التفضيل محلياً.
// ══════════════════════════════════════════════════════════════════════════

/// مفتاح حفظ نمط العرض المفضل في جدول settings.
const String kInventoryViewModeKey = 'inventory.viewMode';

/// معايير الفرز المتاحة في شاشة الأصناف.
enum _SortKey {
  nameAsc('الاسم (أ - ي)', Icons.sort_by_alpha),
  nameDesc('الاسم (ي - أ)', Icons.sort_by_alpha),
  qtyAsc('الأقل كمية', Icons.trending_down),
  qtyDesc('الأكثر كمية', Icons.trending_up),
  outFirst('المنتهية أولاً', Icons.remove_shopping_cart_outlined),
  priceDesc('الأعلى سعراً', Icons.arrow_upward_rounded),
  priceAsc('الأقل سعراً', Icons.arrow_downward_rounded),
  newest('الأحدث إضافةً', Icons.fiber_new_outlined),
  oldest('الأقدم', Icons.history_toggle_off_outlined);

  const _SortKey(this.label, this.icon);

  final String label;
  final IconData icon;

  /// هل هذا الفرز يتعلق بالكمية/المخزون؟
  bool get isStock =>
      this == _SortKey.qtyAsc ||
      this == _SortKey.qtyDesc ||
      this == _SortKey.outFirst;
}

/// مقارنة صنفين حسب المفتاح — كلها محلية وبلا أي شبكة.
int _compareItems(Item a, Item b, _SortKey key) {
  int byName(String x, String y) =>
      x.trim().toLowerCase().compareTo(y.trim().toLowerCase());
  return switch (key) {
    _SortKey.nameAsc => byName(a.name, b.name),
    _SortKey.nameDesc => byName(b.name, a.name),
    _SortKey.qtyAsc => a.quantity.compareTo(b.quantity),
    _SortKey.qtyDesc => b.quantity.compareTo(a.quantity),
    // المنتهية أولاً: الكمية صفر في المقدمة، ثم الأقرب لحد الطلب.
    _SortKey.outFirst => () {
        final ao = a.quantity <= 0 ? 0 : 1;
        final bo = b.quantity <= 0 ? 0 : 1;
        final c = ao.compareTo(bo);
        return c != 0 ? c : a.quantity.compareTo(b.quantity);
      }(),
    _SortKey.priceDesc => b.sellPrice.compareTo(a.sellPrice),
    _SortKey.priceAsc => a.sellPrice.compareTo(b.sellPrice),
    _SortKey.newest => b.createdAt.compareTo(a.createdAt),
    _SortKey.oldest => a.createdAt.compareTo(b.createdAt),
  };
}

/// شاشة بيانات الأصناف والفئات فقط.
///
/// تبدأ الفئات/الأقسام هنا أولًا (فئة رئيسية وفئات فرعية)، ثم تُسجَّل
/// الأصناف داخلها. لا تُسجّل هذه الشاشة شراءً أو بيعًا أو مرتجعًا أو
/// تسوية أو أي حركة مخزنية؛ فهي مخصّصة للبيانات الأساسية فقط.
class InventoryScreen extends ConsumerStatefulWidget {
  const InventoryScreen({super.key});

  @override
  ConsumerState<InventoryScreen> createState() => _InventoryScreenState();
}

class _InventoryScreenState extends ConsumerState<InventoryScreen> {
  String _mode = 'list';
  _SortKey _sort = _SortKey.nameAsc;
  int? _rootId; // الفئة الرئيسية المختارة (null = الكل)
  int? _subId; // الفئة الفرعية المختارة (null = كل ما تحت الرئيسية)

  @override
  void initState() {
    super.initState();
    _loadPreferredMode();
  }

  /// نمط العرض المفضل محفوظ في التفضيلات المحلية (settings).
  Future<void> _loadPreferredMode() async {
    try {
      final st = await ref.read(repoProvider).settings();
      final m = (st[kInventoryViewModeKey] ?? '').trim();
      if (!mounted || (m != 'grid' && m != 'list')) return;
      setState(() => _mode = m);
    } catch (_) {}
  }

  Future<void> _setMode(String mode) async {
    if (_mode == mode) return;
    setState(() => _mode = mode);
    try {
      await ref.read(repoProvider).setSetting(kInventoryViewModeKey, mode);
    } catch (_) {}
  }

  void _selectRoot(int? id) => setState(() {
        _rootId = id;
        _subId = null;
      });

  void _selectSub(int? id) => setState(() => _subId = id);

  /// معرّفات الفئات المطلوب عرضها (null = كل الأصناف).
  Set<int>? _selectedIds(List<ItemCategory> roots) {
    if (_subId != null) return <int>{_subId!};
    if (_rootId == null) return null;
    final ids = <int>{_rootId!};
    for (final r in roots) {
      if (r.id != _rootId) continue;
      for (final c in r.children) {
        if (c.id != null) ids.add(c.id!);
      }
    }
    return ids;
  }

  List<Item> _visibleItems(List<ItemCategory> roots, List<Item> items) {
    final ids = _selectedIds(roots);
    final q = ref.read(itemQueryProvider).trim().toLowerCase();
    final out = items.where((it) {
      if (ids != null &&
          (it.categoryId == null || !ids.contains(it.categoryId))) {
        return false;
      }
      if (q.isEmpty) return true;
      return it.name.toLowerCase().contains(q) ||
          it.sku.toLowerCase().contains(q) ||
          it.category.toLowerCase().contains(q) ||
          it.notes.toLowerCase().contains(q);
    }).toList()
      ..sort((a, b) => _compareItems(a, b, _sort));
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final categoriesAsync = ref.watch(itemCategoryTreeProvider);
    final itemsAsync = ref.watch(itemsProvider);

    return Column(
      children: [
        _InventoryToolbar(
          mode: _mode,
          sort: _sort,
          onModeChanged: _setMode,
          onSortChanged: (k) => setState(() => _sort = k),
          onAddCategory: () => openItemCategoryForm(context, ref),
        ),
        categoriesAsync.when(
          loading: () => const SizedBox(
            height: 54,
            child: Center(child: SizedBox.shrink()),
          ),
          error: (_, __) => const SizedBox.shrink(),
          data: (roots) => _CategoryChipBar(
            roots: roots,
            rootId: _rootId,
            subId: _subId,
            onRoot: _selectRoot,
            onSub: _selectSub,
            onAddCategory: () => openItemCategoryForm(context, ref),
            onManage: () => openCategoryManager(context, ref, roots),
          ),
        ),
        Expanded(
          child: categoriesAsync.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => EmptyState(
              icon: Icons.error_outline,
              title: 'تعذّر تحميل الفئات',
              message: '$e',
            ),
            data: (roots) => itemsAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => EmptyState(
                icon: Icons.error_outline,
                title: 'تعذّر تحميل الأصناف',
                message: '$e',
              ),
              data: (items) => _buildBody(context, roots, items),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildBody(
    BuildContext context,
    List<ItemCategory> roots,
    List<Item> items,
  ) {
    if (roots.isEmpty && items.isEmpty) {
      return EmptyState(
        icon: Icons.create_new_folder_outlined,
        title: 'ابدأ بإضافة فئة',
        message: 'أنشئ أقسامًا غير محدودة، وبعدها أضف كل صنف داخل قسمه.',
        action: FilledButton.icon(
          onPressed: () => openItemCategoryForm(context, ref),
          icon: const Icon(Icons.add),
          label: const Text('إضافة أول فئة'),
        ),
      );
    }
    final visible = _visibleItems(roots, items);
    if (visible.isEmpty) {
      return EmptyState(
        icon: Icons.search_off,
        title: 'لا توجد نتائج',
        message: 'جرّب كلمة بحث أخرى أو بدّل الفئة.',
        action: FilledButton.tonalIcon(
          onPressed: () {
            ref.read(itemQueryProvider.notifier).state = '';
            setState(() {
              _rootId = null;
              _subId = null;
            });
          },
          icon: const Icon(Icons.filter_alt_off_outlined, size: 18),
          label: const Text('مسح الفلاتر'),
        ),
      );
    }
    const pad = EdgeInsets.fromLTRB(12, 4, 12, 96);
    // عدد الأعمدة حسب العرض: هاتف 2 · لوحي 3 · حاسوب 4.
    final w = MediaQuery.sizeOf(context).width;
    final cols = w >= 900 ? 4 : (w >= 600 ? 3 : 2);
    final child = _mode == 'grid'
        ? GridView.builder(
            padding: pad,
            itemCount: visible.length,
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: cols,
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              childAspectRatio: cols >= 4 ? .95 : .82,
            ),
            itemBuilder: (_, i) => _ItemGridCard(item: visible[i]),
          )
        : ListView.builder(
            padding: pad,
            itemCount: visible.length,
            itemBuilder: (_, i) => _ItemTile(item: visible[i]),
          );
    return RefreshIndicator(
      onRefresh: () async => bump(ref),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 2),
            child: Row(
              children: [
                Text(
                  '${visible.length} من ${items.length} صنف',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: AppColors.text2Of(context),
                  ),
                ),
                const Spacer(),
                Text(
                  '${roots.length} فئة رئيسية',
                  style: TextStyle(
                    fontSize: 12.5,
                    color: AppColors.text3Of(context),
                  ),
                ),
              ],
            ),
          ),
          Expanded(child: child),
        ],
      ),
    );
  }
}

/// شريط الأدوات: بحث + باركود + فرز + تبديل نمط العرض.
class _InventoryToolbar extends ConsumerWidget {
  final String mode;
  final _SortKey sort;
  final ValueChanged<String> onModeChanged;
  final ValueChanged<_SortKey> onSortChanged;
  final VoidCallback onAddCategory;

  const _InventoryToolbar({
    required this.mode,
    required this.sort,
    required this.onModeChanged,
    required this.onSortChanged,
    required this.onAddCategory,
  });

  Future<void> _scan(BuildContext context, WidgetRef ref) async {
    try {
      final code = await scanBarcode(context);
      if (code == null || code.isEmpty || !context.mounted) return;
      ref.read(itemQueryProvider.notifier).state = code;
      showSnack(context, '🔎 تم مسح الرمز: $code');
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final q = ref.watch(itemQueryProvider);
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: TextEditingController(text: q)
                    ..selection = TextSelection.collapsed(offset: q.length),
                  decoration: InputDecoration(
                    hintText: 'ابحث بالاسم أو الباركود أو الفئة',
                    prefixIcon: const Icon(Icons.search),
                    isDense: true,
                    suffixIcon: q.isEmpty
                        ? null
                        : IconButton(
                            tooltip: 'مسح البحث',
                            icon: const Icon(Icons.clear),
                            onPressed: () =>
                                ref.read(itemQueryProvider.notifier).state = '',
                          ),
                  ),
                  onChanged: (v) =>
                      ref.read(itemQueryProvider.notifier).state = v,
                ),
              ),
              const SizedBox(width: 8),
              // زر الكاميرا: مسح الباركود فوراً (نفس ماسح التطبيق).
              Container(
                decoration: BoxDecoration(
                  color: AppColors.primarySoftOf(context),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: IconButton(
                  tooltip: 'مسح الباركود',
                  onPressed: () => _scan(context, ref),
                  icon: Icon(
                    Icons.qr_code_scanner_rounded,
                    color: AppColors.primaryOf(context),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // (2026-09-22) صفٌّ قابل للالتفاف: على الشاشات الضيقة (360px)
          // ينزل مبدّل العرض إلى سطر ثانٍ بدل فيض أفقي يقصف الشاشة.
          LayoutBuilder(
            builder: (context, box) {
              final wide = box.maxWidth >= 380;
              return Wrap(
                spacing: 8,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  _SortButton(sort: sort, wide: wide, onChanged: onSortChanged),
                  _ViewModeToggle(
                      mode: mode, wide: wide, onChanged: onModeChanged),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

/// زر الفرز المنسدل [⇅ فرز حسب...].
class _SortButton extends StatelessWidget {
  final _SortKey sort;
  final bool wide;
  final ValueChanged<_SortKey> onChanged;

  const _SortButton(
      {required this.sort, required this.wide, required this.onChanged});

  @override
  Widget build(BuildContext context) => ConstrainedBox(
        constraints: BoxConstraints(maxWidth: wide ? 210 : 150),
        child: PopupMenuButton<_SortKey>(
          tooltip: 'ترتيب النتائج',
          initialValue: sort,
          onSelected: onChanged,
          itemBuilder: (_) => [
            for (final k in _SortKey.values)
              PopupMenuItem<_SortKey>(
                value: k,
                child: Row(
                  children: [
                    Icon(k.icon, size: 18),
                    const SizedBox(width: 8),
                    Expanded(child: Text(k.label)),
                    if (k == sort)
                      Icon(Icons.check,
                          size: 18, color: AppColors.primaryOf(context)),
                  ],
                ),
              ),
          ],
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(
              border: Border.all(color: AppColors.borderOf(context)),
              borderRadius: BorderRadius.circular(11),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('⇅', style: TextStyle(fontWeight: FontWeight.w800)),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    wide ? 'فرز: ${sort.label}' : sort.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12.5),
                  ),
                ),
                const Icon(Icons.arrow_drop_down, size: 20),
              ],
            ),
          ),
        ),
      );
}

/// مبدّل نمط العرض (قائمة / شبكة) — أيقونات فقط على الشاشات الضيقة.
class _ViewModeToggle extends StatelessWidget {
  final String mode;
  final bool wide;
  final ValueChanged<String> onChanged;

  const _ViewModeToggle(
      {required this.mode, required this.wide, required this.onChanged});

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 36,
        child: SegmentedButton<String>(
          segments: [
            ButtonSegment<String>(
              value: 'list',
              icon: const Icon(Icons.view_list_rounded, size: 18),
              label: wide ? const Text('قائمة') : null,
            ),
            ButtonSegment<String>(
              value: 'grid',
              icon: const Icon(Icons.grid_view_rounded, size: 18),
              label: wide ? const Text('شبكة') : null,
            ),
          ],
          selected: <String>{mode},
          showSelectedIcon: false,
          style: SegmentedButton.styleFrom(
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            textStyle: const TextStyle(fontSize: 12.5),
          ),
          onSelectionChanged: (s) => onChanged(s.first),
        ),
      );
}

/// (2026-09-22) لوح إدارة الفئات: تعديل الاسم، إضافة فئة فرعية، والحذف
/// مع ترقية الأبناء — كان الوصول إليها من بطاقة الفئة القديمة فقط.
Future<void> openCategoryManager(
  BuildContext context,
  WidgetRef ref,
  List<ItemCategory> roots,
) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (ctx) {
        // ارتفاع صريح (70٪ من الشاشة) بدل DraggableScrollableSheet داخل
        // صحيفة سفلية — الأخير ينهار إلى صفر حين يقيس نفسه بلا قيد.
        final h = MediaQuery.sizeOf(ctx).height * .70;
        return SizedBox(
          height: h,
          child: _CategoryManager(roots: roots),
        );
      },
    ).whenComplete(() => bump(ref));

class _CategoryManager extends ConsumerWidget {
  final List<ItemCategory> roots;

  const _CategoryManager({required this.roots});

  Future<void> _delete(BuildContext context, WidgetRef ref, ItemCategory c) async {
    final ok = await confirmDialog(
      context,
      title: 'حذف الفئة',
      message: c.hasChildren
          ? 'سيتم حذف «${c.name}» وترقية ${c.children.length} فئة فرعية '
              'إلى فئات رئيسية (لا تُحذف).'
          : 'سيتم حذف الفئة «${c.name}» وفك ربط أصنافها بها — '
              'الأصناف نفسها لن تُحذف.',
      confirmText: 'حذف الفئة',
      danger: true,
    );
    if (ok != true || c.id == null) return;
    await ref.read(repoProvider).deleteItemCategory(c.id!);
    bump(ref);
    if (context.mounted) {
      Navigator.pop(context); // أغلق اللوح بعد الحذف لتحديث الشجرة.
      showSnack(context, 'حُذفت الفئة وبقيت الأصناف محفوظة');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (roots.isEmpty) {
      return const EmptyState(
        icon: Icons.folder_off_outlined,
        title: 'لا توجد فئات بعد',
        message: 'أضف فئة رئيسية أولاً ثم نظّم تحتها الفئات الفرعية.',
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 18),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
          child: Row(
            children: [
              const Icon(Icons.account_tree_outlined),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'إدارة الفئات',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                ),
              ),
              TextButton.icon(
                onPressed: () => openItemCategoryForm(context, ref),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('فئة رئيسية'),
              ),
            ],
          ),
        ),
        for (final root in roots) ...[
          _CategoryManagerTile(
            category: root,
            level: 0,
            onEdit: () => openItemCategoryForm(context, ref, category: root),
            onAddSub: () =>
                openItemCategoryForm(context, ref, parentId: root.id),
            onDelete: () => _delete(context, ref, root),
          ),
          for (final sub in root.children)
            _CategoryManagerTile(
              category: sub,
              level: 1,
              onEdit: () => openItemCategoryForm(context, ref, category: sub),
              onAddSub: () => openItemCategoryForm(context, ref, parentId: sub.id),
              onDelete: () => _delete(context, ref, sub),
            ),
        ],
      ],
    );
  }
}

class _CategoryManagerTile extends StatelessWidget {
  final ItemCategory category;
  final int level;
  final VoidCallback onEdit;
  final VoidCallback onAddSub;
  final VoidCallback onDelete;

  const _CategoryManagerTile({
    required this.category,
    required this.level,
    required this.onEdit,
    required this.onAddSub,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final indent = level * 22.0;
    return Padding(
      padding: EdgeInsetsDirectional.only(start: indent, bottom: 6),
      child: Card(
        margin: EdgeInsets.zero,
        child: ListTile(
          contentPadding: const EdgeInsetsDirectional.only(
              start: 10, end: 4, top: 2, bottom: 2),
          leading: Icon(
            level == 0 ? Icons.folder_outlined : Icons.subdirectory_arrow_left,
            color: AppColors.primaryOf(context),
          ),
          title: Text(
            category.name,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          subtitle: category.hasChildren
              ? Text('${category.children.length} فئة فرعية')
              : null,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: 'إضافة فئة فرعية',
                icon: const Icon(Icons.add_circle_outline, size: 20),
                onPressed: onAddSub,
              ),
              IconButton(
                tooltip: 'تعديل الاسم',
                icon: const Icon(Icons.edit_outlined, size: 20),
                onPressed: onEdit,
              ),
              IconButton(
                tooltip: 'حذف الفئة',
                icon: Icon(Icons.delete_outline,
                    size: 20, color: AppColors.dangerOf(context)),
                onPressed: onDelete,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// شريط الفئات الأفقي (رئيسية + فرعية للفئة المختارة).
class _CategoryChipBar extends StatelessWidget {
  final List<ItemCategory> roots;
  final int? rootId;
  final int? subId;
  final ValueChanged<int?> onRoot;
  final ValueChanged<int?> onSub;
  final VoidCallback onAddCategory;
  final VoidCallback onManage;

  const _CategoryChipBar({
    required this.roots,
    required this.rootId,
    required this.subId,
    required this.onRoot,
    required this.onSub,
    required this.onAddCategory,
    required this.onManage,
  });

  @override
  Widget build(BuildContext context) {
    final selectedRoot = roots.cast<ItemCategory?>().firstWhere(
          (r) => r?.id == rootId,
          orElse: () => null,
        );
    final subs = selectedRoot?.children ?? const <ItemCategory>[];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 46,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: [
              _Chip(
                label: 'الكل',
                icon: Icons.apps_rounded,
                selected: rootId == null,
                onTap: () => onRoot(null),
              ),
              for (final r in roots)
                GestureDetector(
                  // ضغطة مطوّلة = إدارة الفئة (تعديل/حذف/إضافة فرعية).
                  onLongPress: onManage,
                  child: _Chip(
                    label: r.name,
                    icon: r.hasChildren
                        ? Icons.account_tree_outlined
                        : Icons.folder_outlined,
                    selected: rootId == r.id,
                    badge: r.children.length,
                    onTap: () => onRoot(r.id),
                  ),
                ),
              // زر مدمج لإضافة فئة جديدة.
              Padding(
                padding: const EdgeInsetsDirectional.only(start: 6),
                child: ActionChip(
                  avatar: const Icon(Icons.add, size: 17),
                  label: const Text('فئة جديدة'),
                  onPressed: onAddCategory,
                ),
              ),
              // زر مدمج لإدارة الفئات (تعديل/حذف/إضافة فرعية).
              Padding(
                padding: const EdgeInsetsDirectional.only(start: 6),
                child: ActionChip(
                  avatar: const Icon(Icons.tune_rounded, size: 17),
                  label: const Text('إدارة'),
                  onPressed: onManage,
                ),
              ),
            ],
          ),
        ),
        if (subs.isNotEmpty)
          SizedBox(
            height: 42,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                _Chip(
                  label: 'الكل',
                  small: true,
                  selected: subId == null,
                  onTap: () => onSub(null),
                ),
                for (final s in subs)
                  _Chip(
                    label: s.name,
                    small: true,
                    selected: subId == s.id,
                    onTap: () => onSub(s.id),
                  ),
              ],
            ),
          ),
        const SizedBox(height: 2),
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final IconData? icon;
  final bool selected;
  final bool small;
  final int badge;
  final VoidCallback onTap;

  const _Chip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
    this.small = false,
    this.badge = 0,
  });

  @override
  Widget build(BuildContext context) {
    final primary = AppColors.primaryOf(context);
    return Padding(
      padding: const EdgeInsetsDirectional.only(end: 6),
      child: FilterChip(
        selected: selected,
        showCheckmark: false,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
        label: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon,
                  size: 15,
                  color: selected ? primary : AppColors.text3Of(context)),
              const SizedBox(width: 5),
            ],
            Text(
              label,
              style: TextStyle(
                fontSize: small ? 12 : 13,
                fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
              ),
            ),
            if (badge > 0) ...[
              const SizedBox(width: 5),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: selected
                      ? primary.withValues(alpha: .18)
                      : AppColors.primarySoftOf(context),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text('$badge',
                    style: const TextStyle(
                        fontSize: 10.5, fontWeight: FontWeight.w800)),
              ),
            ],
          ],
        ),
        onSelected: (_) => onTap(),
      ),
    );
  }
}

/// بطاقة الصنف في نمط القائمة التفصيلي.
class _ItemTile extends ConsumerWidget {
  final Item item;
  const _ItemTile({required this.item});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final warn = item.out
        ? AppColors.danger
        : (item.low ? AppColors.amber : AppColors.green);
    final warnText = item.out ? 'نفد' : (item.low ? 'قارب النفاد' : 'متوفر');

    return Card(
      margin: const EdgeInsets.only(bottom: 9),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => openItemForm(context, ref, item: item),
        child: Padding(
          padding: const EdgeInsets.all(11),
          child: Row(
            children: [
              _Thumb(image: item.image),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Wrap(
                      spacing: 6,
                      runSpacing: 3,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        if (item.sku.isNotEmpty)
                          _Meta(
                            icon: Icons.qr_code_2_rounded,
                            text: item.sku,
                          ),
                        if (item.category.isNotEmpty)
                          _Meta(
                            icon: Icons.folder_outlined,
                            text: item.category,
                          ),
                        _Meta(icon: Icons.straighten, text: item.unit),
                      ],
                    ),
                    const SizedBox(height: 7),
                    Row(
                      children: [
                        _Price(
                          label: 'شراء',
                          value: Fmt.money(item.buyPrice, 0),
                          color: AppColors.info,
                        ),
                        const SizedBox(width: 14),
                        _Price(
                          label: 'بيع',
                          value: Fmt.money(item.sellPrice, 0),
                          color: AppColors.teal,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Pill(warnText, color: warn),
                  const SizedBox(height: 8),
                  Text(
                    Fmt.money(item.quantity, 0),
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w900,
                      color: warn,
                    ),
                  ),
                  if (item.minQuantity > 0)
                    Text(
                      'حد ${Fmt.money(item.minQuantity, 0)}',
                      style: TextStyle(
                        fontSize: 10.5,
                        color: AppColors.text3Of(context),
                      ),
                    ),
                  const SizedBox(height: 4),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        tooltip: 'تعديل الصنف',
                        onPressed: () => openItemForm(context, ref, item: item),
                        icon: Icon(Icons.edit_outlined,
                            size: 19, color: AppColors.primaryOf(context)),
                      ),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        tooltip: 'حذف الصنف',
                        onPressed: () async {
                          final ok = await confirmDialog(
                            context,
                            title: 'حذف الصنف',
                            message: 'سيُنقل «${item.name}» إلى سلة المهملات '
                                'ويمكن استرجاعه.',
                          );
                          if (!ok || item.id == null) return;
                          await ref.read(repoProvider).deleteItem(item.id!);
                          bump(ref);
                          if (context.mounted) {
                            showSnack(context, 'نُقل الصنف إلى سلة المهملات');
                          }
                        },
                        icon: Icon(Icons.delete_outline,
                            size: 19, color: AppColors.dangerOf(context)),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// بطاقة الصنف في نمط الشبكة.
class _ItemGridCard extends ConsumerWidget {
  final Item item;
  const _ItemGridCard({required this.item});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final warn = item.out
        ? AppColors.danger
        : (item.low ? AppColors.amber : AppColors.green);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => openItemForm(context, ref, item: item),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _Thumb(image: item.image, radius: 0, size: 46),
                  PositionedDirectional(
                    top: 7,
                    end: 7,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 7, vertical: 3),
                      decoration: BoxDecoration(
                        color: warn,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        Fmt.money(item.quantity, 0),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11.5,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(9, 8, 9, 9),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    Fmt.money(item.sellPrice, 0),
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                      color: AppColors.teal,
                    ),
                  ),
                  if (item.sku.isNotEmpty)
                    Text(
                      item.sku,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 10.5,
                        color: AppColors.text3Of(context),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// صورة الصنف المصغّرة (ملف محلي) مع بديل أيقوني آمن.
class _Thumb extends StatelessWidget {
  final String image;
  final double radius;
  final double size;

  const _Thumb({required this.image, this.radius = 13, this.size = 26});

  @override
  Widget build(BuildContext context) {
    final path = image.isEmpty ? '' : MediaPaths.toAbsolute(image);
    final file = path.isEmpty ? null : File(path);
    final hasImage = file != null && MediaPaths.exists(image);
    return Container(
      width: radius == 0 ? null : 52,
      height: radius == 0 ? null : 52,
      decoration: BoxDecoration(
        color: AppColors.primarySoftOf(context),
        borderRadius: BorderRadius.circular(radius),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: hasImage
            ? Image.file(
                file,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => _fallback(context),
              )
            : _fallback(context),
      ),
    );
  }

  Widget _fallback(BuildContext context) => Center(
        child: Icon(
          Icons.inventory_2_outlined,
          size: size,
          color: AppColors.primaryOf(context),
        ),
      );
}

class _Meta extends StatelessWidget {
  final IconData icon;
  final String text;
  const _Meta({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: AppColors.text3Of(context)),
          const SizedBox(width: 3),
          Text(
            text,
            style: TextStyle(fontSize: 11.5, color: AppColors.text2Of(context)),
          ),
        ],
      );
}

class _Price extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  const _Price({required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style:
                  TextStyle(fontSize: 10.5, color: AppColors.text3Of(context))),
          Text(
            value,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w800,
              color: color,
            ),
          ),
        ],
      );
}

/// يفتح نموذج إضافة/تعديل فئة (مع تحديد الفئة الأب لشجرة الفئات).
/// [parentId] يُعيَّن ابتداءً عند الإضافة من داخل فئة معيّنة.
Future<int?> openItemCategoryForm(
  BuildContext context,
  WidgetRef ref, {
  ItemCategory? category,
  int? parentId,
}) =>
    showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
        child: _ItemCategoryForm(category: category, presetParentId: parentId),
      ),
    ).then((id) {
      if (id != null) bump(ref);
      return id;
    });

class _ItemCategoryForm extends ConsumerStatefulWidget {
  final ItemCategory? category;

  /// (2026-09-22) فئة أب مبدئية عند الإضافة من داخل فئة.
  final int? presetParentId;

  const _ItemCategoryForm({this.category, this.presetParentId});

  @override
  ConsumerState<_ItemCategoryForm> createState() => _ItemCategoryFormState();
}

class _ItemCategoryFormState extends ConsumerState<_ItemCategoryForm> {
  late final TextEditingController _name;
  int? _parentId;
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.category?.name ?? '');
    _parentId = widget.category?.parentId ?? widget.presetParentId;
  }

  /// الفئات الممنوع اختيارها كأب: الفئة نفسها وكل سلالتها (منع الدوران).
  Set<int> _forbidden(List<ItemCategory> all) {
    final self = widget.category?.id;
    if (self == null) return const <int>{};
    final childrenOf = <int, List<int>>{};
    for (final c in all) {
      final p = c.parentId;
      if (p != null && c.id != null) {
        childrenOf.putIfAbsent(p, () => <int>[]).add(c.id!);
      }
    }
    final banned = <int>{self};
    final queue = <int>[self];
    while (queue.isNotEmpty) {
      final cur = queue.removeLast();
      for (final child in childrenOf[cur] ?? const <int>[]) {
        if (banned.add(child)) queue.add(child);
      }
    }
    return banned;
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'اسم الفئة مطلوب');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final now = DateTime.now();
      final category = (widget.category ??
              ItemCategory(name: name, createdAt: now, updatedAt: now))
          .copyWith(name: name, parentId: _parentId);
      final id = await ref.read(repoProvider).saveItemCategory(category);
      if (mounted) Navigator.pop(context, id);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = '$e'.replaceFirst('Bad state: ', '');
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(Icons.folder_outlined,
                      color: AppColors.primaryOf(context)),
                  const SizedBox(width: 8),
                  Text(
                    widget.category == null ? 'إضافة فئة جديدة' : 'تعديل الفئة',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: _saving ? null : () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _name,
                autofocus: true,
                textInputAction: TextInputAction.done,
                decoration: InputDecoration(
                  labelText: 'اسم الفئة *',
                  hintText: 'مثل: المواد الغذائية أو الأجهزة',
                  prefixIcon: const Icon(Icons.category_outlined),
                  errorText: _error,
                ),
                onSubmitted: (_) => _saving ? null : _save(),
              ),
              const SizedBox(height: 12),
              // (2026-09-22) اختيار الفئة الأب: فارغ = فئة رئيسية.
              Consumer(
                builder: (ctx, rref, _) {
                  final all = rref.watch(itemCategoriesProvider).valueOrNull ??
                      const [];
                  final banned = _forbidden(all);
                  final options = all
                      .where((c) => c.id != null && !banned.contains(c.id))
                      .toList();
                  final valid = _parentId != null && banned.contains(_parentId)
                      ? null
                      : _parentId;
                  return DropdownButtonFormField<int?>(
                    initialValue: valid,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'الفئة الأب',
                      hintText: 'فئة رئيسية (بدون أب)',
                      prefixIcon: Icon(Icons.account_tree_outlined),
                      isDense: true,
                    ),
                    items: [
                      const DropdownMenuItem<int?>(
                        value: null,
                        child: Text('فئة رئيسية (بدون أب)'),
                      ),
                      for (final c in options)
                        DropdownMenuItem<int?>(
                          value: c.id,
                          child: Text(
                            c.parentId == null ? c.name : '↳ ${c.name}',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged:
                        _saving ? null : (v) => setState(() => _parentId = v),
                  );
                },
              ),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _saving ? null : _save,
                  icon: _saving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.save_outlined),
                  label: Text(
                    widget.category == null ? 'حفظ الفئة' : 'حفظ التعديل',
                  ),
                ),
              ),
            ],
          ),
        ),
      );
}

// ==================== نموذج الصنف ====================

Future<void> openItemForm(
  BuildContext context,
  WidgetRef ref, {
  Item? item,
  int? categoryId,
}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => Padding(
        padding:
            EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: _ItemForm(item: item, presetCategoryId: categoryId),
      ),
    ).then((_) => bump(ref));

class _ItemForm extends ConsumerStatefulWidget {
  final Item? item;
  final int? presetCategoryId;
  const _ItemForm({this.item, this.presetCategoryId});

  @override
  ConsumerState<_ItemForm> createState() => _ItemFormState();
}

class _ItemFormState extends ConsumerState<_ItemForm> {
  late final TextEditingController _name;
  late final TextEditingController _sku;
  late final TextEditingController _unit;
  late final TextEditingController _buy;
  late final TextEditingController _sell;
  late final TextEditingController _qty;
  late final TextEditingController _min;
  late final TextEditingController _notes;
  int? _categoryId;
  String? _error;
  String? _categoryError;

  @override
  void initState() {
    super.initState();
    final i = widget.item;
    _categoryId = widget.presetCategoryId ?? i?.categoryId;
    _name = TextEditingController(text: i?.name ?? '');
    _sku = TextEditingController(text: i?.sku ?? '');
    _unit = TextEditingController(text: i?.unit ?? 'حبة');
    _buy = TextEditingController(text: i == null ? '' : _n(i.buyPrice));
    _sell = TextEditingController(text: i == null ? '' : _n(i.sellPrice));
    _qty = TextEditingController(text: i == null ? '' : _n(i.quantity));
    _min = TextEditingController(text: i == null ? '' : _n(i.minQuantity));
    _notes = TextEditingController(text: i?.notes ?? '');
    for (final c in [_buy, _sell]) {
      c.addListener(() => setState(() {}));
    }
  }

  static String _n(double v) =>
      v == 0 ? '' : (v == v.roundToDouble() ? v.toInt().toString() : '$v');

  @override
  void dispose() {
    for (final c in [_name, _sku, _unit, _buy, _sell, _qty, _min, _notes]) {
      c.dispose();
    }
    super.dispose();
  }

  double get _buyV => Fmt.parseAmount(_buy.text) ?? 0;
  double get _sellV => Fmt.parseAmount(_sell.text) ?? 0;

  Future<void> _addCategory() async {
    final id = await openItemCategoryForm(context, ref);
    if (mounted && id != null) setState(() => _categoryId = id);
  }

  Widget _categoryPicker(
    BuildContext context,
    AsyncValue<List<ItemCategory>> state,
  ) {
    return state.when(
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: LinearProgressIndicator(),
      ),
      error: (e, _) => InputDecorator(
        decoration: const InputDecoration(
          labelText: 'الفئة *',
          errorText: 'تعذّر تحميل الفئات',
          prefixIcon: Icon(Icons.category_outlined),
        ),
        child: Text('$e', maxLines: 2, overflow: TextOverflow.ellipsis),
      ),
      data: (categories) {
        final validId =
            categories.any((c) => c.id == _categoryId) ? _categoryId : null;
        if (categories.isEmpty) {
          return Column(
            children: [
              InputDecorator(
                decoration: InputDecoration(
                  labelText: 'الفئة *',
                  errorText: _categoryError,
                  prefixIcon: const Icon(Icons.category_outlined),
                ),
                child: const Text('أضف فئة أولًا قبل تسجيل الصنف'),
              ),
              const SizedBox(height: 7),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: OutlinedButton.icon(
                  onPressed: _addCategory,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('إضافة فئة جديدة'),
                ),
              ),
            ],
          );
        }
        return Column(
          children: [
            DropdownButtonFormField<int>(
              initialValue: validId,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: 'الفئة *',
                errorText: _categoryError,
                prefixIcon: const Icon(Icons.category_outlined),
              ),
              items: categories
                  .map(
                    (category) => DropdownMenuItem<int>(
                      value: category.id,
                      child: Text(
                        category.name,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  )
                  .toList(),
              onChanged: (value) {
                setState(() {
                  _categoryId = value;
                  _categoryError = null;
                });
              },
            ),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                onPressed: _addCategory,
                icon: const Icon(Icons.add, size: 17),
                label: const Text('إضافة فئة جديدة'),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'اسم الصنف مطلوب');
      return;
    }
    if (_categoryId == null) {
      setState(() => _categoryError = 'اختر فئة أو أضف فئة جديدة أولًا');
      return;
    }

    final repo = ref.read(repoProvider);
    final categories = await repo.itemCategories();
    final category =
        categories.where((value) => value.id == _categoryId).firstOrNull;
    if (category == null) {
      setState(() => _categoryError = 'الفئة المختارة غير موجودة');
      return;
    }

    final now = DateTime.now();
    final base = widget.item;
    final it =
        (base ?? Item(name: name, createdAt: now, updatedAt: now)).copyWith(
      name: name,
      categoryId: category.id,
      sku: _sku.text.trim(),
      unit: _unit.text.trim().isEmpty ? 'حبة' : _unit.text.trim(),
      buyPrice: _buyV,
      sellPrice: _sellV,
      quantity: Fmt.parseAmount(_qty.text) ?? 0,
      minQuantity: Fmt.parseAmount(_min.text) ?? 0,
      category: category.name,
      notes: _notes.text.trim(),
    );
    try {
      await repo.saveItem(it);
      bump(ref);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        showSnack(
          context,
          e is StateError ? e.message : 'تعذّر حفظ الصنف: $e',
          error: true,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final categories = ref.watch(itemCategoriesProvider);
    final profit = _sellV - _buyV;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.inventory_2_outlined,
                    color: AppColors.primaryOf(context),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    widget.item == null ? 'صنف جديد' : 'تعديل الصنف',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              TextField(
                controller: _name,
                autofocus: widget.item == null,
                decoration: InputDecoration(
                  labelText: 'اسم الصنف *',
                  prefixIcon: const Icon(Icons.label_outline),
                  errorText: _error,
                ),
                onChanged: (_) {
                  if (_error != null) setState(() => _error = null);
                },
              ),
              const SizedBox(height: 10),
              _categoryPicker(context, categories),
              const SizedBox(height: 4),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _sku,
                      decoration: InputDecoration(
                        labelText: 'الرمز / الباركود',
                        prefixIcon: const Icon(Icons.qr_code),
                        suffixIcon: IconButton(
                          tooltip: 'مسح الباركود بالكاميرا',
                          icon: const Icon(Icons.barcode_reader),
                          onPressed: () async {
                            final code = await scanBarcode(context);
                            if (code != null && code.isNotEmpty) {
                              setState(() => _sku.text = code);
                            }
                          },
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: _unit,
                      decoration: const InputDecoration(
                        labelText: 'الوحدة',
                        prefixIcon: Icon(Icons.straighten),
                      ),
                    ),
                  ),
                ],
              ),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton.icon(
                  onPressed: () {
                    // توليد رمز باركود فريد (EAN-13 مبسّط) إن لم يكن هناك رمز.
                    if (_sku.text.trim().isEmpty) {
                      final now = DateTime.now();
                      final base =
                          '62${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}${now.millisecondsSinceEpoch.toString().substring(7)}';
                      setState(() => _sku.text = base.substring(0, 12));
                    }
                  },
                  icon: const Icon(Icons.qr_code_2, size: 18),
                  label: const Text('توليد رمز باركود تلقائي'),
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: _AmountField(
                      controller: _buy,
                      label: 'سعر الشراء',
                      icon: Icons.shopping_cart_outlined,
                      words: true,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _AmountField(
                      controller: _sell,
                      label: 'سعر البيع',
                      icon: Icons.sell_outlined,
                      words: true,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: profit >= 0
                      ? AppColors.greenSoftOf(context)
                      : AppColors.dangerSoftOf(context),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      profit >= 0 ? Icons.trending_up : Icons.trending_down,
                      size: 18,
                      color: profit >= 0
                          ? AppColors.greenOf(context)
                          : AppColors.dangerOf(context),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'ربح الوحدة: ${Fmt.money(profit, 0)}'
                      '${_buyV > 0 ? '  (${(profit / _buyV * 100).toStringAsFixed(0)}٪)' : ''}',
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        color: profit >= 0
                            ? AppColors.greenOf(context)
                            : AppColors.dangerOf(context),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: _AmountField(
                      controller: _qty,
                      label: 'الكمية الحالية',
                      icon: Icons.inventory_outlined,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _AmountField(
                      controller: _min,
                      label: 'حد التنبيه',
                      icon: Icons.warning_amber_outlined,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _notes,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: 'ملاحظات',
                  prefixIcon: Icon(Icons.notes_outlined),
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _save,
                  icon: const Icon(Icons.save_outlined),
                  label: const Text('حفظ الصنف'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// حقل مبلغ مع آلة حاسبة سريعة. عند تفعيل [words] يظهر المبلغ بالحروف تحته.
class _AmountField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final IconData icon;
  final bool words;
  const _AmountField({
    required this.controller,
    required this.label,
    required this.icon,
    this.words = false,
  });

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: controller,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: label,
              prefixIcon: Icon(icon),
              suffixIcon: IconButton(
                tooltip: 'آلة حاسبة',
                icon: const Icon(Icons.calculate_outlined),
                onPressed: () async {
                  final v =
                      await openCalculator(context, initial: controller.text);
                  if (v != null) {
                    controller.text =
                        v == v.roundToDouble() ? '${v.toInt()}' : '$v';
                  }
                },
              ),
            ),
          ),
          if (words) AmountWords(controller: controller),
        ],
      );
}
