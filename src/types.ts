export type AccountKind = 'customer' | 'supplier' | 'cash';

export interface Account {
  id: number;
  name: string;
  kind: AccountKind;
  opening_balance: number;
  currency: string;
  phone?: string;
  whatsapp?: string;
  address?: string;
  notes?: string;
  category?: string;
  credit_limit?: number;
  balance?: number;
  last_tx?: string;
  created_at: string;
  updated_at: string;
}

export type TransactionType = 'debit' | 'credit' | 'inflow' | 'outflow' | 'revenue' | 'expense';

export interface TransactionItem {
  id?: number;
  tx_id?: number;
  name: string;
  quantity: number;
  unit_price: number;
  total: number;
}

export interface Transaction {
  id: number;
  account_id?: number;
  account_name?: string;
  type: TransactionType;
  amount: number;
  currency: string;
  from_id?: number;
  to_id?: number;
  rate?: number;
  description?: string;
  reference?: string;
  notes?: string;
  date: string;
  created_at: string;
  updated_at: string;
  items?: TransactionItem[];
}

export interface Item {
  id: number;
  name: string;
  sku: string;
  buy_price: number;
  sell_price: number;
  quantity: number;
  min_quantity: number;
  category: string;
  created_at: string;
}

export type VoucherKind = 'receipt' | 'payment' | 'debit' | 'credit' | 'transfer';
export type VoucherStatus = 'draft' | 'posted' | 'cancelled';

export interface Voucher {
  id: number;
  number: string;
  kind: VoucherKind;
  account_id?: number;
  account_name?: string;
  amount: number;
  currency: string;
  statement: string;
  notes?: string;
  status: VoucherStatus;
  date: string;
  created_at: string;
  updated_at: string;
}

export type UserRole = 'admin' | 'agent' | 'accountant' | 'dataentry' | 'viewer';

export interface User {
  id: number;
  name: string;
  role: UserRole;
  pin?: string;
  permissions?: string;
  is_me?: number;
  active?: number;
  created_at: string;
}

export interface Device {
  id: string;
  name: string;
  platform: 'web' | 'android' | 'windows' | 'ios' | 'linux';
  is_owner: number;
  user_id?: number;
  user_name?: string;
  user_role?: UserRole;
  last_seen_at?: string;
  last_sync_at?: string;
  revoked_at?: string;
  expelled_at?: string;
  fingerprint?: string;
}

export interface JoinRequest {
  id: string;
  device_id: string;
  device_name: string;
  platform: string;
  fingerprint: string;
  token: string;
  status: 'pending' | 'approved' | 'rejected';
  requested_role?: UserRole;
  created_at: string;
}

export interface Invite {
  id: string;
  token: string;
  pin: string;
  workspace_id: string;
  created_by: string;
  expires_at: string;
  used: number;
  created_at: string;
  pinRaw?: string;
  qrContent?: string;
  backendUrl?: string;
  workspaceName?: string;
}

export interface DashboardData {
  totalSales: number;
  totalDebts: number;
  totalCredits: number;
  accountsCount: number;
  lowStock: number;
  pendingJoins: number;
  topDebtors: Array<{
    id: number;
    name: string;
    phone: string;
    balance: number;
  }>;
  recentTx: Array<Transaction>;
}

export interface ActivityItem {
  id: number;
  text: string;
  ref_type?: string;
  ref_id?: string;
  user_name?: string;
  created_at: string;
}
