import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../core/accounting.dart';
import '../core/format.dart';
import '../core/models.dart';
import '../core/sfx.dart';
import '../core/theme.dart';
import '../data/pos_cart.dart';
import '../data/providers.dart';
import 'barcode_scanner.dart';
import 'tx_share.dart';
import 'widgets.dart';

enum _PosPayment {
  cash('نقداً 💵', 'cash'),
  credit('آجل 📑', 'credit'),
  partial('جزئي ⚖️', 'partial');

  final String label;
  final String code;
  const _PosPayment(this.label, this.code);

  static _PosPayment fromCode(String c) => _PosPayment.values
      .firstWhere((p) => p.code == c, orElse: () => _PosPayment.cash);
}

/// شاشة نقطة البيع ونظام المبيعات المتكامل
class PosScreen extends ConsumerStatefulWidget {
  const PosScreen({super.key});

  /// جسر الزر المركزي (Omni): عندما تكون شاشة POS ظاهرة يفتح زر
  /// الإجراء الموحد درج الدفع مباشرة عبر هذا المرجع.
  static void Function()? openCheckoutBridge;

  @override
  ConsumerState<PosScreen> createState() => _PosScreenState();
}

class _PosScreenState extends ConsumerState<PosScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  int? _selectedCategoryId;
  String _searchQuery = '';
  final TextEditingController _searchCtrl = TextEditingController();
  bool _saving = false;

  /// «السماح بالبيع عند نفاد الرصيد الدفتري» — إعداد المخزون.
  bool get _allowNegative =>
      (ref.read(settingsProvider).valueOrNull ?? const {})['allowNegativeStock'] ==
      '1';

  // السلة الحية تعيش في Riverpod (pos_cart.dart) — التنقل لا يفقدها.
  PosDraft get _draft => ref.read(posDraftProvider);
  PosDraftNotifier get _cartCtl => ref.read(posDraftProvider.notifier);

  // جسور قراءة من المسودة — تبقي بقية الشيفرة كما هي.
  Map<int, CartEntry> get _cart => _draft.cart;
  int? get _selectedCustomerId => _draft.customerId;
  _PosPayment get _payment => _PosPayment.fromCode(_draft.payment);
  double get _subtotal => _draft.subtotal;
  double get _discount => _draft.discountValue;
  double get _netTotal => _draft.netTotal;
  int get _itemCount => _draft.itemCount;
  // حقول نصية تُستعاد من المسودة عند إعادة بناء الشاشة (تُهيأ في
  // initState — التهيئة الكسولة تنفجر لو أول وصول كان في dispose).
  late final TextEditingController _paidCtrl;
  late final TextEditingController _discountCtrl;
  late final TextEditingController _notesCtrl;

  @override
  void initState() {
    super.initState();
    final d = ref.read(posDraftProvider);
    _paidCtrl = TextEditingController(text: d.paidText);
    _discountCtrl = TextEditingController(text: d.discountText);
    _notesCtrl = TextEditingController(text: d.notesText);
    _tabController = TabController(length: 2, vsync: this);
    // ربط الزر المركزي الموحد: على شاشة POS يفتح درج الدفع مباشرة.
    PosScreen.openCheckoutBridge = () {
      if (!mounted) return;
      if (_draft.cart.isEmpty) {
        Sfx.reject();
        showSnack(context, 'السلة فارغة — أضف أصنافاً أولاً', error: true);
        return;
      }
      _openCheckoutSheet();
    };
  }

  @override
  void dispose() {
    if (PosScreen.openCheckoutBridge != null) {
      PosScreen.openCheckoutBridge = null;
    }
    _tabController.dispose();
    _searchCtrl.dispose();
    _paidCtrl.dispose();
    _discountCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  void _addItem(Item item) {
    final allowNeg = _allowNegative;
    if (!allowNeg && item.quantity <= 0) {
      Sfx.reject();
      showSnack(context, 'الصنف «${item.name}» نفد من المخزون', error: true);
      return;
    }
    final ok = _cartCtl.addItem(item, allowNegative: allowNeg);
    if (!ok) {
      Sfx.reject();
      showSnack(
        context,
        'الكمية المتاحة من «${item.name}»: ${item.quantity.toStringAsFixed(0)} ${item.unit} فقط',
        error: true,
      );
      return;
    }
    if (allowNeg && item.quantity - (_draft.cart[item.id]?.quantity ?? 0) < 0) {
      showSnack(context,
          '⚠️ «${item.name}»: البيع تجاوز الرصيد الدفتري (رصيد سالب)',
          error: true, silent: true);
    }
    Sfx.click();
  }

  /// إدخال كمية مباشر: نقرة على رقم الكمية تفتح لوحة إدخال سريعة بدل
  /// تكرار «+» للأعداد الكبيرة.
  Future<void> _editQuantity(CartEntry entry) async {
    final qty = await showQuickAmountPad(
      context,
      title: 'كمية «${entry.item.name}»',
      initial: entry.quantity,
      hint: 'المتاح: ${Fmt.money(entry.item.quantity)} ${entry.item.unit}',
    );
    if (qty == null) return;
    final ok = _cartCtl.setQuantity(entry.item.id!, qty,
        allowNegative: _allowNegative);
    if (!ok) {
      Sfx.reject();
      if (mounted) {
        showSnack(
          context,
          'الكمية المتاحة: ${entry.item.quantity.toStringAsFixed(0)} ${entry.item.unit} فقط',
          error: true,
        );
      }
    }
  }

  void _clearCart() {
    _cartCtl.clear();
    _paidCtrl.clear();
    _discountCtrl.clear();
    _notesCtrl.clear();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    // مراقبة المسودة: أي تغيير في السلة (حتى من جلسة سابقة قبل تنقل
    // عرضي بين التبويبات) يعيد بناء الشريط السفلي فوراً.
    ref.watch(posDraftProvider);
    return Scaffold(
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(48),
        child: Container(
          color: Theme.of(context).colorScheme.surface,
          child: TabBar(
            controller: _tabController,
            tabs: const [
              Tab(icon: Icon(Icons.point_of_sale_outlined), text: 'نقطة البيع'),
              Tab(icon: Icon(Icons.history_edu_outlined), text: 'سجل المبيعات'),
            ],
          ),
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [_buildPosSaleTab(), const _PosHistoryTab()],
      ),
      bottomNavigationBar: _tabController.index == 0 && _cart.isNotEmpty
          ? _buildCartBottomBar()
          : null,
    );
  }

  Widget _buildPosSaleTab() {
    final categories = ref.watch(itemCategoriesProvider).valueOrNull ?? [];
    final allItems = ref.watch(itemsProvider).valueOrNull ?? [];
    final currencies =
        ref.watch(currenciesProvider).valueOrNull ?? kDefaultCurrencies;
    final cur = currencies.first;

    final filteredItems = allItems.where((item) {
      if (_selectedCategoryId != null &&
          item.categoryId != _selectedCategoryId) {
        return false;
      }
      if (_searchQuery.isNotEmpty) {
        // بحث ذكي: استعلام رقمي → باركود/SKU أولاً؛ نصي → تطبيع عربي
        // (تجاهل التشكيل وتوحيد أ/إ/آ→ا، ة→ه، ى→ي).
        if (Fmt.isNumericQuery(_searchQuery)) {
          final q = Fmt.normArabic(_searchQuery);
          return item.sku.contains(q) || Fmt.smartContains(item.name, q);
        }
        return Fmt.smartContains(item.name, _searchQuery) ||
            Fmt.smartContains(item.sku, _searchQuery);
      }
      return true;
    }).toList();

    return Column(
      children: [
        // شريط البحث
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
          child: TextField(
            controller: _searchCtrl,
            decoration: InputDecoration(
              hintText: 'ابحث باسم الصنف أو الباركود...',
              prefixIcon: const Icon(Icons.search),
              isDense: true,
              suffixIcon: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: 'مسح الباركود',
                    icon: const Icon(Icons.barcode_reader),
                    onPressed: () async {
                      final code = await scanBarcode(context);
                      if (code != null && code.isNotEmpty) {
                        _searchCtrl.text = code;
                        setState(() => _searchQuery = code.trim());
                      }
                    },
                  ),
                  if (_searchQuery.isNotEmpty)
                    IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        _searchCtrl.clear();
                        setState(() => _searchQuery = '');
                      },
                    ),
                ],
              ),
            ),
            onChanged: (v) => setState(() => _searchQuery = v.trim()),
          ),
        ),

        // فئات الأصناف
        SizedBox(
          height: 44,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: FilterChip(
                  label: const Text('الكل'),
                  selected: _selectedCategoryId == null,
                  onSelected: (_) => setState(() => _selectedCategoryId = null),
                ),
              ),
              for (final cat in categories)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: FilterChip(
                    label: Text(cat.name),
                    selected: _selectedCategoryId == cat.id,
                    onSelected: (_) =>
                        setState(() => _selectedCategoryId = cat.id),
                  ),
                ),
            ],
          ),
        ),

        const SizedBox(height: 6),

        // شبكة الأصناف
        Expanded(
          child: filteredItems.isEmpty
              ? const EmptyState(
                  icon: Icons.inventory_2_outlined,
                  title: 'لا توجد أصناف مطابقة',
                  message: 'أضف أصنافاً من شاشة المخزون أو غيّر نص البحث.',
                )
              : GridView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 6, 12, 90),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    childAspectRatio: 1.15,
                    crossAxisSpacing: 10,
                    mainAxisSpacing: 10,
                  ),
                  itemCount: filteredItems.length,
                  itemBuilder: (context, i) {
                    final item = filteredItems[i];
                    final inCart = _cart[item.id]?.quantity ?? 0.0;
                    final price =
                        item.sellPrice > 0 ? item.sellPrice : item.buyPrice;
                    final isLow = item.minQuantity > 0 &&
                        item.quantity <= item.minQuantity;
                    final isOut = item.quantity <= 0;

                    return Card(
                      elevation: inCart > 0 ? 2 : 0.5,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                        side: BorderSide(
                          color: inCart > 0
                              ? AppColors.primaryOf(context)
                              : Theme.of(context)
                                  .dividerColor
                                  .withValues(alpha: 0.1),
                          width: inCart > 0 ? 2 : 1,
                        ),
                      ),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        // السماح بالبيع رغم النفاد إن فُعِّل الإعداد
                        // (حركة سالبة مع تنبيه بصري بدل الحظر).
                        onTap: isOut && !_allowNegative
                            ? null
                            : () => _addItem(item),
                        child: Padding(
                          padding: const EdgeInsets.all(10),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(
                                    child: Text(
                                      item.name,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w700,
                                        fontSize: 14,
                                      ),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  if (isOut)
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 7, vertical: 3),
                                      decoration: BoxDecoration(
                                        color: AppColors.dangerOf(context),
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: const Text(
                                        'نفد',
                                        style: TextStyle(
                                          color: Colors.white,
                                          fontSize: 10,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    )
                                  else if (inCart > 0)
                                    CircleAvatar(
                                      radius: 12,
                                      backgroundColor: AppColors.primaryOf(
                                        context,
                                      ),
                                      child: Text(
                                        '${inCart.toInt()}',
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 11,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(
                                    '${Fmt.money(price)} ${cur.symbol}',
                                    style: TextStyle(
                                      fontWeight: FontWeight.w800,
                                      fontSize: 13,
                                      color: AppColors.primaryOf(context),
                                    ),
                                  ),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 6,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color: (isOut
                                              ? AppColors.red
                                              : (isLow
                                                  ? Colors.orange
                                                  : AppColors.green))
                                          .withValues(alpha: 0.12),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Text(
                                      '${Fmt.money(item.quantity)} ${item.unit}',
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600,
                                        color: isOut
                                            ? AppColors.red
                                            : (isLow
                                                ? Colors.orange
                                                : AppColors.green),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildCartBottomBar() {
    final currencies =
        ref.watch(currenciesProvider).valueOrNull ?? kDefaultCurrencies;
    final cur = currencies.first;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 10,
            offset: const Offset(0, -3),
          ),
        ],
      ),
      child: SafeArea(
        child: Row(
          children: [
            Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$_itemCount صنف بالسلة',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.text2Of(context),
                  ),
                ),
                Text(
                  '${Fmt.money(_netTotal)} ${cur.symbol}',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                    color: AppColors.primaryOf(context),
                  ),
                ),
              ],
            ),
            const Spacer(),
            IconButton.outlined(
              tooltip: 'إفراغ السلة',
              icon: const Icon(
                Icons.delete_sweep_outlined,
                color: AppColors.red,
              ),
              onPressed: _clearCart,
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed: _openCheckoutSheet,
              icon: const Icon(Icons.shopping_cart_checkout),
              label: const Text('إتمام الفاتورة'),
            ),
          ],
        ),
      ),
    );
  }

  /// درج الدفع المنزلق (Slide-to-Pay): قائمة الأصناف تبقى ملء الشاشة،
  /// وكل الإدخال المالي في درج سفلي موسع — لا تغطية من لوحة المفاتيح.
  void _openCheckoutSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(ctx).viewInsets.bottom,
          ),
          child: StatefulBuilder(
            builder: (context, setSheetState) {
              final accounts = ref.watch(allAccountsProvider).valueOrNull ?? [];
              final currencies = ref.watch(currenciesProvider).valueOrNull ??
                  kDefaultCurrencies;
              final cur = currencies.first;
              final customers = accounts
                  .where(
                    (a) =>
                        a.kind == AccountKind.customer ||
                        a.kind == AccountKind.general,
                  )
                  .toList();
              final needsAccount = _payment != _PosPayment.cash;
              final accountMissing = needsAccount && _selectedCustomerId == null;

              return SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'إتمام الفاتورة 🛒',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () => Navigator.pop(context),
                        ),
                      ],
                    ),
                    const Divider(),

                    // قائمة أصناف السلة — الكمية قابلة للنقر لإدخال مباشر.
                    for (final entry in _cart.values) ...[
                      Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  entry.item.name,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                Text(
                                  '${Fmt.money(entry.unitPrice)} ${cur.symbol} / ${entry.item.unit}',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: AppColors.text2Of(context),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: const Icon(
                                  Icons.remove_circle_outline,
                                  size: 20,
                                ),
                                onPressed: () {
                                  final q = entry.quantity - 1;
                                  _cartCtl.setQuantity(entry.item.id!, q,
                                      allowNegative: _allowNegative);
                                  setSheetState(() {});
                                  setState(() {});
                                },
                              ),
                              // نقرة على الكمية = لوحة إدخال رقمي سريعة.
                              InkWell(
                                onTap: () async {
                                  await _editQuantity(entry);
                                  setSheetState(() {});
                                  setState(() {});
                                },
                                borderRadius: BorderRadius.circular(8),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 10, vertical: 4),
                                  decoration: BoxDecoration(
                                    border: Border.all(
                                        color: AppColors.primaryOf(context)
                                            .withValues(alpha: .4)),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text(
                                    Fmt.money(entry.quantity),
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ),
                              IconButton(
                                icon: const Icon(
                                  Icons.add_circle_outline,
                                  size: 20,
                                ),
                                onPressed: () {
                                  final ok = _cartCtl.setQuantity(
                                      entry.item.id!, entry.quantity + 1,
                                      allowNegative: _allowNegative);
                                  if (!ok) {
                                    Sfx.reject();
                                    showSnack(
                                      context,
                                      'الكمية المتاحة: ${entry.item.quantity.toStringAsFixed(0)} ${entry.item.unit} فقط',
                                      error: true,
                                    );
                                    return;
                                  }
                                  setSheetState(() {});
                                  setState(() {});
                                },
                              ),
                            ],
                          ),
                          SizedBox(
                            width: 75,
                            child: Text(
                              '${Fmt.money(entry.total)} ${cur.symbol}',
                              textAlign: TextAlign.end,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const Divider(height: 12),
                    ],

                    const SizedBox(height: 10),

                    // طريقة الدفع أولاً — تحدد هل نحتاج حساب عميل.
                    SegmentedButton<_PosPayment>(
                      segments: _PosPayment.values
                          .map(
                            (p) =>
                                ButtonSegment(value: p, label: Text(p.label)),
                          )
                          .toList(),
                      selected: {_payment},
                      onSelectionChanged: (set) {
                        _cartCtl.setPayment(set.first.code);
                        setSheetState(() {});
                        setState(() {});
                      },
                    ),

                    const SizedBox(height: 12),

                    // اختيار العميل — يتوهج بالأحمر إذا كان الدفع آجلاً
                    // بلا حساب محدد (تنبيه بصري لا نصي فقط).
                    Container(
                      decoration: accountMissing
                          ? BoxDecoration(
                              border: Border.all(
                                  color: AppColors.dangerOf(context),
                                  width: 2),
                              borderRadius: BorderRadius.circular(10),
                            )
                          : null,
                      padding:
                          accountMissing ? const EdgeInsets.all(6) : null,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (accountMissing)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 6),
                              child: Text(
                                '⚠️ البيع الآجل يتطلب اختيار حساب العميل',
                                style: TextStyle(
                                  color: AppColors.dangerOf(context),
                                  fontWeight: FontWeight.w700,
                                  fontSize: 12.5,
                                ),
                              ),
                            ),
                          // آخر 3 مدينين — اختيار بنقرة واحدة في وضع الآجل.
                          if (needsAccount)
                            FutureBuilder<List<Account>>(
                              future: _recentDebtors(customers),
                              builder: (c, snap) {
                                final recents = snap.data ?? const <Account>[];
                                if (recents.isEmpty) {
                                  return const SizedBox.shrink();
                                }
                                return Padding(
                                  padding: const EdgeInsets.only(bottom: 8),
                                  child: SizedBox(
                                    height: 38,
                                    child: ListView(
                                      scrollDirection: Axis.horizontal,
                                      children: [
                                        for (final a in recents)
                                          Padding(
                                            padding: const EdgeInsets.only(
                                                left: 6),
                                            child: ChoiceChip(
                                              label: Text(a.name,
                                                  overflow:
                                                      TextOverflow.ellipsis),
                                              selected:
                                                  _selectedCustomerId == a.id,
                                              onSelected: (_) {
                                                _cartCtl.setCustomer(a.id);
                                                setSheetState(() {});
                                                setState(() {});
                                              },
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                          DropdownButtonFormField<int?>(
                            initialValue: _selectedCustomerId,
                            decoration: const InputDecoration(
                              isDense: true,
                              labelText: 'العميل',
                              prefixIcon: Icon(Icons.person_outline),
                            ),
                            items: [
                              const DropdownMenuItem<int?>(
                                value: null,
                                child: Text('عميل نقدي (بدون حساب)'),
                              ),
                              for (final c in customers)
                                DropdownMenuItem<int?>(
                                  value: c.id,
                                  child: Text(
                                    '${c.name} (${c.phone.isNotEmpty ? c.phone : 'بدون هاتف'})',
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                            ],
                            onChanged: (val) {
                              _cartCtl.setCustomer(val);
                              setSheetState(() {});
                              setState(() {});
                            },
                          ),
                        ],
                      ),
                    ),

                    // تحذير تجاوز حد الائتمان — قبل السماح بالتأكيد.
                    if (needsAccount && _selectedCustomerId != null)
                      FutureBuilder<_CreditCheck?>(
                        future: _checkCreditLimit(),
                        builder: (c, snap) {
                          final chk = snap.data;
                          if (chk == null || !chk.exceeded) {
                            return const SizedBox.shrink();
                          }
                          return Container(
                            margin: const EdgeInsets.only(top: 10),
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: AppColors.dangerOf(context)
                                  .withValues(alpha: .1),
                              border: Border.all(
                                  color: AppColors.dangerOf(context)),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              '🚨 هذه الفاتورة تتجاوز حد الائتمان للعميل!\n'
                              'الحد: ${Fmt.money(chk.limit)} ${cur.symbol} — '
                              'الدين الحالي: ${Fmt.money(chk.currentDebt)} ${cur.symbol}\n'
                              'المتبقي من الحد: ${Fmt.money(chk.remaining)} ${cur.symbol}',
                              style: TextStyle(
                                color: AppColors.dangerOf(context),
                                fontWeight: FontWeight.w700,
                                fontSize: 12.5,
                                height: 1.6,
                              ),
                            ),
                          );
                        },
                      ),

                    if (_payment == _PosPayment.partial) ...[
                      const SizedBox(height: 12),
                      TextField(
                        controller: _paidCtrl,
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        inputFormatters: const [ThousandsFormatter()],
                        decoration: InputDecoration(
                          labelText: 'المبلغ المدفوع مقدماً',
                          prefixIcon: const Icon(Icons.payments_outlined),
                          isDense: true,
                          // أزرار الأصفار السريعة داخل الحقل.
                          suffixIcon: _ZeroButtons(controller: _paidCtrl,
                              onChanged: () {
                            _cartCtl.setPaid(_paidCtrl.text);
                            setSheetState(() {});
                            setState(() {});
                          }),
                        ),
                        onChanged: (v) {
                          _cartCtl.setPaid(v);
                          setSheetState(() {});
                          setState(() {});
                        },
                      ),
                      AmountWords(controller: _paidCtrl),
                    ],

                    const SizedBox(height: 12),

                    // الخصم المزدوج: نسبة % أو مبلغ مقطوع.
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _discountCtrl,
                            keyboardType:
                                const TextInputType.numberWithOptions(
                                    decimal: true),
                            inputFormatters: _draft.discountIsPercent
                                ? null
                                : const [ThousandsFormatter()],
                            decoration: InputDecoration(
                              labelText: _draft.discountIsPercent
                                  ? 'نسبة الخصم %'
                                  : 'مبلغ الخصم',
                              prefixIcon:
                                  const Icon(Icons.discount_outlined),
                              isDense: true,
                            ),
                            onChanged: (v) {
                              _cartCtl.setDiscount(v);
                              setSheetState(() {});
                              setState(() {});
                            },
                          ),
                        ),
                        const SizedBox(width: 8),
                        SegmentedButton<bool>(
                          style: const ButtonStyle(
                            visualDensity: VisualDensity.compact,
                          ),
                          segments: const [
                            ButtonSegment(value: false, label: Text('مبلغ')),
                            ButtonSegment(value: true, label: Text('٪')),
                          ],
                          selected: {_draft.discountIsPercent},
                          onSelectionChanged: (set) {
                            _cartCtl.setDiscountIsPercent(set.first);
                            setSheetState(() {});
                            setState(() {});
                          },
                        ),
                      ],
                    ),

                    const SizedBox(height: 16),

                    // الملخص المالي
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppColors.primarySoftOf(context),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Column(
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text('المجموع الفرعي:'),
                              Text('${Fmt.money(_subtotal)} ${cur.symbol}'),
                            ],
                          ),
                          if (_discount > 0) ...[
                            const SizedBox(height: 4),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  _draft.discountIsPercent
                                      ? 'الخصم (${_draft.discountText.trim()}٪):'
                                      : 'الخصم:',
                                  style:
                                      const TextStyle(color: AppColors.red),
                                ),
                                Text(
                                  '-${Fmt.money(_discount)} ${cur.symbol}',
                                  style: const TextStyle(color: AppColors.red),
                                ),
                              ],
                            ),
                          ],
                          const Divider(),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text(
                                'الصافي الإجمالي:',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16,
                                ),
                              ),
                              Text(
                                '${Fmt.money(_netTotal)} ${cur.symbol}',
                                style: TextStyle(
                                  fontWeight: FontWeight.w900,
                                  fontSize: 18,
                                  color: AppColors.primaryOf(context),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 20),

                    // زر تأكيد عريض مع قفل فوري ضد النقر المزدوج.
                    SizedBox(
                      width: double.infinity,
                      height: 52,
                      child: FilledButton.icon(
                        onPressed: _saving ? null : () => _executeSale(ctx),
                        icon: _saving
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(Icons.check_circle_outline),
                        label: Text(
                          _saving ? 'جارٍ الحفظ…' : 'تأكيد وإصدار الفاتورة',
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }

  /// أحدث 3 عملاء لهم مبيعات آجلة — للاختيار بنقرة واحدة.
  Future<List<Account>> _recentDebtors(List<Account> customers) async {
    try {
      final repo = ref.read(repoProvider);
      final txs = await repo.transactions();
      final seen = <int>{};
      final out = <Account>[];
      for (final t in txs) {
        if (t.type != OpType.debit || t.accountId == null) continue;
        if (!seen.add(t.accountId!)) continue;
        final a = customers.where((c) => c.id == t.accountId).firstOrNull;
        if (a != null) out.add(a);
        if (out.length >= 3) break;
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  /// فحص حد الائتمان للعميل المحدد مقابل صافي الفاتورة الحالية.
  Future<_CreditCheck?> _checkCreditLimit() async {
    final id = _selectedCustomerId;
    if (id == null) return null;
    try {
      final repo = ref.read(repoProvider);
      final acc = await repo.account(id);
      if (acc == null || acc.creditLimit == null || acc.creditLimit! <= 0) {
        return null;
      }
      final balance = await repo.balanceOf(acc);
      // الرصيد الموجب = دين على العميل. الجزئي يضيف المتبقي فقط.
      final debt = balance > 0 ? balance : 0.0;
      var added = _netTotal;
      if (_payment == _PosPayment.partial) {
        final paid =
            Fmt.parseAmount(ThousandsFormatter.strip(_paidCtrl.text)) ?? 0.0;
        added = (_netTotal - paid).clamp(0.0, double.infinity);
      }
      final limit = acc.creditLimit!;
      return _CreditCheck(
        limit: limit,
        currentDebt: debt,
        exceeded: debt + added > limit,
        remaining: (limit - debt).clamp(0.0, double.infinity),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _executeSale(BuildContext sheetCtx) async {
    if (_cart.isEmpty) return;

    if ((_payment == _PosPayment.credit || _payment == _PosPayment.partial) &&
        _selectedCustomerId == null) {
      Sfx.reject();
      showSnack(
        context,
        'البيع الآجل أو الجزئي يتطلب اختيار حساب العميل.',
        error: true,
        silent: true,
      );
      return;
    }

    setState(() => _saving = true);
    final repo = ref.read(repoProvider);

    try {
      final currencies = await repo.currencies();
      final cur = currencies.first;
      // رقم فاتورة تسلسلي رقمي بحت (بدون أحرف)
      final refNum = await repo.nextTxNumber();

      // 0. تحقق نهائي من توفر المخزون (دفاع ضد بيانات تغيّرت أثناء الجلسة).
      // إعداد «السماح بالبيع عند نفاد الرصيد» يتخطى الحظر مع تنبيه بصري.
      if (!_allowNegative) {
        for (final e in _cart.values) {
          if (e.item.id == null) continue;
          final fresh = await repo.item(e.item.id!);
          final available = fresh?.quantity ?? e.item.quantity;
          if (available < e.quantity) {
            throw StateError(
              'الكمية المطلوبة من «${e.item.name}» غير متوفرة. '
              'المتاح: ${available.toStringAsFixed(0)} ${e.item.unit}.',
            );
          }
        }
      }

      // 1. تجهيز أسطر الفاتورة
      final lines = _cart.values.map((e) {
        return InvoiceLine(
          itemId: e.item.id,
          name: e.item.name,
          unit: e.item.unit,
          quantity: e.quantity,
          unitPrice: e.unitPrice,
          total: e.total,
        );
      }).toList();

      // 2. تحديد نوع وسجل العملية المالية
      late final int txId;
      final now = DateTime.now();

      if (_payment == _PosPayment.cash) {
        // مبيعات نقدية: إيراد
        final tx = Tx(
          accountId: _selectedCustomerId,
          amount: _netTotal,
          currency: cur.code,
          type: OpType.revenue,
          date: now,
          description: 'فاتورة مبيعات نقدية رقم #$refNum',
          reference: refNum,
          notes: 'طريقة الدفع: نقداً',
          createdAt: now,
          updatedAt: now,
        );
        txId = await repo.saveTx(tx, items: lines);
      } else if (_payment == _PosPayment.credit) {
        // مبيعات آجلة: قيد مدين على العميل (عليه)
        final tx = Tx(
          accountId: _selectedCustomerId!,
          amount: _netTotal,
          currency: cur.code,
          type: OpType.debit,
          date: now,
          description: 'فاتورة مبيعات آجلة رقم #$refNum',
          reference: refNum,
          notes: 'طريقة الدفع: آجل (على الحساب)',
          createdAt: now,
          updatedAt: now,
        );
        txId = await repo.saveTx(tx, items: lines);
      } else {
        // مبيعات جزئية: قيد بالباقي + قبض بالمقدم
        final paid =
            Fmt.parseAmount(ThousandsFormatter.strip(_paidCtrl.text)) ?? 0.0;
        final remainder = (_netTotal - paid).clamp(0.0, double.infinity);

        // تسجيل المبلغ الكامل كمدين
        final debitTx = Tx(
          accountId: _selectedCustomerId!,
          amount: _netTotal,
          currency: cur.code,
          type: OpType.debit,
          date: now,
          description:
              'فاتورة مبيعات جزئية رقم #$refNum (إجمالي ${Fmt.money(_netTotal)} ${cur.symbol} — مدفوع ${Fmt.money(paid)} ${cur.symbol} — متبقي ${Fmt.money(remainder)} ${cur.symbol})',
          reference: refNum,
          notes:
              'طريقة الدفع: جزئي (مقدم + آجل)\nالمبلغ المدفوع: ${Fmt.money(paid)} ${cur.symbol}\nالمبلغ المتبقي: ${Fmt.money(remainder)} ${cur.symbol}',
          createdAt: now,
          updatedAt: now,
        );
        txId = await repo.saveTx(debitTx, items: lines);

        // تسجيل الدفعة المسددة كقبض إن وجدت
        if (paid > 0) {
          final payTx = Tx(
            accountId: _selectedCustomerId!,
            amount: paid,
            currency: cur.code,
            type: OpType.inflow,
            date: now,
            description:
                'دفعة مقدمة من فاتورة #$refNum (المتبقي: ${Fmt.money(remainder)} ${cur.symbol})',
            reference: '',
            createdAt: now,
            updatedAt: now,
          );
          await repo.saveTx(payTx);
        }
      }

      // 3. خصم الكميات تلقائياً من المخزون
      for (final line in lines) {
        if (line.itemId != null) {
          try {
            await repo.addStockMove(
              StockMove(
                itemId: line.itemId!,
                quantity: line.quantity,
                kind: StockKind.sale,
                date: now,
                createdAt: now,
                notes: 'مبيع نقطة بيع #$refNum',
              ),
            );
          } catch (e) {
            debugPrint('Failed to reduce stock for ${line.name}: $e');
          }
        }
      }

      // تحديث البيانات
      bump(ref);
      if (mounted && (await repo.settings())['warnLowStock'] != '0') {
        final low = <String>[];
        for (final line in lines) {
          if (line.itemId == null) continue;
          final it = await repo.item(line.itemId!);
          if (it != null &&
              it.minQuantity > 0 &&
              it.quantity <= it.minQuantity) {
            low.add(
              '${it.name} (${it.quantity.toStringAsFixed(0)} ${it.unit})',
            );
          }
        }
        if (low.isNotEmpty && mounted) {
          Sfx.warning();
          showSnack(
            context,
            '⚠️ أصناف وصلت حد إعادة الطلب: ${low.join('، ')}',
            error: true,
            silent: true,
          );
        }
      }

      if (mounted && (await repo.settings())['warnLowStock'] != '0') {
        final low = <String>[];
        for (final line in lines) {
          if (line.itemId == null) continue;
          final it = await repo.item(line.itemId!);
          if (it != null &&
              it.minQuantity > 0 &&
              it.quantity <= it.minQuantity) {
            low.add(
              '${it.name} (${it.quantity.toStringAsFixed(0)} ${it.unit})',
            );
          }
        }
        if (low.isNotEmpty && mounted) {
          Sfx.warning();
          showSnack(
            context,
            '⚠️ أصناف وصلت حد إعادة الطلب:\n${low.join('، ')}',
            error: true,
            silent: true,
          );
        }
      }

      if (mounted) {
        Navigator.pop(sheetCtx);
        Sfx.opCreated(); // صوت الدفع + اهتزاز طويل (1.5 ث) عند إنشاء العملية.
        _showSuccessDialog(txId, refNum, lines);
        _clearCart();
      }
    } catch (e) {
      if (mounted) {
        Sfx.error();
        showSnack(
          context,
          'تعذّر إتمام الفاتورة: $e',
          error: true,
          silent: true,
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _showSuccessDialog(int txId, String refNum, List<InvoiceLine> lines) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.check_circle, color: AppColors.green),
              SizedBox(width: 8),
              Text('تمت العملية بنجاح ✅'),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('رقم الفاتورة: $refNum'),
              Text('عدد الأصناف: ${lines.length}'),
              const SizedBox(height: 12),
              const Text(
                'يمكنك طباعة الإيصال الحراري أو مشاركة الفاتورة عبر واتساب مباشرة:',
              ),
            ],
          ),
          actions: [
            OutlinedButton.icon(
              icon: const Icon(Icons.print_outlined),
              label: const Text('طباعة إيصال حراري (80mm)'),
              onPressed: () async {
                final repo = ref.read(repoProvider);
                final txs = await repo.transactions();
                final tx = txs.firstWhere((t) => t.id == txId);
                final accs = await repo.accounts(includeArchived: true);
                final acc = accs.where((a) => a.id == tx.accountId).firstOrNull;
                await _printThermalInvoice(tx, acc, lines);
              },
            ),
            FilledButton.icon(
              icon: const Icon(Icons.send_outlined),
              label: const Text('إرسال واتساب'),
              onPressed: () async {
                final repo = ref.read(repoProvider);
                final txs = await repo.transactions();
                final tx = txs.firstWhere((t) => t.id == txId);
                final accs = await repo.accounts(includeArchived: true);
                final acc = accs.where((a) => a.id == tx.accountId).firstOrNull;
                if (acc == null || acc.phone.isEmpty) {
                  showSnack(
                    context,
                    'لا يوجد رقم هاتف مسجل للعميل',
                    error: true,
                  );
                  return;
                }
                await TxShare.sendNow(context, ref, tx: tx, account: acc);
              },
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('فاتورة جديدة'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _printThermalInvoice(
    Tx tx,
    Account? account,
    List<InvoiceLine> lines,
  ) async {
    final repo = ref.read(repoProvider);
    final st = await repo.settings();
    final orgName = (st['businessName'] ?? 'المتجر').trim();
    final orgPhone = (st['phone'] ?? '').trim();
    final footer = (st['voucherFooter'] ?? 'شكراً لزيارتكم!').trim();

    final doc = pw.Document();
    doc.addPage(
      pw.Page(
        pageFormat: const PdfPageFormat(
          80 * PdfPageFormat.mm,
          double.infinity,
          marginAll: 4 * PdfPageFormat.mm,
        ),
        build: (pw.Context context) {
          return pw.Directionality(
            textDirection: pw.TextDirection.rtl,
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.center,
              children: [
                pw.Text(
                  orgName,
                  style: pw.TextStyle(
                    fontSize: 16,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
                if (orgPhone.isNotEmpty)
                  pw.Text(
                    'هاتف: $orgPhone',
                    style: const pw.TextStyle(fontSize: 10),
                  ),
                pw.Divider(thickness: 1),
                pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Text(
                      'فاتورة مبيعات',
                      style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                    ),
                    pw.Text('#${tx.reference}'),
                  ],
                ),
                pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Text('التاريخ: ${Fmt.date(tx.date)}'),
                    pw.Text('الوقت: ${tx.date.hour}:${tx.date.minute}'),
                  ],
                ),
                if (account != null)
                  pw.Align(
                    alignment: pw.Alignment.centerRight,
                    child: pw.Text('العميل: ${account.name}'),
                  ),
                pw.Divider(thickness: 1),
                for (final item in lines) ...[
                  pw.Row(
                    mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                    children: [
                      pw.Expanded(
                        child: pw.Text(
                          item.name,
                          style: const pw.TextStyle(fontSize: 10),
                        ),
                      ),
                      pw.Text(
                        '${item.quantity} × ${Fmt.money(item.unitPrice)} = ${Fmt.money(item.total)}',
                        style: const pw.TextStyle(fontSize: 10),
                      ),
                    ],
                  ),
                ],
                pw.Divider(thickness: 1),
                pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Text(
                      'الإجمالي المطلوب:',
                      style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                    ),
                    pw.Text(
                      '${Fmt.money(tx.amount)} ${tx.currency}',
                      style: pw.TextStyle(
                        fontWeight: pw.FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
                pw.SizedBox(height: 8),
                pw.Text(
                  footer,
                  style: const pw.TextStyle(fontSize: 9),
                  textAlign: pw.TextAlign.center,
                ),
              ],
            ),
          );
        },
      ),
    );

    await Printing.layoutPdf(
      onLayout: (_) => doc.save(),
      name: 'invoice-${tx.reference}.pdf',
    );
  }
}

/// تبويب سجل فواتير المبيعات
class _PosHistoryTab extends ConsumerWidget {
  const _PosHistoryTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final txData = ref.watch(txPageProvider);

    return txData.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => EmptyState(
        icon: Icons.error_outline,
        title: 'تعذّر تحميل سجل المبيعات',
        message: '$e',
      ),
      data: (page) {
        // تصفية فواتير المبيعات فقط (وصفها فاتورة، نستثني الدفعات المقدمة)
        final posTxs = page.items
            .where(
              (t) =>
                  (t.description.contains('فاتورة') &&
                      !t.description.startsWith('دفعة مقدمة')) ||
                  t.type == OpType.revenue,
            )
            .toList();

        if (posTxs.isEmpty) {
          return const EmptyState(
            icon: Icons.receipt_long_outlined,
            title: 'لا توجد فواتير مبيعات مسجلة',
            message: 'قم بإجراء عمليات بيع من تبويب نقطة البيع وستظهر هنا.',
          );
        }

        return ListView.separated(
          padding: const EdgeInsets.all(12),
          itemCount: posTxs.length,
          separatorBuilder: (_, __) => const SizedBox(height: 8),
          itemBuilder: (context, i) {
            final tx = posTxs[i];
            final account = page.accounts[tx.accountId];

            return Card(
              child: ListTile(
                leading: CircleAvatar(
                  backgroundColor: AppColors.primarySoftOf(context),
                  child: const Icon(Icons.receipt, color: AppColors.teal),
                ),
                title: Text(
                  tx.reference.isNotEmpty
                      ? 'فاتورة #${tx.reference}'
                      : tx.description,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                subtitle: Text(
                  '${account?.name ?? 'عميل نقدي'} • ${Fmt.date(tx.date)}',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.text2Of(context),
                  ),
                ),
                trailing: Text(
                  '${Fmt.money(tx.amount)} ${tx.currency}',
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    fontSize: 14,
                    color: AppColors.primaryOf(context),
                  ),
                ),
                onTap: () async {
                  final repo = ref.read(repoProvider);
                  final items = await repo.transactionItems(tx.id!);
                  if (context.mounted) {
                    showDialog(
                      context: context,
                      builder: (_) => AlertDialog(
                        title: Text('تفاصيل ${tx.reference}'),
                        content: SizedBox(
                          width: double.maxFinite,
                          child: items.isEmpty
                              ? const Text('لا توجد أصناف مسجلة لهذه الفاتورة.')
                              : ListView.builder(
                                  shrinkWrap: true,
                                  itemCount: items.length,
                                  itemBuilder: (_, idx) {
                                    final it = items[idx];
                                    return ListTile(
                                      title: Text(it.name),
                                      trailing: Text(
                                        '${it.quantity} × ${Fmt.money(it.unitPrice)} = ${Fmt.money(it.total)}',
                                      ),
                                    );
                                  },
                                ),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context),
                            child: const Text('إغلاق'),
                          ),
                        ],
                      ),
                    );
                  }
                },
              ),
            );
          },
        );
      },
    );
  }
}

/// نتيجة فحص حد الائتمان للعميل قبل تأكيد فاتورة آجلة.
class _CreditCheck {
  final double limit;
  final double currentDebt;
  final double remaining;
  final bool exceeded;
  const _CreditCheck({
    required this.limit,
    required this.currentDebt,
    required this.remaining,
    required this.exceeded,
  });
}

/// زرا «+00» و«+000» المدمجان في حقول المبالغ لتسريع الإدخال.
class _ZeroButtons extends StatelessWidget {
  final TextEditingController controller;
  final VoidCallback onChanged;
  const _ZeroButtons({required this.controller, required this.onChanged});

  void _append(String zeros) {
    final raw = ThousandsFormatter.strip(controller.text);
    if (raw.isEmpty || raw == '0' || raw.contains('.')) return;
    controller.value = const ThousandsFormatter().formatEditUpdate(
      controller.value,
      TextEditingValue(text: '$raw$zeros'),
    );
    Sfx.click();
    onChanged();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextButton(
          style: TextButton.styleFrom(
            minimumSize: const Size(38, 32),
            padding: const EdgeInsets.symmetric(horizontal: 6),
          ),
          onPressed: () => _append('00'),
          child: const Text('+00',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800)),
        ),
        TextButton(
          style: TextButton.styleFrom(
            minimumSize: const Size(38, 32),
            padding: const EdgeInsets.symmetric(horizontal: 6),
          ),
          onPressed: () => _append('000'),
          child: const Text('+000',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800)),
        ),
      ],
    );
  }
}
