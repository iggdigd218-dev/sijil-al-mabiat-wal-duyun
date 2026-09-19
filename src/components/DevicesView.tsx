import React, { useState } from 'react';
import {
  Smartphone,
  Laptop,
  Crown,
  Trash2,
  Ban,
  RotateCcw,
  CheckCircle2,
  Clock,
} from 'lucide-react';
import { Device } from '../types';
import { api } from '../api';
import { ConfirmModal } from './ConfirmModal';

interface DevicesViewProps {
  devices: Device[];
  onRefresh: () => void;
  onShowToast: (msg: string, type?: 'success' | 'error' | 'info') => void;
}

export const DevicesView: React.FC<DevicesViewProps> = ({
  devices,
  onRefresh,
  onShowToast,
}) => {
  const [deleteDeviceTarget, setDeleteDeviceTarget] = useState<Device | null>(null);
  const [transferTarget, setTransferTarget] = useState<Device | null>(null);
  const [isLoading, setIsLoading] = useState(false);

  const handleConfirmDelete = async () => {
    if (!deleteDeviceTarget) return;
    setIsLoading(true);
    try {
      await api.deleteDevice(deleteDeviceTarget.id);
      onShowToast(`تم حذف وإلغاء ارتباط الجهاز "${deleteDeviceTarget.name}" بنجاح`, 'success');
      setDeleteDeviceTarget(null);
      onRefresh();
    } catch (err: any) {
      onShowToast(err.message || 'فشل حذف الجهاز', 'error');
    } finally {
      setIsLoading(false);
    }
  };

  const handleConfirmTransfer = async () => {
    if (!transferTarget) return;
    setIsLoading(true);
    try {
      await api.transferOwnership(transferTarget.id);
      onShowToast(`تم نقل ملكية المجموعة للجهاز "${transferTarget.name}" بنجاح!`, 'success');
      setTransferTarget(null);
      onRefresh();
    } catch (err: any) {
      onShowToast(err.message || 'فشل نقل الملكية', 'error');
    } finally {
      setIsLoading(false);
    }
  };

  return (
    <div className="space-y-4">
      <div className="bg-white rounded-2xl p-4 border border-slate-200 shadow-xs flex items-center justify-between">
        <div>
          <h3 className="font-extrabold text-sm text-slate-800">الأجهزة المصرح لها في المنشأة</h3>
          <p className="text-xs text-slate-400">إدارة صلاحيات وصول الأجهزة المتصلة بالمجموعة وقاعدة البيانات</p>
        </div>
        <span className="text-xs font-bold text-slate-600 bg-slate-100 px-3 py-1 rounded-xl">
          {devices.length} جهاز مرتبط
        </span>
      </div>

      <div className="bg-white rounded-2xl border border-slate-200 shadow-xs overflow-hidden">
        <div className="overflow-x-auto">
          <table className="w-full text-right text-xs">
            <thead className="bg-slate-50/80 border-b border-slate-200 text-slate-500 font-bold">
              <tr>
                <th className="py-3.5 px-4">اسم الجهاز والنوع</th>
                <th className="py-3.5 px-4">المستخدم المعين</th>
                <th className="py-3.5 px-4">الدور والصلاحية</th>
                <th className="py-3.5 px-4">آخر ظهور / مزامنة</th>
                <th className="py-3.5 px-4 text-left">إجراءات</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-100">
              {devices.map((device) => {
                const isOwner = device.is_owner === 1;
                return (
                  <tr key={device.id} className="hover:bg-slate-50/70 transition-colors">
                    <td className="py-3.5 px-4">
                      <div className="flex items-center gap-3">
                        <div
                          className={`w-9 h-9 rounded-xl flex items-center justify-center shrink-0 ${
                            isOwner
                              ? 'bg-amber-100 text-amber-600'
                              : 'bg-slate-100 text-slate-600'
                          }`}
                        >
                          {device.platform === 'web' || device.platform === 'windows' ? (
                            <Laptop className="w-4 h-4" />
                          ) : (
                            <Smartphone className="w-4 h-4" />
                          )}
                        </div>
                        <div>
                          <div className="flex items-center gap-1.5 font-extrabold text-slate-800 text-xs">
                            <span>{device.name}</span>
                            {isOwner && (
                              <span className="inline-flex items-center gap-0.5 px-2 py-0.5 rounded-full bg-amber-50 border border-amber-200 text-amber-700 text-[10px] font-bold">
                                <Crown className="w-3 h-3 text-amber-500" />
                                <span>المالك (Owner)</span>
                              </span>
                            )}
                          </div>
                          <span className="text-[10px] text-slate-400 font-mono">
                            منصة: {device.platform} • ID: {device.id.slice(0, 8)}
                          </span>
                        </div>
                      </div>
                    </td>

                    <td className="py-3.5 px-4">
                      <span className="font-bold text-slate-700">
                        {device.user_name || 'بدون مستخدم معين'}
                      </span>
                    </td>

                    <td className="py-3.5 px-4">
                      <span className="text-[10px] font-bold px-2 py-0.5 rounded-md bg-sky-50 text-sky-700 border border-sky-200">
                        {device.user_role || (isOwner ? 'admin' : 'agent')}
                      </span>
                    </td>

                    <td className="py-3.5 px-4 text-slate-500 font-mono text-[11px]">
                      <div className="flex items-center gap-1">
                        <Clock className="w-3 h-3 text-slate-400" />
                        <span>{new Date(device.last_seen_at || Date.now()).toLocaleString('ar-YE')}</span>
                      </div>
                    </td>

                    <td className="py-3.5 px-4 text-left">
                      <div className="flex items-center justify-end gap-1.5">
                        {!isOwner && (
                          <>
                            <button
                              onClick={() => setTransferTarget(device)}
                              className="p-1.5 rounded-lg text-slate-400 hover:text-amber-600 hover:bg-amber-50 transition-colors"
                              title="نقل الملكية لهذا الجهاز"
                            >
                              <Crown className="w-3.5 h-3.5" />
                            </button>
                            <button
                              onClick={() => setDeleteDeviceTarget(device)}
                              className="p-1.5 rounded-lg text-slate-400 hover:text-rose-600 hover:bg-rose-50 transition-colors"
                              title="حذف وفصل الجهاز"
                            >
                              <Trash2 className="w-3.5 h-3.5" />
                            </button>
                          </>
                        )}
                      </div>
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      </div>

      {/* Delete Device Modal */}
      <ConfirmModal
        isOpen={Boolean(deleteDeviceTarget)}
        title="تأكيد فصل وإلغاء ارتباط الجهاز"
        message={`هل أنت متأكد من حذف الجهاز "${deleteDeviceTarget?.name}" وفصل وصوله لقاعدة البيانات وسجل المبيعات؟`}
        confirmLabel="فصل الجهاز"
        cancelLabel="إلغاء"
        variant="danger"
        isLoading={isLoading}
        onConfirm={handleConfirmDelete}
        onCancel={() => setDeleteDeviceTarget(null)}
      />

      {/* Transfer Ownership Modal */}
      <ConfirmModal
        isOpen={Boolean(transferTarget)}
        title="تحذير: نقل ملكية المنشأة"
        message={`هل تريد حقاً نقل ملكية المجموعة إلى الجهاز "${transferTarget?.name}"؟ سيصبح هو المالك الرئيسي للمنشأة وستفقد صلاحيات المالك الحصري.`}
        confirmLabel="تأكيد نقل الملكية"
        cancelLabel="تراجع"
        variant="warning"
        isLoading={isLoading}
        onConfirm={handleConfirmTransfer}
        onCancel={() => setTransferTarget(null)}
      />
    </div>
  );
};
