import React, { useState } from 'react';
import { UserCheck, Plus, Edit2, Trash2, Key, Shield } from 'lucide-react';
import { User, UserRole } from '../types';
import { api } from '../api';
import { ConfirmModal } from './ConfirmModal';

interface UsersViewProps {
  users: User[];
  onRefresh: () => void;
  onOpenUserModal: (user?: User) => void;
  onShowToast: (msg: string, type?: 'success' | 'error' | 'info') => void;
}

export const UsersView: React.FC<UsersViewProps> = ({
  users,
  onRefresh,
  onOpenUserModal,
  onShowToast,
}) => {
  const [deleteUserTarget, setDeleteUserTarget] = useState<User | null>(null);
  const [isDeleting, setIsDeleting] = useState(false);

  const handleConfirmDelete = async () => {
    if (!deleteUserTarget) return;
    setIsDeleting(true);
    try {
      await api.deleteUser(deleteUserTarget.id);
      onShowToast(`تم حذف المستخدم "${deleteUserTarget.name}" بنجاح`, 'success');
      setDeleteUserTarget(null);
      onRefresh();
    } catch (err: any) {
      onShowToast(err.message || 'فشل حذف المستخدم', 'error');
    } finally {
      setIsDeleting(false);
    }
  };

  const getRoleBadge = (role: UserRole) => {
    switch (role) {
      case 'admin':
        return { label: 'مدير النظام (Admin)', class: 'bg-purple-50 text-purple-700 border-purple-200' };
      case 'agent':
        return { label: 'وكيل مبيعات (Agent)', class: 'bg-sky-50 text-sky-700 border-sky-200' };
      case 'accountant':
        return { label: 'محاسب (Accountant)', class: 'bg-emerald-50 text-emerald-700 border-emerald-200' };
      case 'dataentry':
        return { label: 'مدخل بيانات (Data Entry)', class: 'bg-amber-50 text-amber-700 border-amber-200' };
      case 'viewer':
        return { label: 'مشاهد فقط (Viewer)', class: 'bg-slate-100 text-slate-700 border-slate-200' };
      default:
        return { label: role, class: 'bg-slate-100 text-slate-700 border-slate-200' };
    }
  };

  return (
    <div className="space-y-4">
      <div className="bg-white rounded-2xl p-4 border border-slate-200 shadow-xs flex items-center justify-between">
        <div>
          <h3 className="font-extrabold text-sm text-slate-800">المستخدمون وصلاحيات الوصول</h3>
          <p className="text-xs text-slate-400">إدارة حسابات الفريق ورموز الدخول PIN والصلاحيات</p>
        </div>
        <button
          onClick={() => onOpenUserModal()}
          className="flex items-center gap-1.5 px-3.5 py-2 text-xs font-bold bg-sky-600 hover:bg-sky-700 text-white rounded-xl shadow-xs transition-colors"
        >
          <Plus className="w-4 h-4" />
          <span>مستخدم جديد</span>
        </button>
      </div>

      <div className="bg-white rounded-2xl border border-slate-200 shadow-xs overflow-hidden">
        <div className="overflow-x-auto">
          <table className="w-full text-right text-xs">
            <thead className="bg-slate-50/80 border-b border-slate-200 text-slate-500 font-bold">
              <tr>
                <th className="py-3.5 px-4">اسم المستخدم</th>
                <th className="py-3.5 px-4">الدور الوظيفي</th>
                <th className="py-3.5 px-4">رمز الدخول PIN</th>
                <th className="py-3.5 px-4">تاريخ الإنشاء</th>
                <th className="py-3.5 px-4 text-left">إجراءات</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-100">
              {users.map((user) => {
                const badge = getRoleBadge(user.role);
                return (
                  <tr key={user.id} className="hover:bg-slate-50/70 transition-colors">
                    <td className="py-3.5 px-4">
                      <div className="flex items-center gap-2.5">
                        <div className="w-8 h-8 rounded-xl bg-slate-100 text-slate-700 flex items-center justify-center font-bold">
                          {user.name.slice(0, 1)}
                        </div>
                        <span className="font-extrabold text-slate-800">{user.name}</span>
                      </div>
                    </td>

                    <td className="py-3.5 px-4">
                      <span className={`text-[10px] px-2.5 py-0.5 rounded-full font-bold border ${badge.class}`}>
                        {badge.label}
                      </span>
                    </td>

                    <td className="py-3.5 px-4 font-mono">
                      <span className="text-slate-400">••••</span>
                    </td>

                    <td className="py-3.5 px-4 text-slate-500 font-mono text-[11px]">
                      {new Date(user.created_at).toLocaleDateString('ar-YE')}
                    </td>

                    <td className="py-3.5 px-4 text-left">
                      <div className="flex items-center justify-end gap-1.5">
                        <button
                          onClick={() => onOpenUserModal(user)}
                          className="p-1.5 rounded-lg text-slate-500 hover:text-slate-800 hover:bg-slate-100 transition-colors"
                          title="تعديل"
                        >
                          <Edit2 className="w-3.5 h-3.5" />
                        </button>
                        <button
                          onClick={() => setDeleteUserTarget(user)}
                          className="p-1.5 rounded-lg text-slate-400 hover:text-rose-600 hover:bg-rose-50 transition-colors"
                          title="حذف"
                        >
                          <Trash2 className="w-3.5 h-3.5" />
                        </button>
                      </div>
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      </div>

      <ConfirmModal
        isOpen={Boolean(deleteUserTarget)}
        title="تأكيد حذف المستخدم"
        message={`هل أنت متأكد من حذف المستخدم "${deleteUserTarget?.name}" وإلغاء إمكانية دخوله للنظام؟`}
        confirmLabel="حذف المستخدم"
        cancelLabel="تراجع"
        variant="danger"
        isLoading={isDeleting}
        onConfirm={handleConfirmDelete}
        onCancel={() => setDeleteUserTarget(null)}
      />
    </div>
  );
};
