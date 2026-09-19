import { Account, Transaction, Item, Voucher, User, Device, JoinRequest, Invite, DashboardData, ActivityItem } from './types';

const BASE_URL = '/api';

async function request<T>(endpoint: string, options?: RequestInit): Promise<T> {
  const res = await fetch(`${BASE_URL}${endpoint}`, {
    ...options,
    headers: {
      'Content-Type': 'application/json',
      ...(options?.headers || {}),
    },
  });

  if (!res.ok) {
    let errorMsg = res.statusText;
    try {
      const data = await res.json();
      if (data.error) errorMsg = data.error;
    } catch {
      // ignore
    }
    throw new Error(errorMsg);
  }

  return res.json();
}

export const api = {
  // Auth
  getGoogleStatus: () => request<{ loggedIn: boolean; email?: string; name?: string; picture?: string }>('/auth/google/status'),
  loginGoogle: (data: { email: string; name?: string; picture?: string; id_token?: string; access_token?: string }) =>
    request<{ ok: boolean; email: string; name: string }>('/auth/google/login', { method: 'POST', body: JSON.stringify(data) }),
  logoutGoogle: () => request<{ ok: boolean }>('/auth/google/logout', { method: 'POST' }),

  // Dashboard
  getDashboard: () => request<DashboardData>('/dashboard'),

  // Accounts
  getAccounts: (kind?: string, search?: string) => {
    const params = new URLSearchParams();
    if (kind) params.set('kind', kind);
    if (search) params.set('search', search);
    return request<Account[]>(`/accounts?${params.toString()}`);
  },
  createAccount: (account: Partial<Account>) => request<{ id: number }>('/accounts', { method: 'POST', body: JSON.stringify(account) }),
  updateAccount: (id: number, account: Partial<Account>) => request<{ ok: boolean }>(`/accounts/${id}`, { method: 'PUT', body: JSON.stringify(account) }),
  deleteAccount: (id: number) => request<{ ok: boolean }>(`/accounts/${id}`, { method: 'DELETE' }),

  // Transactions
  getTransactions: (type?: string, account_id?: number) => {
    const params = new URLSearchParams();
    if (type) params.set('type', type);
    if (account_id) params.set('account_id', String(account_id));
    return request<Transaction[]>(`/transactions?${params.toString()}`);
  },
  createTransaction: (tx: Partial<Transaction> & { items?: any[] }) => request<{ id: number }>('/transactions', { method: 'POST', body: JSON.stringify(tx) }),
  deleteTransaction: (id: number) => request<{ ok: boolean }>(`/transactions/${id}`, { method: 'DELETE' }),

  // Items / Inventory
  getItems: () => request<Item[]>('/items'),
  createItem: (item: Partial<Item>) => request<{ id: number }>('/items', { method: 'POST', body: JSON.stringify(item) }),
  updateItem: (id: number, item: Partial<Item>) => request<{ ok: boolean }>(`/items/${id}`, { method: 'PUT', body: JSON.stringify(item) }),
  deleteItem: (id: number) => request<{ ok: boolean }>(`/items/${id}`, { method: 'DELETE' }),

  // Vouchers
  getVouchers: () => request<Voucher[]>('/vouchers'),
  createVoucher: (voucher: Partial<Voucher>) => request<{ id: number }>('/vouchers', { method: 'POST', body: JSON.stringify(voucher) }),

  // Users
  getUsers: () => request<User[]>('/users'),
  createUser: (user: Partial<User>) => request<{ id: number }>('/users', { method: 'POST', body: JSON.stringify(user) }),
  updateUser: (id: number, user: Partial<User>) => request<{ ok: boolean }>(`/users/${id}`, { method: 'PUT', body: JSON.stringify(user) }),
  deleteUser: (id: number) => request<{ ok: boolean }>(`/users/${id}`, { method: 'DELETE' }),

  // Devices
  getDevices: () => request<Device[]>('/devices'),
  createDevice: (device: Partial<Device>) => request<{ id: string }>('/devices', { method: 'POST', body: JSON.stringify(device) }),
  updateDevice: (id: string, updates: Partial<Device>) => request<{ ok: boolean }>(`/devices/${id}`, { method: 'PUT', body: JSON.stringify(updates) }),
  deleteDevice: (id: string) => request<{ ok: boolean }>(`/devices/${id}`, { method: 'DELETE' }),
  transferOwnership: (id: string) => request<{ ok: boolean }>(`/devices/${id}/transfer-ownership`, { method: 'POST' }),

  // Invites & Join Requests
  createInvite: () => request<Invite>('/invite', { method: 'POST' }),
  getInvites: () => request<Invite[]>('/invites'),
  requestJoin: (data: { deviceName: string; platform: string; fingerprint?: string; token?: string; pin?: string }) =>
    request<{ ok: boolean; requestId: string; deviceId: string; message: string }>('/join-request', { method: 'POST', body: JSON.stringify(data) }),
  getJoinRequests: () => request<JoinRequest[]>('/join-requests'),
  approveJoinRequest: (id: string, role: string) => request<{ ok: boolean; message: string; deviceId: string; deviceName: string }>(`/join-requests/${id}/approve`, { method: 'POST', body: JSON.stringify({ role }) }),
  rejectJoinRequest: (id: string) => request<{ ok: boolean }>(`/join-requests/${id}/reject`, { method: 'POST' }),

  // Settings
  getSettings: () => request<Record<string, string>>('/settings'),
  saveSettings: (settings: Record<string, string>) => request<{ ok: boolean }>('/settings', { method: 'POST', body: JSON.stringify(settings) }),

  // Activity & Backup
  getActivity: () => request<ActivityItem[]>('/activity'),
  getBackup: () => request<any>('/backup/export'),
  restoreBackup: (backup: any) => request<{ ok: boolean; message: string }>('/backup/restore', { method: 'POST', body: JSON.stringify(backup) }),

  // Sync Engine & Snapshot
  getSnapshot: () => request<{ ok: boolean; timestamp: string; snapshot: any }>('/sync/snapshot'),
  pushSync: (operations: any[]) => request<{ ok: boolean; results: any[] }>('/sync/push', { method: 'POST', body: JSON.stringify({ operations }) }),
};
