import React, { useState } from 'react';
import { Shield, CheckCircle2, User, Key } from 'lucide-react';
import { api } from '../api';

interface LoginModalProps {
  isOpen: boolean;
  onSuccess: (email: string, name: string) => void;
  onClose: () => void;
  onShowToast: (msg: string, type?: 'success' | 'error' | 'info') => void;
}

export const LoginModal: React.FC<LoginModalProps> = ({
  isOpen,
  onSuccess,
  onClose,
  onShowToast,
}) => {
  const [email, setEmail] = useState('manager@nexora.local');
  const [name, setName] = useState('مدير المنشأة الرئيسي');
  const [loading, setLoading] = useState(false);

  if (!isOpen) return null;

  const handleLogin = async (e: React.FormEvent) => {
    e.preventDefault();
    setLoading(true);
    try {
      const res = await api.loginGoogle({
        email: email.trim(),
        name: name.trim(),
        picture: `https://api.dicebear.com/7.x/initials/svg?seed=${encodeURIComponent(name)}`,
      });
      onShowToast(`مرحباً بك، ${res.name}`, 'success');
      onSuccess(res.email, res.name);
      onClose();
    } catch (err: any) {
      onShowToast(err.message || 'فشل تسجيل الدخول', 'error');
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="fixed inset-0 bg-slate-900/60 backdrop-blur-xs flex items-center justify-center p-4 z-50">
      <div className="bg-white rounded-3xl p-6 max-w-sm w-full border border-slate-200 shadow-2xl space-y-4">
        <div className="text-center space-y-2">
          <div className="w-12 h-12 rounded-2xl bg-sky-100 text-sky-600 flex items-center justify-center mx-auto text-xl font-bold">
            📒
          </div>
          <h3 className="font-extrabold text-base text-slate-900">سجل المبيعات والديون</h3>
          <p className="text-xs text-slate-500">تسجيل الدخول وربط حساب Google السحابي</p>
        </div>

        <form onSubmit={handleLogin} className="space-y-3 text-xs">
          <div>
            <label className="font-bold text-slate-700 block mb-1">البريد الإلكتروني (Google Account):</label>
            <input
              type="email"
              dir="ltr"
              required
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              placeholder="name@gmail.com"
              className="w-full px-3 py-2 bg-slate-50 border border-slate-200 rounded-xl focus:bg-white focus:outline-hidden"
            />
          </div>

          <div>
            <label className="font-bold text-slate-700 block mb-1">الاسم الكريم:</label>
            <input
              type="text"
              required
              value={name}
              onChange={(e) => setName(e.target.value)}
              placeholder="اسم التاجر أو المنشأة"
              className="w-full px-3 py-2 bg-slate-50 border border-slate-200 rounded-xl focus:bg-white focus:outline-hidden"
            />
          </div>

          <div className="pt-2">
            <button
              type="submit"
              disabled={loading}
              className="w-full py-2.5 px-4 rounded-xl bg-sky-600 hover:bg-sky-700 text-white font-bold shadow-xs transition-colors flex items-center justify-center gap-2 disabled:opacity-50"
            >
              <Shield className="w-4 h-4" />
              <span>{loading ? 'جارٍ تسجيل الدخول...' : 'متابعة وتسجيل الدخول'}</span>
            </button>
          </div>
        </form>
      </div>
    </div>
  );
};
