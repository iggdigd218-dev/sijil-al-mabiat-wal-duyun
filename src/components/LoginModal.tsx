import React, { useState } from 'react';
import { Shield, Mail, Lock, Store, LogIn, UserPlus, KeyRound } from 'lucide-react';
import { api } from '../api';
import { setAuthSession, getDeviceId, getAuthSession } from '../services/syncQueueService';
import { AuthSession } from '../types';

interface LoginModalProps {
  isOpen: boolean;
  onSuccess: (session: AuthSession) => void;
  onClose: () => void;
  onShowToast: (msg: string, type?: 'success' | 'error' | 'info') => void;
}

export const LoginModal: React.FC<LoginModalProps> = ({
  isOpen,
  onSuccess,
  onClose,
  onShowToast,
}) => {
  const currentSession = getAuthSession();
  const [isRegisterMode, setIsRegisterMode] = useState(false);
  const [name, setName] = useState('');
  const [email, setEmail] = useState(currentSession?.user_email || '');
  const [password, setPassword] = useState('admin123');
  const [storeId, setStoreId] = useState(currentSession?.store_id || 'store-main');
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  if (!isOpen) return null;

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setError(null);
    setLoading(true);

    try {
      const deviceId = getDeviceId();
      if (isRegisterMode) {
        if (!name.trim()) {
          setError('يرجى إدخال اسم المستخدم');
          setLoading(false);
          return;
        }
        const res = await api.register({
          name: name.trim(),
          email: email.trim().toLowerCase(),
          password,
          store_id: storeId.trim() || 'store-main',
        });
        setAuthSession(res.session);
        onShowToast(`تم إنشاء الحساب بنجاح: مرحباً بك ${res.session.user_name}`, 'success');
        onSuccess(res.session);
        onClose();
      } else {
        const res = await api.login({
          email: email.trim().toLowerCase(),
          password,
          store_id: storeId.trim() || 'store-main',
          device_id: deviceId,
        });
        setAuthSession(res.session);
        onShowToast(`تم تسجيل الدخول بنجاح: ${res.session.user_name}`, 'success');
        onSuccess(res.session);
        onClose();
      }
    } catch (err: any) {
      const errMsg = err?.message || 'فشل تسجيل الدخول، تحقق من البيانات';
      setError(errMsg);
      onShowToast(errMsg, 'error');
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="fixed inset-0 bg-slate-900/60 backdrop-blur-xs flex items-center justify-center p-4 z-50 animate-in fade-in">
      <div className="bg-white rounded-3xl p-6 max-w-sm w-full border border-slate-200 shadow-2xl space-y-4">
        <div className="text-center space-y-2">
          <div className="w-12 h-12 rounded-2xl bg-indigo-50 text-indigo-600 flex items-center justify-center mx-auto text-xl font-bold border border-indigo-100">
            <Lock className="w-6 h-6" />
          </div>
          <h3 className="font-extrabold text-base text-slate-900">
            {isRegisterMode ? 'إنشاء حساب مستخدم جديد' : 'تسجيل الدخول بالبريد الإلكتروني'}
          </h3>
          <p className="text-xs text-slate-500">
            المصادقة المحلية بالبريد وكلمة المرور حصراً
          </p>
        </div>

        {error && (
          <div className="p-2.5 rounded-xl bg-rose-50 border border-rose-200 text-rose-700 text-xs font-medium text-center">
            {error}
          </div>
        )}

        <form onSubmit={handleSubmit} className="space-y-3 text-xs">
          {isRegisterMode && (
            <div>
              <label className="font-bold text-slate-700 block mb-1">الاسم الكامل:</label>
              <input
                type="text"
                required
                value={name}
                onChange={(e) => setName(e.target.value)}
                placeholder="أحمد محمد"
                className="w-full px-3 py-2 bg-slate-50 border border-slate-200 rounded-xl focus:bg-white focus:outline-hidden text-slate-900"
              />
            </div>
          )}

          <div>
            <label className="font-bold text-slate-700 block mb-1">البريد الإلكتروني (Email):</label>
            <div className="relative">
              <input
                type="email"
                required
                dir="ltr"
                value={email}
                onChange={(e) => setEmail(e.target.value)}
                placeholder="user@example.com"
                className="w-full px-3 py-2 pl-9 bg-slate-50 border border-slate-200 rounded-xl focus:bg-white focus:outline-hidden text-slate-900 font-mono text-xs"
              />
              <Mail className="w-4 h-4 text-slate-400 absolute left-3 top-2.5 pointer-events-none" />
            </div>
          </div>

          <div>
            <label className="font-bold text-slate-700 block mb-1">كلمة المرور (Password):</label>
            <div className="relative">
              <input
                type="password"
                required
                dir="ltr"
                value={password}
                onChange={(e) => setPassword(e.target.value)}
                placeholder="••••••••"
                className="w-full px-3 py-2 pl-9 bg-slate-50 border border-slate-200 rounded-xl focus:bg-white focus:outline-hidden text-slate-900 font-mono text-xs"
              />
              <KeyRound className="w-4 h-4 text-slate-400 absolute left-3 top-2.5 pointer-events-none" />
            </div>
            <p className="text-[10px] text-slate-400 mt-0.5">كلمة مرور الحساب الافتراضي: admin123</p>
          </div>

          <div>
            <label className="font-bold text-slate-700 block mb-1">معرّف المتجر السحابي (Store ID):</label>
            <div className="relative">
              <input
                type="text"
                dir="ltr"
                value={storeId}
                onChange={(e) => setStoreId(e.target.value)}
                placeholder="store-main"
                className="w-full px-3 py-2 pl-9 bg-slate-50 border border-slate-200 rounded-xl focus:bg-white focus:outline-hidden text-slate-900 font-mono text-xs"
              />
              <Store className="w-4 h-4 text-slate-400 absolute left-3 top-2.5 pointer-events-none" />
            </div>
          </div>

          <div className="pt-2 flex items-center gap-2">
            <button
              type="button"
              onClick={onClose}
              disabled={loading}
              className="w-1/2 py-2.5 px-4 rounded-xl border border-slate-200 hover:bg-slate-50 text-slate-700 font-bold transition-colors"
            >
              إلغاء
            </button>
            <button
              type="submit"
              disabled={loading}
              className="w-1/2 py-2.5 px-4 rounded-xl bg-indigo-600 hover:bg-indigo-700 text-white font-bold shadow-xs transition-colors flex items-center justify-center gap-2 disabled:opacity-50"
            >
              {loading ? (
                <span>جاري المعالجة...</span>
              ) : isRegisterMode ? (
                <>
                  <UserPlus className="w-4 h-4" />
                  <span>تسجيل</span>
                </>
              ) : (
                <>
                  <LogIn className="w-4 h-4" />
                  <span>دخول</span>
                </>
              )}
            </button>
          </div>
        </form>

        <div className="pt-1 text-center">
          <button
            type="button"
            onClick={() => {
              setIsRegisterMode(!isRegisterMode);
              setError(null);
            }}
            className="text-indigo-600 hover:text-indigo-800 text-xs font-bold"
          >
            {isRegisterMode ? 'لديك حساب بالفعل؟ تسجيل الدخول' : 'إنشاء حساب جديد بالبريد الإلكتروني'}
          </button>
        </div>
      </div>
    </div>
  );
};
