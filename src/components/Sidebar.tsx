import React from 'react';
import {
  LayoutDashboard,
  ShoppingCart,
  Users,
  CreditCard,
  Receipt,
  Package,
  BarChart3,
  Network,
  Smartphone,
  UserCheck,
  Bell,
  Settings,
  Database,
  LogOut,
  ShieldCheck,
} from 'lucide-react';

interface SidebarProps {
  currentScreen: string;
  onSelectScreen: (screen: string) => void;
  accountsCount: number;
  devicesCount: number;
  pendingJoinsCount: number;
  userEmail: string;
  onLogout: () => void;
}

export const Sidebar: React.FC<SidebarProps> = ({
  currentScreen,
  onSelectScreen,
  accountsCount,
  devicesCount,
  pendingJoinsCount,
  userEmail,
  onLogout,
}) => {
  const navSections = [
    {
      title: 'الرئيسية',
      items: [
        { id: 'dashboard', label: 'لوحة التحكم', icon: LayoutDashboard },
        { id: 'pos', label: 'نقطة البيع (POS)', icon: ShoppingCart },
      ],
    },
    {
      title: 'الحسابات والعمليات',
      items: [
        { id: 'accounts', label: 'الحسابات والعملاء', icon: Users, badge: accountsCount },
        { id: 'transactions', label: 'العمليات المالية', icon: CreditCard },
        { id: 'vouchers', label: 'السندات والقيود', icon: Receipt },
      ],
    },
    {
      title: 'المخزون والتقارير',
      items: [
        { id: 'inventory', label: 'المخزون والأصناف', icon: Package },
        { id: 'reports', label: 'التقارير والإحصائيات', icon: BarChart3 },
      ],
    },
    {
      title: 'المجموعة وربط الأعضاء',
      items: [
        { id: 'group', label: 'إدارة المجموعة', icon: Network, highlight: 'سحابي' },
        { id: 'devices', label: 'الأجهزة المرتبطة', icon: Smartphone, badge: devicesCount },
        { id: 'users', label: 'المستخدمون والصلاحيات', icon: UserCheck },
        { id: 'joinRequests', label: 'طلبات الانضمام', icon: Bell, badge: pendingJoinsCount, alert: pendingJoinsCount > 0 },
      ],
    },
    {
      title: 'النظام',
      items: [
        { id: 'settings', label: 'إعدادات المنشأة', icon: Settings },
        { id: 'backup', label: 'النسخ الاحتياطي والمزامنة', icon: Database },
      ],
    },
  ];

  return (
    <aside className="w-72 bg-slate-900 text-slate-100 flex flex-col shrink-0 h-screen sticky top-0 border-l border-slate-800 shadow-xl select-none z-20">
      {/* Header / Brand */}
      <div className="p-4 border-b border-slate-800 flex items-center justify-between gap-3">
        <div className="flex items-center gap-3">
          <div className="w-10 h-10 rounded-xl bg-gradient-to-tr from-sky-500 to-indigo-600 flex items-center justify-center text-xl shadow-lg shadow-sky-500/20 text-white font-bold">
            📒
          </div>
          <div>
            <h1 className="font-extrabold text-sm leading-tight text-white">سجل المبيعات والديون</h1>
            <p className="text-xs text-sky-400 font-medium truncate max-w-[130px]" title={userEmail}>
              {userEmail || 'Nexora Ledger'}
            </p>
          </div>
        </div>
        <button
          onClick={onLogout}
          className="p-1.5 rounded-lg text-slate-400 hover:text-rose-400 hover:bg-slate-800/80 transition-colors"
          title="تسجيل الخروج"
        >
          <LogOut className="w-4 h-4" />
        </button>
      </div>

      {/* Navigation list */}
      <div className="flex-1 overflow-y-auto px-3 py-3 space-y-4">
        {navSections.map((section, idx) => (
          <div key={idx}>
            <div className="text-[11px] font-bold text-slate-400 uppercase tracking-wider px-3 mb-1.5">
              {section.title}
            </div>
            <div className="space-y-0.5">
              {section.items.map((item) => {
                const Icon = item.icon;
                const active = currentScreen === item.id;
                return (
                  <button
                    key={item.id}
                    id={`nav-${item.id}`}
                    onClick={() => onSelectScreen(item.id)}
                    className={`w-full flex items-center gap-3 px-3 py-2 rounded-xl text-xs font-semibold transition-all duration-150 text-right ${
                      active
                        ? 'bg-sky-500 text-white shadow-md shadow-sky-500/25 font-bold'
                        : 'text-slate-300 hover:text-white hover:bg-slate-800/70'
                    }`}
                  >
                    <Icon className={`w-4 h-4 shrink-0 ${active ? 'text-white' : 'text-slate-400'}`} />
                    <span className="flex-1 truncate">{item.label}</span>
                    {item.highlight && (
                      <span className="text-[10px] px-2 py-0.5 rounded-full font-bold bg-amber-500/20 text-amber-300 border border-amber-500/30">
                        {item.highlight}
                      </span>
                    )}
                    {typeof item.badge === 'number' && item.badge > 0 && (
                      <span
                        className={`text-[10px] px-2 py-0.5 rounded-full font-bold ${
                          item.alert
                            ? 'bg-rose-500 text-white animate-pulse'
                            : active
                            ? 'bg-sky-700 text-white'
                            : 'bg-slate-800 text-slate-300'
                        }`}
                      >
                        {item.badge}
                      </span>
                    )}
                  </button>
                );
              })}
            </div>
          </div>
        ))}
      </div>

      {/* Footer / Connection State */}
      <div className="p-3 bg-slate-950/60 border-t border-slate-800/80 text-[11px] space-y-1.5 text-slate-400">
        <div className="flex items-center justify-between">
          <span className="flex items-center gap-1.5">
            <span className="w-2 h-2 rounded-full bg-emerald-400 animate-ping inline-block" />
            <span className="text-emerald-400 font-medium">متصل • SQLite محلي</span>
          </span>
          <span className="text-slate-400 font-mono text-[10px]">v3.65.0</span>
        </div>
        <div className="flex items-center gap-1.5 text-slate-400 text-[10px]">
          <ShieldCheck className="w-3.5 h-3.5 text-sky-400" />
          <span>مزامنة سحابية + أمان الأجهزة</span>
        </div>
      </div>
    </aside>
  );
};
