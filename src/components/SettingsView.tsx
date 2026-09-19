import React, { useState, useEffect } from 'react';
import { Settings, Save, Building, Phone, MapPin, DollarSign, Cloud, Shield } from 'lucide-react';
import { api } from '../api';

interface SettingsViewProps {
  onShowToast: (msg: string, type?: 'success' | 'error' | 'info') => void;
}

export const SettingsView: React.FC<SettingsViewProps> = ({ onShowToast }) => {
  const [loading, setLoading] = useState(false);
  const [settings, setSettings] = useState({
    business_name: 'سجل المبيعات والديون',
    business_name_en: 'Nexora Ledger & POS',
    business_phone: '+967 770 000 000',
    business_address: 'صنعاء - الجمهورية اليمنية',
    currency: 'YER',
    cloud_sync_url: 'https://nexora-sync.firebaseio.com',
    workspace_mode: 'group',
  });

  useEffect(() => {
    api.getSettings().then((data) => {
      if (data && Object.keys(data).length > 0) {
        setSettings((prev) => ({ ...prev, ...data }));
      }
    });
  }, []);

  const handleSave = async (e: React.FormEvent) => {
    e.preventDefault();
    setLoading(true);
    try {
      await api.saveSettings(settings);
      onShowToast('تم حفظ إعدادات المنشأة بنجاح!', 'success');
    } catch (err: any) {
      onShowToast(err.message || 'فشل حفظ الإعدادات', 'error');
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="max-w-2xl mx-auto space-y-6">
      <div className="bg-white rounded-2xl p-4 border border-slate-200 shadow-xs flex items-center justify-between">
        <div>
          <h3 className="font-extrabold text-sm text-slate-800">إعدادات وبيانات المنشأة</h3>
          <p className="text-xs text-slate-400">تخصيص ترويسة الفواتير، العملة الافتراضية، وإعدادات الربط السحابي</p>
        </div>
      </div>

      <form onSubmit={handleSave} className="bg-white rounded-2xl border border-slate-200 shadow-xs p-6 space-y-4">
        <div>
          <label className="text-xs font-bold text-slate-700 block mb-1">اسم المنشأة / المحل (بالعربية):</label>
          <div className="relative">
            <Building className="w-4 h-4 absolute right-3 top-3 text-slate-400" />
            <input
              type="text"
              value={settings.business_name}
              onChange={(e) => setSettings({ ...settings, business_name: e.target.value })}
              className="w-full pr-9 pl-3 py-2 bg-slate-50 border border-slate-200 rounded-xl text-xs focus:bg-white focus:outline-hidden"
              required
            />
          </div>
        </div>

        <div>
          <label className="text-xs font-bold text-slate-700 block mb-1">اسم المنشأة بالإنجليزية (English):</label>
          <input
            type="text"
            dir="ltr"
            value={settings.business_name_en}
            onChange={(e) => setSettings({ ...settings, business_name_en: e.target.value })}
            className="w-full px-3 py-2 bg-slate-50 border border-slate-200 rounded-xl text-xs focus:bg-white focus:outline-hidden"
          />
        </div>

        <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
          <div>
            <label className="text-xs font-bold text-slate-700 block mb-1">رقم الهاتف / الواتساب:</label>
            <div className="relative">
              <Phone className="w-4 h-4 absolute right-3 top-3 text-slate-400" />
              <input
                type="text"
                dir="ltr"
                value={settings.business_phone}
                onChange={(e) => setSettings({ ...settings, business_phone: e.target.value })}
                className="w-full pr-9 pl-3 py-2 bg-slate-50 border border-slate-200 rounded-xl text-xs focus:bg-white focus:outline-hidden"
              />
            </div>
          </div>

          <div>
            <label className="text-xs font-bold text-slate-700 block mb-1">العملة الافتراضية:</label>
            <div className="relative">
              <DollarSign className="w-4 h-4 absolute right-3 top-3 text-slate-400" />
              <select
                value={settings.currency}
                onChange={(e) => setSettings({ ...settings, currency: e.target.value })}
                className="w-full pr-9 pl-3 py-2 bg-slate-50 border border-slate-200 rounded-xl text-xs font-bold focus:bg-white focus:outline-hidden"
              >
                <option value="YER">ريال يمني (YER)</option>
                <option value="SAR">ريال سعودي (SAR)</option>
                <option value="USD">دولار أمريكي (USD)</option>
                <option value="AED">درهم إماراتي (AED)</option>
              </select>
            </div>
          </div>
        </div>

        <div>
          <label className="text-xs font-bold text-slate-700 block mb-1">العنوان والموقع:</label>
          <div className="relative">
            <MapPin className="w-4 h-4 absolute right-3 top-3 text-slate-400" />
            <input
              type="text"
              value={settings.business_address}
              onChange={(e) => setSettings({ ...settings, business_address: e.target.value })}
              className="w-full pr-9 pl-3 py-2 bg-slate-50 border border-slate-200 rounded-xl text-xs focus:bg-white focus:outline-hidden"
            />
          </div>
        </div>

        <div className="pt-2 border-t border-slate-100">
          <label className="text-xs font-bold text-slate-700 block mb-1">خادم المزامنة السحابية (Firebase / Cloud Server):</label>
          <div className="relative">
            <Cloud className="w-4 h-4 absolute right-3 top-3 text-slate-400" />
            <input
              type="text"
              dir="ltr"
              value={settings.cloud_sync_url}
              onChange={(e) => setSettings({ ...settings, cloud_sync_url: e.target.value })}
              className="w-full pr-9 pl-3 py-2 bg-slate-50 border border-slate-200 rounded-xl text-xs font-mono focus:bg-white focus:outline-hidden"
            />
          </div>
        </div>

        <div className="pt-4 flex justify-end">
          <button
            type="submit"
            disabled={loading}
            className="flex items-center gap-2 px-6 py-2.5 rounded-xl bg-sky-600 hover:bg-sky-700 text-white text-xs font-extrabold shadow-sm transition-colors disabled:opacity-50"
          >
            <Save className="w-4 h-4" />
            <span>حفظ الإعدادات</span>
          </button>
        </div>
      </form>
    </div>
  );
};
