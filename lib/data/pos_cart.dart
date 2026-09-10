import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/models.dart';

/// سطر في سلة نقطة البيع.
class CartEntry {
  final Item item;
  final double quantity;
  final double unitPrice;

  const CartEntry({
    required this.item,
    this.quantity = 1.0,
    required this.unitPrice,
  });

  double get total => quantity * unitPrice;

  CartEntry copyWith({Item? item, double? quantity, double? unitPrice}) =>
      CartEntry(
        item: item ?? this.item,
        quantity: quantity ?? this.quantity,
        unitPrice: unitPrice ?? this.unitPrice,
      );
}

/// حالة مسودة فاتورة نقطة البيع كاملة — تعيش في Riverpod لا في حالة
/// الشاشة، فالتنقل بعيداً عن تبويب POS (حتى بالخطأ) لا يُفقد السلة؛
/// تُصفَّر فقط عند إتمام البيع أو الإفراغ الصريح.
class PosDraft {
  final Map<int, CartEntry> cart;
  final int? customerId;
  final String payment; // cash | credit | partial
  final String paidText;
  final String discountText;
  final bool discountIsPercent;
  final String notesText;

  const PosDraft({
    this.cart = const {},
    this.customerId,
    this.payment = 'cash',
    this.paidText = '',
    this.discountText = '',
    this.discountIsPercent = false,
    this.notesText = '',
  });

  static const _sentinel = Object();

  PosDraft copyWith({
    Map<int, CartEntry>? cart,
    Object? customerId = _sentinel,
    String? payment,
    String? paidText,
    String? discountText,
    bool? discountIsPercent,
    String? notesText,
  }) =>
      PosDraft(
        cart: cart ?? this.cart,
        customerId: identical(customerId, _sentinel)
            ? this.customerId
            : customerId as int?,
        payment: payment ?? this.payment,
        paidText: paidText ?? this.paidText,
        discountText: discountText ?? this.discountText,
        discountIsPercent: discountIsPercent ?? this.discountIsPercent,
        notesText: notesText ?? this.notesText,
      );

  double get subtotal =>
      cart.values.fold<double>(0.0, (sum, e) => sum + e.total);

  /// قيمة الخصم الفعلية وفق النمط: نسبة مئوية من المجموع أو مبلغ مقطوع.
  double get discountValue {
    final raw =
        double.tryParse(discountText.replaceAll(',', '').trim()) ?? 0.0;
    if (raw <= 0) return 0.0;
    if (discountIsPercent) {
      final pct = raw.clamp(0.0, 100.0);
      return subtotal * pct / 100.0;
    }
    return raw.clamp(0.0, subtotal);
  }

  double get netTotal =>
      (subtotal - discountValue).clamp(0.0, double.infinity);

  int get itemCount =>
      cart.values.fold<int>(0, (sum, e) => sum + e.quantity.toInt());
}

class PosDraftNotifier extends StateNotifier<PosDraft> {
  PosDraftNotifier() : super(const PosDraft());

  /// إضافة صنف (أو زيادة كميته). يعيد false إذا مُنع لنفاد الرصيد.
  bool addItem(Item item, {required bool allowNegative}) {
    final id = item.id;
    if (id == null) return false;
    final inCart = state.cart[id]?.quantity ?? 0.0;
    if (!allowNegative && inCart + 1 > item.quantity) return false;
    final next = Map<int, CartEntry>.from(state.cart);
    next[id] = (next[id] ??
            CartEntry(
              item: item,
              quantity: 0,
              unitPrice:
                  item.sellPrice > 0 ? item.sellPrice : item.buyPrice,
            ))
        .copyWith(quantity: inCart + 1);
    state = state.copyWith(cart: next);
    return true;
  }

  /// تحديد كمية سطر مباشرة (إدخال رقمي سريع). يعيد false إن رُفضت.
  bool setQuantity(int itemId, double qty, {required bool allowNegative}) {
    final entry = state.cart[itemId];
    if (entry == null) return false;
    if (qty <= 0) {
      removeItem(itemId);
      return true;
    }
    if (!allowNegative && qty > entry.item.quantity) return false;
    final next = Map<int, CartEntry>.from(state.cart);
    next[itemId] = entry.copyWith(quantity: qty);
    state = state.copyWith(cart: next);
    return true;
  }

  void setUnitPrice(int itemId, double price) {
    final entry = state.cart[itemId];
    if (entry == null || price <= 0) return;
    final next = Map<int, CartEntry>.from(state.cart);
    next[itemId] = entry.copyWith(unitPrice: price);
    state = state.copyWith(cart: next);
  }

  void removeItem(int itemId) {
    final next = Map<int, CartEntry>.from(state.cart)..remove(itemId);
    state = state.copyWith(cart: next);
  }

  void setCustomer(int? id) => state = state.copyWith(customerId: id);
  void setPayment(String p) => state = state.copyWith(payment: p);
  void setPaid(String t) => state = state.copyWith(paidText: t);
  void setDiscount(String t) => state = state.copyWith(discountText: t);
  void setDiscountIsPercent(bool v) =>
      state = state.copyWith(discountIsPercent: v);
  void setNotes(String t) => state = state.copyWith(notesText: t);

  void clear() => state = const PosDraft();
}

/// مسودة نقطة البيع الحية — تبقى عبر التنقل بين التبويبات.
final posDraftProvider =
    StateNotifierProvider<PosDraftNotifier, PosDraft>(
        (ref) => PosDraftNotifier());
