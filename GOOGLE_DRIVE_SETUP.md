# إعداد Google Drive

يستخدم التطبيق Google Identity Services للحصول على رمز وصول مؤقت بصلاحية محدودة `https://www.googleapis.com/auth/drive.file`. لا يحتوي المستودع أو APK على Client Secret أو refresh token.

## إعداد Google Cloud

1. أنشئ مشروعاً أو استخدم المشروع المرتبط بالتطبيق، ثم فعّل **Google Drive API**.
2. أنشئ OAuth consent screen من نوع **External**. أثناء وضع Testing أضف حسابات الاستخدام إلى **Test users**، أو انقل التطبيق إلى **In production** عند الجاهزية.
3. أنشئ OAuth Client من نوع **Web application**، وضع Client ID في `firebase-applet-config.json` أو في إعداد البناء الآمن المناسب. لا تضع Client Secret في الواجهة أو Git.
4. أضف أصل التشغيل الفعلي الظاهر في `window.location.origin` إلى **Authorized JavaScript origins**. في بيئة Capacitor قد يكون الأصل `https://localhost`، ويجب إضافته إذا ظهر حرفياً في سجل التشخيص. أضف أيضاً أصل التطوير الفعلي المستخدم من خادم المشروع، ولا تضف أصولاً عشوائية.
5. لا تخلط بين **Authorized JavaScript origins** و **Authorized redirect URIs**. تدفق GIS الحالي يستخدم Token Client ولا يعتمد Redirect URI عشوائياً. إذا تغير التدفق لاحقاً إلى Authorization Code، أضف Redirect URI المطابق حرفياً لذلك التدفق فقط.
6. تأكد من أن Audience يطابق إعداد OAuth consent screen، وأن حساب Google الذي سيختبر التطبيق موجود ضمن Test users أثناء وضع Testing.

## التشخيص

عند التطوير، راجع `window.location.origin` في سجل WebView/المتصفح وسجّل القيمة حرفياً في إعدادات OAuth. أخطاء `origin_mismatch` تعني أن الأصل الفعلي غير موجود في Authorized JavaScript origins، ولا يمكن إصلاحها بتعديل JavaScript وحده.

## حدود Android

تسجيل Google داخل WebView غير موثوق ولا يجب تحويله إلى صفحة Google مضمّنة. للحصول على Google Sign-In أصلي كامل في Android يلزم OAuth Android Client مرتبط بـ package ID وشهادة التوقيع SHA-1/SHA-256، ثم إعداد Google Play Services أو مكتبة Android موثوقة. لا يمكن تخمين هذه القيم من المستودع.
