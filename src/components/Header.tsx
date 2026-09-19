import React from 'react';
import { Plus, RefreshCw, UserPlus, HelpCircle } from 'lucide-react';

interface HeaderProps {
  title: string;
  onRefresh: () => void;
  onOpenTxModal: () => void;
  onOpenAccountModal: () => void;
  onOpenHelpGuide?: () => void;
  isLoading?: boolean;
  isSseConnected?: boolean;
}

export const Header: React.FC<HeaderProps> = ({
  title,
  onRefresh,
  onOpenTxModal,
  onOpenAccountModal,
  onOpenHelpGuide,
  isLoading,
  isSseConnected = true,
}) => {
  return (
    <header className="h-16 bg-white border-b border-slate-200 px-6 flex items-center justify-between sticky top-0 z-10 shadow-xs">
      <div>
        <h2 className="text-lg font-black text-slate-800 tracking-tight">{title}</h2>
        <div className="flex items-center gap-2 mt-0.5">
          <p className="text-xs text-slate-600 font-medium">سجل المبيعات والديون • نظام المزامنة الفورية</p>
          <span className="inline-block w-1 h-1 rounded-full bg-slate-300"></span>
          <span className={`inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-[10px] font-bold ${
            isSseConnected ? 'bg-emerald-50 text-emerald-700 border border-emerald-200' : 'bg-amber-50 text-amber-700 border border-amber-200'
          }`}>
            <span className={`w-1.5 h-1.5 rounded-full ${isSseConnected ? 'bg-emerald-500 animate-pulse' : 'bg-amber-500'}`}></span>
            <span>{isSseConnected ? 'المزامنة الفورية نشطة (SSE)' : 'المزامنة متوقفة'}</span>
          </span>
        </div>
      </div>

      <div className="flex items-center gap-2.5">
        {onOpenHelpGuide && (
          <button
            id="btn-header-help-guide"
            onClick={onOpenHelpGuide}
            className="flex items-center gap-1.5 px-3 py-2 text-xs font-bold text-sky-700 bg-sky-50 hover:bg-sky-100 rounded-xl transition-colors border border-sky-100"
            title="دليل الاستخدام والترحيب"
          >
            <HelpCircle className="w-4 h-4 text-sky-600" />
            <span className="hidden sm:inline">دليل الاستخدام</span>
          </button>
        )}

        <button
          id="btn-header-refresh"
          onClick={onRefresh}
          disabled={isLoading}
          className="p-2 text-slate-600 hover:text-slate-900 bg-slate-100 hover:bg-slate-200 rounded-xl transition-all"
          title="تحديث البيانات"
        >
          <RefreshCw className={`w-4 h-4 ${isLoading ? 'animate-spin text-sky-600' : ''}`} />
        </button>

        <button
          id="btn-header-add-account"
          onClick={onOpenAccountModal}
          className="flex items-center gap-1.5 px-3 py-2 text-xs font-bold text-slate-700 bg-slate-100 hover:bg-slate-200 rounded-xl transition-colors"
        >
          <UserPlus className="w-4 h-4 text-slate-500" />
          <span>حساب جديد</span>
        </button>

        <button
          id="btn-header-add-tx"
          onClick={onOpenTxModal}
          className="flex items-center gap-1.5 px-4 py-2 text-xs font-bold text-white bg-sky-600 hover:bg-sky-700 active:scale-98 rounded-xl shadow-sm shadow-sky-600/30 transition-all"
        >
          <Plus className="w-4 h-4" />
          <span>عملية جديدة</span>
        </button>
      </div>
    </header>
  );
};
