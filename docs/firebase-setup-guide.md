# خطوات إعداد Firebase للإصدار الإنتاجي (Production)

## 1. إنشاء مشروع Firebase
- افتح https://console.firebase.google.com
- أنشئ مشروعاً جديداً (أو استخدم مشروعاً موجوداً).
- فعّل **Google Authentication** من قسم Build → Authentication → Sign-in method → Google.

## 2. إنشاء Realtime Database
- من القائمة اليسرى: Build → Realtime Database → Create database.
- اختر أقرب منطقة جغرافية (مثلاً europe-west1 أو asia-southeast1).
- ابدأ بوضع **locked mode** (مقفول) ثم استبدل القواعد بالقواعد أدناه.

## 3. ربط التطبيق
- من Project settings → Add app → Android و Windows (لا تحتاج GoogleService-json للعمل عبر REST لأننا نستخدم REST فقط).
- في الحقيقة نستخدم **REST API مباشرة** مع id_token من Google Sign-In، لذا لا حاجة إلى google-services.json.

## 4. قواعد قاعدة البيانات (Database Rules)
في نافذة "Realtime Database → Rules"، الصق القواعد التالية:

```json
{
  "rules": {
    "workspaces": {
      "$wsId": {
        ".read": "auth != null",
        ".write": "auth != null",
        "operations": {
          ".indexOn": ["timestamp"],
          "$opId": {
            ".validate": "newData.hasChildren(['id','deviceId','workspaceId','entityType','entityId','opType','version','payload','timestamp']) && newData.child('workspaceId').val() == $wsId"
          }
        },
        "meta": { ".write": "auth != null" }
      }
    }
  }
}
```

⚠️ هذه القواعد تتطلب مصادقة (auth != null) — أي مستخدم سجل دخوله بجوجل يستطيع القراءة والكتابة.
للعزل التام بين المستخدمين يُنصح لاحقاً بربط workspaceId بقائمة المستخدمين المصرح لهم في جدول `workspaces/members`.

## 5. نسخ رابط قاعدة البيانات
- من صفحة Realtime Database ستجد رابطاً بالشكل:
  `https://YOUR-PROJECT-default-rtdb.REGION.firebasedatabase.app`
- في التطبيق: الإعدادات → المزامنة السحابية → الصق الرابط، فعّل "مزامنة تلقائية" → احفظ.

## 6. الاختبار
- سجّل الدخول بحساب Google على الجهاز الرئيسي.
- أضف بيانات (فاتورة/صنف/حساب).
- على جهاز ثانٍ: سجّل دخول بنفس الحساب (أو حساب مشارك في نفس الـ Workspace مستقبلاً)، ثم الصق نفس رابط القاعدة.
- اضغط "حفظ ومزامنة الآن" — ستظهر البيانات على الجهاز الآخر.

## 7. إيقاف القواعد المفتوحة
احذف أي قواعد مؤقتة مثل `".read": true, ".write": true` — لا تتركها مفعّلة.

## 8. بيانات حساسة
- لا تضع service account key داخل التطبيق أو GitHub.
- لا تشارك معرف المشروع مع من لا يجب أن يصل إلى قاعدتك.
- النسخ الاحتياطية .nexora التي يُصدّرها التطبيق لا تحتوي على id_token ولا auth_secret.
