import React from 'react';
import {
  TrendingUp,
  ArrowDownLeft,
  Users,
  AlertTriangle,
  ArrowUpRight,
  UserCheck,
  CheckCircle2,
  Clock,
  Phone,
  MessageCircle,
} from 'lucide-react';
import { DashboardData, Transaction } from '../types';

interface DashboardViewProps {
  data: DashboardData | null;
  onSelectAccount: (accountId: number) => void;
  onOpenTxModal: () => void;
  onOpenInviteModal: () => void;
  onGoToJoinRequests: () => void;
}

export const DashboardView: React.FC<DashboardViewProps> = ({
  data,
  onSelectAccount,
  onOpenTxModal,
  onOpenInviteModal,
  onGoToJoinRequests,
}) => {
  const formatMoney = (num: number, cur = 'ر.ي') => {
    return `${new Intl.NumberFormat('ar-YE').format(Math.round(num || 0))} ${cur}`;
  };

  const getTxTypeLabel = (type: string) => {
    switch (type) {
      case 'debit':
        return { text: 'عليه (مدين)', color: 'text-rose-600 bg-rose-50 border-rose-200' };
      case 'credit':
        return { text: 'له (دائن)', color: 'text-emerald-600 bg-emerald-50 border-emerald-200' };
      case 'inflow':
        return { text: 'سند قبض', color: 'text-sky-600 bg-sky-50 border-sky-200' };
      case 'outflow':
        return { text: 'سند صرف', color: 'text-amber-600 bg-amber-50 border-amber-200' };
      case 'revenue':
        return { text: 'إيراد', color: 'text-emerald-700 bg-emerald-100 border-emerald-300' };
      case 'expense':
        return { text: 'مصروف', color: 'text-orange-600 bg-orange-50 border-orange-200' };
      default:
        return { text: type, color: 'text-slate-600 bg-slate-100 border-slate-200' };
    }
  };

  return (
    <div className="space-y-6">
      {/* Alert Banner matching Flutter logic */}
      <div className="bg-sky-50 border border-sky-200/80 rounded-2xl p-4 flex items-start gap-3.5 shadow-xs">
        <div className="p-2 rounded-xl bg-sky-100 text-sky-600 shrink-0 mt-0.5">
          <CheckCircle2 className="w-5 h-5" />
        </div>
        <div className="flex-1">
          <h4 className="text-xs font-bold text-sky-950">نظام محاسبي متكامل مع ربط أجهزة سحابي ومحلي</h4>
          <p className="text-xs text-sky-800 leading-relaxed mt-0.5">
            يعمل التطبيق بقاعدة بيانات SQLite حقيقية، ويدعم تسجيل دخول Google، ومزامنة الدعوات عبر QR Code ورمز PIN صالح 15 دقيقة مع موافقة مسبقة للمدير كما في تطبيق Flutter الأصلي.
          </p>
        </div>
        <button
          onClick={onOpenInviteModal}
          className="shrink-0 px-3 py-1.5 text-xs font-bold bg-sky-600 hover:bg-sky-700 text-white rounded-xl shadow-xs transition-colors"
        >
          دعوة جهاز جديد
        </button>
      </div>

      {/* Stats Cards */}
      <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
        {/* Total Sales */}
        <div className="bg-white rounded-2xl p-4 border border-slate-200 shadow-xs relative overflow-hidden group">
          <div className="absolute top-0 right-0 left-0 h-1 bg-sky-500" />
          <div className="flex items-start justify-between">
            <div>
              <span className="text-xs font-semibold text-slate-500">إجمالي المبيعات</span>
              <div className="text-xl font-black text-slate-900 mt-1 font-mono">
                {formatMoney(data?.totalSales || 0)}
              </div>
            </div>
            <div className="w-10 h-10 rounded-xl bg-sky-50 text-sky-600 flex items-center justify-center">
              <TrendingUp className="w-5 h-5" />
            </div>
          </div>
          <div className="mt-3 text-[11px] text-slate-400 flex items-center gap-1">
            <span>من كافة الفواتير والعمليات</span>
          </div>
        </div>

        {/* Total Debts */}
        <div className="bg-white rounded-2xl p-4 border border-slate-200 shadow-xs relative overflow-hidden group">
          <div className="absolute top-0 right-0 left-0 h-1 bg-emerald-500" />
          <div className="flex items-start justify-between">
            <div>
              <span className="text-xs font-semibold text-slate-500">الذمم المدينة (مستحق لنا)</span>
              <div className="text-xl font-black text-emerald-600 mt-1 font-mono">
                {formatMoney(data?.totalDebts || 0)}
              </div>
            </div>
            <div className="w-10 h-10 rounded-xl bg-emerald-50 text-emerald-600 flex items-center justify-center">
              <ArrowDownLeft className="w-5 h-5" />
            </div>
          </div>
          <div className="mt-3 text-[11px] text-slate-400 flex items-center gap-1">
            <span>ديون العملاء الإجمالية</span>
          </div>
        </div>

        {/* Pending Joins */}
        <div
          onClick={onGoToJoinRequests}
          className={`bg-white rounded-2xl p-4 border border-slate-200 shadow-xs relative overflow-hidden cursor-pointer transition-all hover:border-amber-300 ${
            (data?.pendingJoins || 0) > 0 ? 'ring-2 ring-amber-400/40 bg-amber-50/20' : ''
          }`}
        >
          <div className="absolute top-0 right-0 left-0 h-1 bg-amber-500" />
          <div className="flex items-start justify-between">
            <div>
              <span className="text-xs font-semibold text-slate-500">طلبات انضمام الأجهزة</span>
              <div className="text-xl font-black text-slate-900 mt-1 font-mono">
                {data?.pendingJoins || 0} طلب
              </div>
            </div>
            <div className="w-10 h-10 rounded-xl bg-amber-50 text-amber-600 flex items-center justify-center">
              <UserCheck className="w-5 h-5" />
            </div>
          </div>
          <div className="mt-3 text-[11px] text-amber-600 font-bold flex items-center gap-1">
            {(data?.pendingJoins || 0) > 0 ? '⚠️ يتطلب موافقة المدير' : 'لا توجد طلبات معلقة'}
          </div>
        </div>

        {/* Low Stock Alerts */}
        <div className="bg-white rounded-2xl p-4 border border-slate-200 shadow-xs relative overflow-hidden">
          <div className="absolute top-0 right-0 left-0 h-1 bg-rose-500" />
          <div className="flex items-start justify-between">
            <div>
              <span className="text-xs font-semibold text-slate-500">تنبيهات نقص المخزون</span>
              <div className="text-xl font-black text-rose-600 mt-1 font-mono">
                {data?.lowStock || 0} صنف
              </div>
            </div>
            <div className="w-10 h-10 rounded-xl bg-rose-50 text-rose-600 flex items-center justify-center">
              <AlertTriangle className="w-5 h-5" />
            </div>
          </div>
          <div className="mt-3 text-[11px] text-slate-400 flex items-center gap-1">
            <span>أصناف بلغت حد الطلب الأدنى</span>
          </div>
        </div>
      </div>

      {/* Grid: Top Debtors + Recent Transactions */}
      <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
        {/* Top Debtors */}
        <div className="bg-white rounded-2xl border border-slate-200 shadow-xs overflow-hidden">
          <div className="p-4 border-b border-slate-100 flex items-center justify-between">
            <div className="flex items-center gap-2">
              <Users className="w-4 h-4 text-sky-600" />
              <h3 className="text-sm font-black text-slate-800">أكثر العملاء مديونية</h3>
            </div>
            <span className="text-[11px] font-bold text-slate-400">أعلى 5 ديون</span>
          </div>

          <div className="divide-y divide-slate-100">
            {(!data?.topDebtors || data.topDebtors.length === 0) ? (
              <div className="p-8 text-center text-slate-400 text-xs">
                لا توجد ديون مسجلة حالياً
              </div>
            ) : (
              data.topDebtors.map((debtor) => (
                <div
                  key={debtor.id}
                  onClick={() => onSelectAccount(debtor.id)}
                  className="p-3.5 hover:bg-slate-50 flex items-center justify-between gap-3 cursor-pointer transition-colors"
                >
                  <div className="flex items-center gap-3">
                    <div className="w-9 h-9 rounded-xl bg-sky-100 text-sky-700 font-bold text-xs flex items-center justify-center">
                      {debtor.name.slice(0, 1)}
                    </div>
                    <div>
                      <div className="text-xs font-bold text-slate-800">{debtor.name}</div>
                      <div className="text-[11px] text-slate-400 flex items-center gap-2 mt-0.5">
                        {debtor.phone && (
                          <span className="flex items-center gap-1">
                            <Phone className="w-3 h-3 text-slate-400" />
                            <span dir="ltr">{debtor.phone}</span>
                          </span>
                        )}
                      </div>
                    </div>
                  </div>

                  <div className="text-left font-mono">
                    <div className="text-xs font-black text-rose-600">
                      {formatMoney(debtor.balance)}
                    </div>
                    <span className="text-[10px] text-slate-400">مستحق عليه</span>
                  </div>
                </div>
              ))
            )}
          </div>
        </div>

        {/* Recent Transactions */}
        <div className="bg-white rounded-2xl border border-slate-200 shadow-xs overflow-hidden">
          <div className="p-4 border-b border-slate-100 flex items-center justify-between">
            <div className="flex items-center gap-2">
              <Clock className="w-4 h-4 text-sky-600" />
              <h3 className="text-sm font-black text-slate-800">آخر العمليات المسجلة</h3>
            </div>
            <button
              onClick={onOpenTxModal}
              className="text-xs font-bold text-sky-600 hover:text-sky-700"
            >
              + إضافة عملية
            </button>
          </div>

          <div className="divide-y divide-slate-100 max-h-[380px] overflow-y-auto">
            {(!data?.recentTx || data.recentTx.length === 0) ? (
              <div className="p-8 text-center text-slate-400 text-xs">
                لا توجد عمليات مسجلة حتى الآن
              </div>
            ) : (
              data.recentTx.map((tx) => {
                const typeInfo = getTxTypeLabel(tx.type);
                return (
                  <div key={tx.id} className="p-3.5 hover:bg-slate-50 flex items-center justify-between gap-3">
                    <div className="flex items-center gap-3">
                      <div className="w-9 h-9 rounded-xl bg-slate-100 text-slate-700 flex items-center justify-center shrink-0">
                        {tx.type === 'debit' ? (
                          <ArrowDownLeft className="w-4 h-4 text-rose-500" />
                        ) : (
                          <ArrowUpRight className="w-4 h-4 text-emerald-500" />
                        )}
                      </div>
                      <div>
                        <div className="text-xs font-bold text-slate-800">
                          {tx.account_name || 'حساب عام'}
                        </div>
                        <div className="text-[11px] text-slate-400 flex items-center gap-2 mt-0.5">
                          <span>{tx.description || 'عملية مالية'}</span>
                          <span>•</span>
                          <span>{new Date(tx.date).toLocaleDateString('ar-YE')}</span>
                        </div>
                      </div>
                    </div>

                    <div className="text-left font-mono">
                      <div className="text-xs font-black text-slate-900">
                        {formatMoney(tx.amount, tx.currency)}
                      </div>
                      <span className={`text-[10px] px-2 py-0.5 rounded-md font-bold border ${typeInfo.color}`}>
                        {typeInfo.text}
                      </span>
                    </div>
                  </div>
                );
              })
            )}
          </div>
        </div>
      </div>
    </div>
  );
};
