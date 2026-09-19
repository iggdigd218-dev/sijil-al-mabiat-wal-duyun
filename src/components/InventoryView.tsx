import React, { useState } from 'react';
import { Package, Plus, Search, Edit2, Trash2, AlertTriangle } from 'lucide-react';
import { Item } from '../types';
import { api } from '../api';
import { ConfirmModal } from './ConfirmModal';

interface InventoryViewProps {
  items: Item[];
  onRefresh: () => void;
  onOpenItemModal: (item?: Item) => void;
  onShowToast: (msg: string, type?: 'success' | 'error' | 'info') => void;
}

export const InventoryView: React.FC<InventoryViewProps> = ({
  items,
  onRefresh,
  onOpenItemModal,
  onShowToast,
}) => {
  const [search, setSearch] = useState('');
  const [categoryFilter, setCategoryFilter] = useState('all');
  const [deleteItemTarget, setDeleteItemTarget] = useState<Item | null>(null);
  const [isDeleting, setIsDeleting] = useState(false);

  const categories = ['all', ...Array.from(new Set(items.map((i) => i.category).filter(Boolean)))];

  const filtered = items.filter((item) => {
    const matchesSearch =
      item.name.toLowerCase().includes(search.toLowerCase()) ||
      item.sku.toLowerCase().includes(search.toLowerCase());
    const matchesCat = categoryFilter === 'all' || item.category === categoryFilter;
    return matchesSearch && matchesCat;
  });

  const handleConfirmDelete = async () => {
    if (!deleteItemTarget) return;
    setIsDeleting(true);
    try {
      await api.deleteItem(deleteItemTarget.id);
      onShowToast(`تم حذف الصنف "${deleteItemTarget.name}" بنجاح`, 'success');
      setDeleteItemTarget(null);
      onRefresh();
    } catch (err: any) {
      onShowToast(err.message || 'فشل حذف الصنف', 'error');
    } finally {
      setIsDeleting(false);
    }
  };

  return (
    <div className="space-y-4">
      {/* Header controls */}
      <div className="bg-white rounded-2xl p-4 border border-slate-200 shadow-xs flex flex-col sm:flex-row sm:items-center justify-between gap-3">
        <div className="flex items-center gap-2 overflow-x-auto pb-1 sm:pb-0">
          {categories.map((cat) => (
            <button
              key={cat}
              onClick={() => setCategoryFilter(cat)}
              className={`px-3 py-1.5 rounded-xl text-xs font-bold transition-colors ${
                categoryFilter === cat
                  ? 'bg-sky-600 text-white shadow-xs'
                  : 'bg-slate-100 text-slate-600 hover:bg-slate-200'
              }`}
            >
              {cat === 'all' ? `جميع الأصناف (${items.length})` : cat}
            </button>
          ))}
        </div>

        <div className="flex items-center gap-2">
          <div className="relative flex-1 sm:w-64">
            <Search className="w-4 h-4 absolute right-3 top-3 text-slate-400" />
            <input
              type="text"
              value={search}
              onChange={(e) => setSearch(e.target.value)}
              placeholder="بحث بالاسم أو SKU..."
              className="w-full pr-9 pl-3 py-2 bg-slate-50 border border-slate-200 rounded-xl text-xs focus:bg-white focus:outline-hidden"
            />
          </div>

          <button
            id="btn-add-item-view"
            onClick={() => onOpenItemModal()}
            className="flex items-center gap-1.5 px-3.5 py-2 text-xs font-bold bg-sky-600 hover:bg-sky-700 text-white rounded-xl shadow-xs transition-colors shrink-0"
          >
            <Plus className="w-4 h-4" />
            <span>صنف جديد</span>
          </button>
        </div>
      </div>

      {/* Inventory Table */}
      <div className="bg-white rounded-2xl border border-slate-200 shadow-xs overflow-hidden">
        <div className="overflow-x-auto">
          <table className="w-full text-right text-xs">
            <thead className="bg-slate-50/80 border-b border-slate-200 text-slate-500 font-bold">
              <tr>
                <th className="py-3.5 px-4">الصنف ورمز SKU</th>
                <th className="py-3.5 px-4">الفئة</th>
                <th className="py-3.5 px-4">سعر الشراء</th>
                <th className="py-3.5 px-4">سعر البيع</th>
                <th className="py-3.5 px-4">الكمية المتوفرة</th>
                <th className="py-3.5 px-4 text-left">إجراءات</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-100">
              {filtered.length === 0 ? (
                <tr>
                  <td colSpan={6} className="py-12 text-center text-slate-400">
                    لا توجد أصناف في المخزون مطابقة
                  </td>
                </tr>
              ) : (
                filtered.map((item) => {
                  const isLow = item.quantity <= item.min_quantity;
                  return (
                    <tr key={item.id} className="hover:bg-slate-50/70 transition-colors">
                      <td className="py-3.5 px-4">
                        <div className="flex items-center gap-3">
                          <div className="w-8 h-8 rounded-xl bg-slate-100 text-slate-600 flex items-center justify-center shrink-0">
                            <Package className="w-4 h-4" />
                          </div>
                          <div>
                            <div className="font-extrabold text-slate-800 text-xs">{item.name}</div>
                            {item.sku && (
                              <div className="text-[10px] text-slate-400 font-mono">{item.sku}</div>
                            )}
                          </div>
                        </div>
                      </td>

                      <td className="py-3.5 px-4">
                        <span className="text-[10px] font-bold px-2 py-0.5 rounded-full bg-slate-100 text-slate-600">
                          {item.category || 'عام'}
                        </span>
                      </td>

                      <td className="py-3.5 px-4 font-mono text-slate-600">
                        {item.buy_price} ر.ي
                      </td>

                      <td className="py-3.5 px-4 font-mono font-bold text-sky-600">
                        {item.sell_price} ر.ي
                      </td>

                      <td className="py-3.5 px-4 font-mono">
                        <div className="flex items-center gap-1.5">
                          <span
                            className={`text-xs font-bold ${
                              isLow ? 'text-rose-600 font-black' : 'text-slate-900'
                            }`}
                          >
                            {item.quantity}
                          </span>
                          {isLow && (
                            <span className="text-[10px] px-1.5 py-0.5 rounded-sm bg-rose-50 text-rose-600 border border-rose-200 font-bold flex items-center gap-0.5">
                              <AlertTriangle className="w-3 h-3" />
                              <span>حد الطلب ({item.min_quantity})</span>
                            </span>
                          )}
                        </div>
                      </td>

                      <td className="py-3.5 px-4 text-left">
                        <div className="flex items-center justify-end gap-1.5">
                          <button
                            onClick={() => onOpenItemModal(item)}
                            className="p-1.5 rounded-lg text-slate-500 hover:text-slate-800 hover:bg-slate-100 transition-colors"
                            title="تعديل الصنف"
                          >
                            <Edit2 className="w-3.5 h-3.5" />
                          </button>
                          <button
                            onClick={() => setDeleteItemTarget(item)}
                            className="p-1.5 rounded-lg text-slate-400 hover:text-rose-600 hover:bg-rose-50 transition-colors"
                            title="حذف الصنف"
                          >
                            <Trash2 className="w-3.5 h-3.5" />
                          </button>
                        </div>
                      </td>
                    </tr>
                  );
                })
              )}
            </tbody>
          </table>
        </div>
      </div>

      {/* Confirm Delete Modal */}
      <ConfirmModal
        isOpen={Boolean(deleteItemTarget)}
        title="تأكيد حذف الصنف من المخزون"
        message={`هل أنت متأكد من رغبتك في حذف الصنف "${deleteItemTarget?.name}" من قائمة المخزون؟ لن يتم حذف العمليات السابقة التي تضمنت هذا الصنف.`}
        confirmLabel="حذف الصنف"
        cancelLabel="تراجع"
        variant="danger"
        isLoading={isDeleting}
        onConfirm={handleConfirmDelete}
        onCancel={() => setDeleteItemTarget(null)}
      />
    </div>
  );
};
