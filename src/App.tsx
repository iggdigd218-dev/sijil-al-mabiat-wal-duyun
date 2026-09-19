import React, { useState, useEffect, useCallback } from 'react';
import { Sidebar } from './components/Sidebar';
import { Header } from './components/Header';
import { DashboardView } from './components/DashboardView';
import { PosView } from './components/PosView';
import { AccountsView } from './components/AccountsView';
import { TransactionsView } from './components/TransactionsView';
import { InventoryView } from './components/InventoryView';
import { VouchersView } from './components/VouchersView';
import { GroupManagementView } from './components/GroupManagementView';
import { DevicesView } from './components/DevicesView';
import { UsersView } from './components/UsersView';
import { ReportsView } from './components/ReportsView';
import { SettingsView } from './components/SettingsView';
import { BackupView } from './components/BackupView';
import { LoginModal } from './components/LoginModal';
import { AccountStatementModal } from './components/AccountStatementModal';
import { WelcomeGuideModal } from './components/WelcomeGuideModal';
import {
  AccountModal,
  TransactionModal,
  ItemModal,
  UserModal,
  VoucherModal,
} from './components/Modals';
import {
  Account,
  Transaction,
  Item,
  Voucher,
  User,
  Device,
  JoinRequest,
  Invite,
  DashboardData,
} from './types';
import { api } from './api';

interface Toast {
  id: string;
  message: string;
  type: 'success' | 'error' | 'info';
}

export function App() {
  const [currentScreen, setCurrentScreen] = useState<string>('dashboard');
  const [isLoading, setIsLoading] = useState(false);
  const [userEmail, setUserEmail] = useState<string>('owner@nexora.local');

  // App Data State
  const [dashboardData, setDashboardData] = useState<DashboardData | null>(null);
  const [accounts, setAccounts] = useState<Account[]>([]);
  const [transactions, setTransactions] = useState<Transaction[]>([]);
  const [items, setItems] = useState<Item[]>([]);
  const [vouchers, setVouchers] = useState<Voucher[]>([]);
  const [users, setUsers] = useState<User[]>([]);
  const [devices, setDevices] = useState<Device[]>([]);
  const [invites, setInvites] = useState<Invite[]>([]);
  const [joinRequests, setJoinRequests] = useState<JoinRequest[]>([]);

  // Modals
  const [isAccountModalOpen, setIsAccountModalOpen] = useState(false);
  const [editingAccount, setEditingAccount] = useState<Account | null>(null);

  const [isTxModalOpen, setIsTxModalOpen] = useState(false);
  const [txInitialAccountId, setTxInitialAccountId] = useState<number | undefined>(undefined);

  const [isItemModalOpen, setIsItemModalOpen] = useState(false);
  const [editingItem, setEditingItem] = useState<Item | null>(null);

  const [isUserModalOpen, setIsUserModalOpen] = useState(false);
  const [editingUser, setEditingUser] = useState<User | null>(null);

  const [isVoucherModalOpen, setIsVoucherModalOpen] = useState(false);
  const [isLoginModalOpen, setIsLoginModalOpen] = useState(false);
  const [statementAccount, setStatementAccount] = useState<Account | null>(null);
  const [isWelcomeGuideOpen, setIsWelcomeGuideOpen] = useState(false);

  // Toasts
  const [toasts, setToasts] = useState<Toast[]>([]);

  const showToast = useCallback((message: string, type: 'success' | 'error' | 'info' = 'info') => {
    const id = Date.now().toString();
    setToasts((prev) => [...prev, { id, message, type }]);
    setTimeout(() => {
      setToasts((prev) => prev.filter((t) => t.id !== id));
    }, 3500);
  }, []);

  const loadAllData = useCallback(async () => {
    setIsLoading(true);
    try {
      const [
        dash,
        accs,
        txs,
        its,
        vchs,
        usrs,
        devs,
        invs,
        joins,
        authStatus,
      ] = await Promise.all([
        api.getDashboard().catch(() => null),
        api.getAccounts().catch(() => []),
        api.getTransactions().catch(() => []),
        api.getItems().catch(() => []),
        api.getVouchers().catch(() => []),
        api.getUsers().catch(() => []),
        api.getDevices().catch(() => []),
        api.getInvites().catch(() => []),
        api.getJoinRequests().catch(() => []),
        api.getGoogleStatus().catch(() => ({ loggedIn: false })),
      ]);

      if (dash) setDashboardData(dash);
      setAccounts(accs);
      setTransactions(txs);
      setItems(its);
      setVouchers(vchs);
      setUsers(usrs);
      setDevices(devs);
      setInvites(invs);
      setJoinRequests(joins);
      if (authStatus.loggedIn && (authStatus as any).email) {
        setUserEmail((authStatus as any).email);
      }
    } catch (err: any) {
      console.error('Error fetching data:', err);
    } finally {
      setIsLoading(false);
    }
  }, []);

  const [isSseConnected, setIsSseConnected] = useState(false);

  useEffect(() => {
    loadAllData();
  }, [loadAllData]);

  // Real-time SSE listener for instant manager-member sync
  useEffect(() => {
    let es: EventSource | null = null;
    try {
      es = new EventSource('/api/sync/events');
      es.addEventListener('connected', () => {
        setIsSseConnected(true);
      });
      es.addEventListener('sync', (e: MessageEvent) => {
        setIsSseConnected(true);
        try {
          const payload = JSON.parse(e.data);
          loadAllData();
          if (payload.type === 'join_requested') {
            showToast(`📲 جهاز جديد يطلب الانضمام: ${payload.deviceName || 'جهاز'}`, 'info');
          } else if (payload.type === 'join_approved') {
            showToast(`✅ تم اعتماد جهاز: ${payload.deviceName} بدور ${payload.role}`, 'success');
          } else if (payload.type === 'account_created') {
            showToast(`👤 مزامنة الحسابات: تم إضافة حساب "${payload.name}" فورياً`, 'info');
          } else if (payload.type === 'account_updated') {
            showToast(`✏️ مزامنة الحسابات: تم تحديث بيانات الحساب "${payload.name}"`, 'info');
          } else if (payload.type === 'account_deleted') {
            showToast(`🗑️ مزامنة الحسابات: تم حذف حساب بواسطة جهاز مرتبط`, 'info');
          } else if (payload.type === 'voucher_created') {
            showToast(`🧾 مزامنة فورية: تم إصدار سند ${payload.kind === 'receipt' ? 'قبض' : 'صرف'} بقيمة ${Number(payload.amount || 0).toLocaleString()} ر.ي`, 'info');
          } else if (payload.type === 'transaction_created') {
            showToast(`⚡ مزامنة فورية: تم تسجيل عملية بقيمة ${Number(payload.amount || 0).toLocaleString()} ر.ي`, 'info');
          } else if (payload.type === 'batch_sync_applied') {
            showToast(`🔄 اكتملت مزامنة ${payload.count} عمليات من الأجهزة المرتبطة`, 'success');
          } else if (payload.type === 'auth_updated') {
            showToast(`🔒 تم تحديث حالة الحساب السحابي المرتبط`, 'info');
          }
        } catch {
          loadAllData();
        }
      });
      es.onerror = () => {
        setIsSseConnected(false);
      };
    } catch {
      setIsSseConnected(false);
    }
    return () => {
      es?.close();
    };
  }, [loadAllData, showToast]);

  const handleLogout = async () => {
    await api.logoutGoogle();
    setUserEmail('guest@local');
    setIsLoginModalOpen(true);
  };

  const getScreenTitle = () => {
    switch (currentScreen) {
      case 'dashboard':
        return 'لوحة التحكم والمؤشرات المالية';
      case 'pos':
        return 'نقطة البيع وإصدار الفواتير (POS)';
      case 'accounts':
        return 'إدارة الحسابات والعملاء والموردين';
      case 'transactions':
        return 'سجل العمليات المالية والقيود';
      case 'vouchers':
        return 'السندات والقيود المحاسبية';
      case 'inventory':
        return 'المخزون وإدارة الأصناف';
      case 'reports':
        return 'التقارير المالية والتحليلية';
      case 'group':
        return 'إدارة المجموعة وربط الأجهزة';
      case 'devices':
        return 'الأجهزة المرتبطة وصلاحيات الوصول';
      case 'users':
        return 'المستخدمون ورموز الدخول';
      case 'joinRequests':
        return 'طلبات الانضمام المعلقة';
      case 'settings':
        return 'إعدادات المنشأة والترويسة';
      case 'backup':
        return 'النسخ الاحتياطي ومراجعة الأنشطة';
      default:
        return 'سجل المبيعات والديون';
    }
  };

  return (
    <div className="min-h-screen bg-slate-100 flex flex-row">
      {/* Toast Notifications */}
      <div className="fixed bottom-4 left-4 z-50 space-y-2 max-w-sm pointer-events-none">
        {toasts.map((toast) => (
          <div
            key={toast.id}
            className={`pointer-events-auto px-4 py-3 rounded-2xl shadow-xl border text-xs font-bold transition-all duration-300 transform translate-y-0 ${
              toast.type === 'success'
                ? 'bg-emerald-800 text-white border-emerald-700'
                : toast.type === 'error'
                ? 'bg-rose-800 text-white border-rose-700'
                : 'bg-slate-900 text-white border-slate-800'
            }`}
          >
            {toast.message}
          </div>
        ))}
      </div>

      {/* Main Sidebar */}
      <Sidebar
        currentScreen={currentScreen}
        onSelectScreen={setCurrentScreen}
        accountsCount={accounts.length}
        devicesCount={devices.length}
        pendingJoinsCount={joinRequests.filter((r) => r.status === 'pending').length}
        userEmail={userEmail}
        onLogout={handleLogout}
      />

      {/* Content Area */}
      <div className="flex-1 flex flex-col min-w-0 h-screen overflow-y-auto">
        <Header
          title={getScreenTitle()}
          onRefresh={loadAllData}
          onOpenTxModal={() => {
            setTxInitialAccountId(undefined);
            setIsTxModalOpen(true);
          }}
          onOpenAccountModal={() => {
            setEditingAccount(null);
            setIsAccountModalOpen(true);
          }}
          onOpenHelpGuide={() => setIsWelcomeGuideOpen(true)}
          isLoading={isLoading}
          isSseConnected={isSseConnected}
        />

        <main className="p-6 flex-1 max-w-7xl w-full mx-auto">
          {currentScreen === 'dashboard' && (
            <DashboardView
              data={dashboardData}
              onSelectAccount={(accId) => {
                setCurrentScreen('accounts');
              }}
              onOpenTxModal={() => {
                setTxInitialAccountId(undefined);
                setIsTxModalOpen(true);
              }}
              onOpenInviteModal={() => setCurrentScreen('group')}
              onGoToJoinRequests={() => setCurrentScreen('group')}
            />
          )}

          {currentScreen === 'pos' && (
            <PosView
              items={items}
              accounts={accounts}
              onRefreshItems={loadAllData}
              onShowToast={showToast}
            />
          )}

          {currentScreen === 'accounts' && (
            <AccountsView
              accounts={accounts}
              onRefresh={loadAllData}
              onOpenAccountModal={(acc) => {
                setEditingAccount(acc || null);
                setIsAccountModalOpen(true);
              }}
              onOpenTxModal={(accId) => {
                setTxInitialAccountId(accId);
                setIsTxModalOpen(true);
              }}
              onOpenStatement={(acc) => {
                setStatementAccount(acc);
              }}
              onShowToast={showToast}
            />
          )}

          {currentScreen === 'transactions' && (
            <TransactionsView
              transactions={transactions}
              accounts={accounts}
              onRefresh={loadAllData}
              onOpenTxModal={() => {
                setTxInitialAccountId(undefined);
                setIsTxModalOpen(true);
              }}
              onShowToast={showToast}
            />
          )}

          {currentScreen === 'vouchers' && (
            <VouchersView
              vouchers={vouchers}
              accounts={accounts}
              onRefresh={loadAllData}
              onOpenVoucherModal={() => setIsVoucherModalOpen(true)}
              onShowToast={showToast}
            />
          )}

          {currentScreen === 'inventory' && (
            <InventoryView
              items={items}
              onRefresh={loadAllData}
              onOpenItemModal={(item) => {
                setEditingItem(item || null);
                setIsItemModalOpen(true);
              }}
              onShowToast={showToast}
            />
          )}

          {currentScreen === 'reports' && (
            <ReportsView
              dashboard={dashboardData}
              accounts={accounts}
              items={items}
              transactions={transactions}
            />
          )}

          {currentScreen === 'group' && (
            <GroupManagementView
              invites={invites}
              joinRequests={joinRequests}
              devices={devices}
              onRefresh={loadAllData}
              onShowToast={showToast}
            />
          )}

          {currentScreen === 'devices' && (
            <DevicesView
              devices={devices}
              onRefresh={loadAllData}
              onShowToast={showToast}
            />
          )}

          {currentScreen === 'users' && (
            <UsersView
              users={users}
              onRefresh={loadAllData}
              onOpenUserModal={(usr) => {
                setEditingUser(usr || null);
                setIsUserModalOpen(true);
              }}
              onShowToast={showToast}
            />
          )}

          {currentScreen === 'joinRequests' && (
            <GroupManagementView
              invites={invites}
              joinRequests={joinRequests}
              devices={devices}
              onRefresh={loadAllData}
              onShowToast={showToast}
            />
          )}

          {currentScreen === 'settings' && (
            <SettingsView onShowToast={showToast} />
          )}

          {currentScreen === 'backup' && (
            <BackupView onShowToast={showToast} />
          )}
        </main>
      </div>

      {/* Modals */}
      <AccountModal
        isOpen={isAccountModalOpen}
        account={editingAccount}
        onClose={() => setIsAccountModalOpen(false)}
        onSuccess={loadAllData}
        onShowToast={showToast}
      />

      <TransactionModal
        isOpen={isTxModalOpen}
        accounts={accounts}
        initialAccountId={txInitialAccountId}
        onClose={() => setIsTxModalOpen(false)}
        onSuccess={loadAllData}
        onShowToast={showToast}
      />

      <ItemModal
        isOpen={isItemModalOpen}
        item={editingItem}
        onClose={() => setIsItemModalOpen(false)}
        onSuccess={loadAllData}
        onShowToast={showToast}
      />

      <UserModal
        isOpen={isUserModalOpen}
        user={editingUser}
        onClose={() => setIsUserModalOpen(false)}
        onSuccess={loadAllData}
        onShowToast={showToast}
      />

      <VoucherModal
        isOpen={isVoucherModalOpen}
        accounts={accounts}
        onClose={() => setIsVoucherModalOpen(false)}
        onSuccess={loadAllData}
        onShowToast={showToast}
      />

      <LoginModal
        isOpen={isLoginModalOpen}
        onSuccess={(email, name) => {
          setUserEmail(email);
          loadAllData();
        }}
        onClose={() => setIsLoginModalOpen(false)}
        onShowToast={showToast}
      />

      <AccountStatementModal
        isOpen={Boolean(statementAccount)}
        account={statementAccount}
        transactions={transactions}
        onClose={() => setStatementAccount(null)}
        onShowToast={showToast}
      />

      <WelcomeGuideModal
        isOpen={isWelcomeGuideOpen}
        onClose={() => setIsWelcomeGuideOpen(false)}
        onNavigate={(screen) => setCurrentScreen(screen)}
      />
    </div>
  );
}
