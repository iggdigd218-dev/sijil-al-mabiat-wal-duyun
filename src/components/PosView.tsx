import React, { useState } from 'react';
import {
  Search,
  ShoppingCart,
  Plus,
  Minus,
  Trash2,
  Check,
  CreditCard,
  Banknote,
  Package,
  ArrowLeft,
  Printer,
  MessageCircle,
  Copy,
  Barcode,
} from 'lucide-react';
import { Item, Account } from '../types';
import { api } from '../api';

interface PosViewProps {
  items: Item[];
  accounts: Account[];
  businessName?: string;
  onRefreshItems: () => void;
  onShowToast: (msg: string, type?: 'success' | 'error' | 'info') => void;
}

interface CartItem {
  item: Item;
  quantity: number;
  unitPrice: number;
}

export const PosView: React.FC<PosViewProps> = ({
  items,
  accounts,
  businessName = 'سجل المبيعات والديون',
  onRefreshItems,
  onShowToast,
}) => {
  const [search, setSearch] = useState('');
  const [selectedCategory, setSelectedCategory] = useState<string>('all');
  const [cart, setCart] = useState<CartItem[]>([]);
  const [discount, setDiscount] = useState<number>(0);
  const [selectedAccountId, setSelectedAccountId] = useState<string>('');
  const [isCheckingOut, setIsCheckingOut] = useState(false);
  const [lastReceipt, setLastReceipt] = useState<any | null>(null);
  const [copied, setCopied] = useState(false);

  const categories = ['all', ...Array.from(new Set(items.map((i) => i.category).filter(Boolean)))];

  const filteredItems = items.filter((item) => {
    const matchesSearch =
      item.name.toLowerCase().includes(search.toLowerCase()) ||
      item.sku.toLowerCase().includes(search.toLowerCase());
    const matchesCategory = selectedCategory === 'all' || item.category === selectedCategory;
    return matchesSearch && matchesCategory;
  });

  const addToCart = (item: Item) => {
    setCart((prev) => {
      const existing = prev.find((c) => c.item.id === item.id);
      if (existing) {
        return prev.map((c) =>
          c.item.id === item.id ? { ...c, quantity: c.quantity + 1 } : c
        );
      }
      return [...prev, { item, quantity: 1, unitPrice: item.sell_price }];
    });
  };

  const handleBarcodeOrEnter = (e: React.KeyboardEvent<HTMLInputElement>) => {
    if (e.key === 'Enter' && search.trim()) {
      const trimmed = search.trim().toLowerCase();
      // Try exact SKU or barcode match first
      const exactItem = items.find((i) => i.sku?.toLowerCase() === trimmed || i.name.toLowerCase() === trimmed);
      if (exactItem) {
        addToCart(exactItem);
        onShowToast(`تمت إضافة "${exactItem.name}" إلى السلة`, 'success');
        setSearch('');
        return;
      }
      // If single item matched filter
      if (filteredItems.length === 1) {
        addToCart(filteredItems[0]);
        onShowToast(`تمت إضافة "${filteredItems[0].name}" إلى السلة`, 'success');
        setSearch('');
        return;
      }
    }
  };

  const updateQuantity = (itemId: number, delta: number) => {
    setCart((prev) =>
      prev
        .map((c) => {
          if (c.item.id === itemId) {
            const newQty = c.quantity + delta;
            return newQty > 0 ? { ...c, quantity: newQty } : null;
          }
          return c;
        })
        .filter(Boolean) as CartItem[]
    );
  };

  const removeFromCart = (itemId: number) => {
    setCart((prev) => prev.filter((c) => c.item.id !== itemId));
  };

  const clearCart = () => {
    setCart([]);
    setDiscount(0);
    setSelectedAccountId('');
  };

  const subtotal = cart.reduce((sum, c) => sum + c.quantity * c.unitPrice, 0);
  const total = Math.max(0, subtotal - (discount || 0));

  const handleCheckout = async (paymentMode: 'cash' | 'credit') => {
    if (cart.length === 0) {
      onShowToast('السلة فارغة، أضف أصنافاً أولاً', 'error');
      return;
    }

    if (paymentMode === 'credit' && !selectedAccountId) {
      onShowToast('يجب اختيار حساب العميل للبيع الآجل', 'error');
      return;
    }

    setIsCheckingOut(true);
    try {
      const selectedAccount = accounts.find((a) => String(a.id) === selectedAccountId);
      const customerName = selectedAccount ? selectedAccount.name : 'عميل نقدي';

      const txItems = cart.map((c) => ({
        name: c.item.name,
        quantity: c.quantity,
        unit_price: c.unitPrice,
        total: c.quantity * c.unitPrice,
      }));

      // In the database:
      // - Credit sale (آجل) = 'debit' on customer account (مستحق لنا)
      // - Cash sale (نقدي) = 'inflow' (قبض نقدي)
      const txType = paymentMode === 'credit' ? 'debit' : 'inflow';

      const res = await api.createTransaction({
        account_id: selectedAccount ? selectedAccount.id : undefined,
        type: txType,
        amount: total,
        currency: 'YER',
        description: `فاتورة مبيعات (${paymentMode === 'credit' ? 'آجل' : 'نقدي'}) - ${cart.length} أصناف`,
        reference: `POS-${Date.now().toString().slice(-6)}`,
        items: txItems,
        date: new Date().toISOString(),
      });

      setLastReceipt({
        id: res.id,
        date: new Date().toLocaleString('ar-YE'),
        customerName,
        customerPhone: selectedAccount?.phone || selectedAccount?.whatsapp || '',
        paymentMode: paymentMode === 'credit' ? 'آجل' : 'نقدي',
        items: [...cart],
        subtotal,
        discount,
        total,
      });

      onShowToast(`✅ تم إصدار الفاتورة رقم #${res.id} بنجاح!`, 'success');
      clearCart();
      onRefreshItems();
    } catch (err: any) {
      onShowToast(err.message || 'فشلت عملية البيع', 'error');
    } finally {
      setIsCheckingOut(false);
    }
  };

  const generateReceiptWhatsAppText = () => {
    if (!lastReceipt) return '';
    const itemsList = lastReceipt.items
      .map((it: CartItem) => `• ${it.item.name} × ${it.quantity} = ${it.quantity * it.unitPrice} ر.ي`)
      .join('\n');

    return `🧾 فاتورة مبيعات - ${businessName}
رقم الفاتورة: #${lastReceipt.id}
العميل: ${lastReceipt.customerName}
التاريخ: ${lastReceipt.date}
طريقة الدفع: ${lastReceipt.paymentMode}
----------------------------
الأصناف:
${itemsList}
----------------------------
المجموع: ${lastReceipt.subtotal} ر.ي
${lastReceipt.discount > 0 ? `الخصم: ${lastReceipt.discount} ر.ي\n` : ''}الإجمالي الصافي: ${lastReceipt.total} ر.ي

شاكرين لكم زيارتكم الكريمة!`;
  };

  const handleShareReceiptWhatsApp = () => {
    const text = generateReceiptWhatsAppText();
    const phone = (lastReceipt?.customerPhone || '').replace(/[^0-9]/g, '');
    const url = phone
      ? `https://wa.me/${phone}?text=${encodeURIComponent(text)}`
      : `https://wa.me/?text=${encodeURIComponent(text)}`;
    window.open(url, '_blank');
    onShowToast('تم تجهيز الفاتورة للإرسال عبر واتساب', 'success');
  };

  const handleCopyReceiptText = () => {
    const text = generateReceiptWhatsAppText();
    navigator.clipboard.writeText(text);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
    onShowToast('تم نسخ نص الفاتورة للحافظة', 'success');
  };

  return (
    <div className="space-y-4">
      {/* Receipt Modal if available */}
      {lastReceipt && (
        <div className="fixed inset-0 bg-slate-900/60 backdrop-blur-xs flex items-center justify-center p-4 z-50 animate-in fade-in duration-200">
          <div className="bg-white rounded-3xl p-6 max-w-sm w-full border border-slate-200 shadow-2xl space-y-4 text-right">
            <div className="text-center pb-3 border-b border-dashed border-slate-200">
              <div className="w-12 h-12 rounded-2xl bg-emerald-100 text-emerald-600 flex items-center justify-center mx-auto mb-2 text-2xl font-bold">
                ✓
              </div>
              <h3 className="font-extrabold text-base text-slate-900">فاتورة مبيعات</h3>
              <p className="text-xs text-slate-400 font-mono">#{lastReceipt.id}</p>
            </div>

            <div className="text-xs space-y-1.5 text-slate-600">
              <div className="flex justify-between">
                <span>العميل:</span>
                <span className="font-bold text-slate-900">{lastReceipt.customerName}</span>
              </div>
              <div className="flex justify-between">
                <span>طريقة الدفع:</span>
                <span className="font-bold text-slate-900">{lastReceipt.paymentMode}</span>
              </div>
              <div className="flex justify-between">
                <span>التاريخ:</span>
                <span className="font-mono text-[11px]">{lastReceipt.date}</span>
              </div>
            </div>

            <div className="border-t border-b border-dashed border-slate-200 py-3 space-y-2 max-h-48 overflow-y-auto text-xs">
              {lastReceipt.items.map((it: CartItem, idx: number) => (
                <div key={idx} className="flex justify-between items-center">
                  <div>
                    <span className="font-semibold text-slate-800">{it.item.name}</span>
                    <span className="text-slate-400 text-[11px] mr-1">× {it.quantity}</span>
                  </div>
                  <span className="font-mono font-bold">{it.quantity * it.unitPrice} ر.ي</span>
                </div>
              ))}
            </div>

            <div className="space-y-1 text-xs">
              {lastReceipt.discount > 0 && (
                <div className="flex justify-between text-slate-500">
                  <span>الخصم:</span>
                  <span className="font-mono">-{lastReceipt.discount} ر.ي</span>
                </div>
              )}
              <div className="flex justify-between text-base font-extrabold text-slate-900 pt-1">
                <span>الإجمالي:</span>
                <span className="text-emerald-600 font-mono">{lastReceipt.total} ر.ي</span>
              </div>
            </div>

            {/* Receipt Actions */}
            <div className="grid grid-cols-2 gap-2 pt-1">
              <button
                onClick={handleShareReceiptWhatsApp}
                className="py-2 px-3 rounded-xl bg-emerald-600 hover:bg-emerald-700 text-white text-xs font-bold flex items-center justify-center gap-1.5 transition-colors"
              >
                <MessageCircle className="w-4 h-4" />
                <span>واتساب</span>
              </button>
              <button
                onClick={handleCopyReceiptText}
                className="py-2 px-3 rounded-xl border border-slate-200 bg-slate-50 hover:bg-slate-100 text-slate-700 text-xs font-bold flex items-center justify-center gap-1.5 transition-colors"
              >
                {copied ? <Check className="w-4 h-4 text-emerald-600" /> : <Copy className="w-4 h-4" />}
                <span>{copied ? 'تم النسخ' : 'نسخ النص'}</span>
              </button>
            </div>

            <div className="flex gap-2 pt-1">
              <button
                onClick={() => window.print()}
                className="flex-1 py-2 rounded-xl border border-slate-300 text-xs font-bold text-slate-700 hover:bg-slate-50 flex items-center justify-center gap-1.5"
              >
                <Printer className="w-4 h-4" />
                <span>طباعة</span>
              </button>
              <button
                onClick={() => setLastReceipt(null)}
                className="flex-1 py-2 rounded-xl bg-slate-900 text-white text-xs font-bold hover:bg-slate-800 transition-colors"
              >
                إغلاق
              </button>
            </div>
          </div>
        </div>
      )}

      <div className="grid grid-cols-1 lg:grid-cols-12 gap-6 items-start">
        {/* Items catalog (8 cols) */}
        <div className="lg:col-span-8 space-y-4">
          {/* Search & Category Filter */}
          <div className="bg-white rounded-2xl p-4 border border-slate-200 shadow-xs space-y-3">
            <div className="relative">
              <Search className="w-4 h-4 absolute right-3.5 top-3.5 text-slate-400" />
              <input
                id="input-pos-search"
                type="text"
                value={search}
                onChange={(e) => setSearch(e.target.value)}
                onKeyDown={handleBarcodeOrEnter}
                placeholder="ابحث بالاسم أو امسح الباركود / SKU واضغط Enter..."
                className="w-full pr-10 pl-10 py-2.5 bg-slate-50 border border-slate-200 rounded-xl text-xs focus:bg-white focus:outline-hidden focus:border-sky-500 transition-colors"
              />
              <Barcode className="w-4 h-4 absolute left-3.5 top-3.5 text-slate-400" />
            </div>

            {/* Category pills */}
            <div className="flex items-center gap-2 overflow-x-auto pb-1">
              {categories.map((cat) => (
                <button
                  key={cat}
                  onClick={() => setSelectedCategory(cat)}
                  className={`px-3 py-1.5 rounded-xl text-xs font-bold shrink-0 transition-colors ${
                    selectedCategory === cat
                      ? 'bg-sky-600 text-white shadow-xs'
                      : 'bg-slate-100 text-slate-600 hover:bg-slate-200'
                  }`}
                >
                  {cat === 'all' ? 'جميع الأصناف' : cat}
                </button>
              ))}
            </div>
          </div>

          {/* Items Grid */}
          <div className="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 gap-3">
            {filteredItems.length === 0 ? (
              <div className="col-span-full py-16 text-center text-slate-400">
                <Package className="w-8 h-8 mx-auto mb-2 opacity-40" />
                <p className="text-xs">لم يتم العثور على أصناف مطابقة</p>
              </div>
            ) : (
              filteredItems.map((item) => {
                const inCart = cart.find((c) => c.item.id === item.id);
                const isLowStock = item.quantity <= item.min_quantity;
                return (
                  <div
                    key={item.id}
                    onClick={() => addToCart(item)}
                    className={`bg-white rounded-2xl p-3.5 border transition-all cursor-pointer select-none flex flex-col justify-between relative group hover:shadow-md hover:-translate-y-0.5 ${
                      inCart
                        ? 'border-sky-500 ring-2 ring-sky-500/20 bg-sky-50/20'
                        : 'border-slate-200 hover:border-sky-300'
                    }`}
                  >
                    <div>
                      <div className="flex items-start justify-between gap-1 mb-1.5">
                        <span className="text-[10px] font-bold px-2 py-0.5 rounded-md bg-slate-100 text-slate-600 truncate max-w-[80px]">
                          {item.category || 'عام'}
                        </span>
                        {isLowStock && (
                          <span className="text-[9px] font-bold px-1.5 py-0.5 rounded-sm bg-rose-100 text-rose-700">
                            منخفض
                          </span>
                        )}
                      </div>
                      <h4 className="text-xs font-bold text-slate-800 line-clamp-2 leading-tight">
                        {item.name}
                      </h4>
                      {item.sku && (
                        <p className="text-[10px] text-slate-400 font-mono mt-0.5">{item.sku}</p>
                      )}
                    </div>

                    <div className="mt-4 pt-2 border-t border-slate-100 flex items-end justify-between">
                      <div>
                        <div className="text-xs font-extrabold text-sky-600 font-mono">
                          {item.sell_price} ر.ي
                        </div>
                        <div className="text-[10px] text-slate-400">
                          المتوفر: {item.quantity}
                        </div>
                      </div>

                      {inCart ? (
                        <span className="w-6 h-6 rounded-lg bg-sky-600 text-white flex items-center justify-center text-xs font-bold">
                          {inCart.quantity}
                        </span>
                      ) : (
                        <span className="w-6 h-6 rounded-lg bg-slate-100 group-hover:bg-sky-100 text-slate-600 group-hover:text-sky-600 flex items-center justify-center text-xs font-bold transition-colors">
                          +
                        </span>
                      )}
                    </div>
                  </div>
                );
              })
            )}
          </div>
        </div>

        {/* Cart panel (4 cols) */}
        <div className="lg:col-span-4 bg-white rounded-2xl border border-slate-200 shadow-xs p-5 space-y-4 sticky top-20">
          <div className="flex items-center justify-between pb-3 border-b border-slate-100">
            <div className="flex items-center gap-2">
              <ShoppingCart className="w-4 h-4 text-sky-600" />
              <h3 className="font-extrabold text-sm text-slate-800">سلة الفاتورة</h3>
            </div>
            {cart.length > 0 && (
              <button
                onClick={clearCart}
                className="text-[11px] font-bold text-rose-500 hover:text-rose-600"
              >
                إفراغ السلة
              </button>
            )}
          </div>

          {/* Cart items list */}
          <div className="space-y-2 max-h-60 overflow-y-auto pr-0.5">
            {cart.length === 0 ? (
              <div className="py-10 text-center text-slate-400">
                <ShoppingCart className="w-8 h-8 mx-auto mb-1.5 opacity-30" />
                <p className="text-xs">السلة فارغة</p>
                <p className="text-[11px] text-slate-400 mt-0.5">انقر على أي صنف لإضافته للفاتورة</p>
              </div>
            ) : (
              cart.map((c) => (
                <div
                  key={c.item.id}
                  className="p-2.5 rounded-xl bg-slate-50 border border-slate-100 flex items-center justify-between gap-2 text-xs"
                >
                  <div className="flex-1 min-w-0">
                    <div className="font-bold text-slate-800 truncate">{c.item.name}</div>
                    <div className="text-[11px] text-slate-400 font-mono">
                      {c.unitPrice} ر.ي × {c.quantity} = {c.unitPrice * c.quantity} ر.ي
                    </div>
                  </div>

                  <div className="flex items-center gap-1 shrink-0">
                    <button
                      onClick={() => updateQuantity(c.item.id, -1)}
                      className="w-6 h-6 rounded-md bg-white border border-slate-200 text-slate-600 flex items-center justify-center hover:bg-slate-100"
                    >
                      <Minus className="w-3 h-3" />
                    </button>
                    <span className="w-6 text-center font-bold font-mono text-xs">
                      {c.quantity}
                    </span>
                    <button
                      onClick={() => updateQuantity(c.item.id, 1)}
                      className="w-6 h-6 rounded-md bg-white border border-slate-200 text-slate-600 flex items-center justify-center hover:bg-slate-100"
                    >
                      <Plus className="w-3 h-3" />
                    </button>
                    <button
                      onClick={() => removeFromCart(c.item.id)}
                      className="w-6 h-6 rounded-md text-slate-400 hover:text-rose-500 flex items-center justify-center mr-1"
                    >
                      <Trash2 className="w-3.5 h-3.5" />
                    </button>
                  </div>
                </div>
              ))
            )}
          </div>

          {/* Pricing breakdown */}
          <div className="pt-3 border-t border-slate-100 space-y-2 text-xs">
            <div className="flex justify-between text-slate-500">
              <span>المجموع الفرعي:</span>
              <span className="font-mono font-bold">{subtotal} ر.ي</span>
            </div>

            <div className="flex items-center justify-between gap-2">
              <span className="text-slate-500">الخصم:</span>
              <div className="flex items-center gap-1 w-28">
                <input
                  type="number"
                  min="0"
                  value={discount || ''}
                  onChange={(e) => setDiscount(Number(e.target.value) || 0)}
                  placeholder="0"
                  className="w-full text-left font-mono py-1 px-2 rounded-lg bg-slate-50 border border-slate-200 text-xs focus:bg-white focus:outline-hidden"
                />
                <span className="text-[11px] text-slate-400">ر.ي</span>
              </div>
            </div>

            <div className="flex justify-between items-center text-sm font-black text-slate-900 pt-2 border-t border-slate-100">
              <span>الصافي المطلوب:</span>
              <span className="text-sky-600 text-base font-mono">{total} ر.ي</span>
            </div>
          </div>

          {/* Customer selection for Credit / آجل */}
          <div className="pt-2 space-y-1.5">
            <label className="text-xs font-bold text-slate-700">حساب العميل (للبيع الآجل)</label>
            <select
              id="select-pos-customer"
              value={selectedAccountId}
              onChange={(e) => setSelectedAccountId(e.target.value)}
              className="w-full py-2 px-3 bg-slate-50 border border-slate-200 rounded-xl text-xs font-medium focus:bg-white focus:outline-hidden"
            >
              <option value="">-- بيع نقدي (بدون حساب) --</option>
              {accounts.map((acc) => (
                <option key={acc.id} value={acc.id}>
                  {acc.name} ({acc.kind === 'customer' ? 'عميل' : acc.kind === 'supplier' ? 'مورد' : 'صندوق'})
                </option>
              ))}
            </select>
          </div>

          {/* Checkout Action Buttons */}
          <div className="pt-2 grid grid-cols-2 gap-2">
            <button
              id="btn-pos-cash"
              disabled={isCheckingOut || cart.length === 0}
              onClick={() => handleCheckout('cash')}
              className="py-2.5 px-3 rounded-xl bg-emerald-600 hover:bg-emerald-700 text-white text-xs font-extrabold flex items-center justify-center gap-1.5 shadow-xs transition-colors disabled:opacity-50"
            >
              <Banknote className="w-4 h-4" />
              <span>دفع نقدي</span>
            </button>

            <button
              id="btn-pos-credit"
              disabled={isCheckingOut || cart.length === 0}
              onClick={() => handleCheckout('credit')}
              className="py-2.5 px-3 rounded-xl bg-amber-500 hover:bg-amber-600 text-white text-xs font-extrabold flex items-center justify-center gap-1.5 shadow-xs transition-colors disabled:opacity-50"
            >
              <CreditCard className="w-4 h-4" />
              <span>بيع آجل (دين)</span>
            </button>
          </div>
        </div>
      </div>
    </div>
  );
};
