# معاينة الواجهات تفاعلياً — ما هو ممكن وما ليس ممكناً، ولماذا

**التاريخ:** 2026-09-18 · **الإصدار:** 3.65.1+117
**الخلاصة:** `flutter run -d web-server` **لا يمكن أن يعمل في هذا المشروع**،
والمسار الصحيح للمعاينة التفاعلية في المتصفح هو **بناء Linux أصلي + noVNC**
— وهو مسار موجود فعلاً في المستودع (`qa/prepare_preview.sh`) ويتطلب بيئة
تسمح بتنزيل Flutter SDK.

---

## ١) لماذا الويب ليس خياراً (ثلاثة مانعات بنيوية، لا إعدادات)

| # | المانع | الدليل | الأثر |
|---|---|---|---|
| 1 | **`dart:io` مستورد في 37 ملفاً داخل `lib/`** | `grep -rl "import 'dart:io'" lib \| wc -l` → 37، منها `core/theme.dart` و`data/repository.dart` و`data/sync/cloud_join.dart` | `dart:io` غير موجود في تصريف الويب → فشل **تصريف** (compile)، لا فشل تشغيل |
| 2 | **قاعدة البيانات عبر `sqflite_common_ffi` (FFI)** | `pubspec.yaml` + 41 استعمالاً لـ FFI/`Process`/`ServerSocket`/`Directory` | `dart:ffi` غير مدعوم على الويب؛ يلزم `sqflite_web`/IndexedDB وطبقة تخزين بديلة |
| 3 | **لا يوجد مجلد `web/`** | `ls -d web` → غير موجود | المشروع أُنشئ لسطح المكتب/الموبايل؛ `flutter build web` لا يملك runner |

> النتيجة العملية: الأمر `flutter run -d web-server --web-port 8080 --web-hostname 0.0.0.0`
> يفشل في مرحلة التصريف حتى لو وُجد SDK سليم وشبكة مفتوحة. تحويل التطبيق
> للويب **مشروع معماري** (عزل `dart:io` خلف واجهات + طبقة تخزين ويب + خادم
> وكيل للمزامنة) وليس ضبط أعلامات.

## ٢) المسار الصحيح: بناء Linux أصلي وعرضه عبر noVNC

المستودع يملك هذا المسار جاهزاً في `qa/prepare_preview.sh`، وفكرته:

1. إنشاء runner Linux منفصل خارج المستودع (`~/.cache/nexora_qa_runtime`)
   حتى لا تتضخم حصة مساحة العمل.
2. نسخ `pubspec.yaml` + `pubspec.lock` + `lib/` + `assets/` إليه.
3. `flutter pub get && flutter build linux --debug`.
4. ربط أصول noVNC (`/usr/share/novnc/{core,vendor}`) داخل `qa/preview/`
   (روابط رمزية — **لا تُحذف** في `scripts/clean_flutter_env.sh` لأن
   `qa/preview/index.html` متتبَّع في git).
5. تشغيل البناء داخل `Xvfb` وفتحه في المتصفح عبر noVNC → **تفاعل لحظي
   حقيقي بالشاشات الأصلية نفسها**، لا محاكاة.

```bash
bash qa/prepare_preview.sh          # يحتاج Flutter + شبكة
./build.sh && ./run.sh              # أو بناء وتشغيل محلي (Xvfb تلقائياً)
```

## ٣) حدود بيئة الحاويات الحالية (موثّقة لتوفير الوقت)

`bash scripts/env_check.sh` يفحص هذا آلياً. القياس الفعلي في هذه البيئة:

| المورد | الحالة | الأثر |
|---|---|---|
| Flutter SDK | ⛔ غير مثبّت (`/opt/flutter` غير موجود) | لا `flutter` ولا `dart` |
| `storage.googleapis.com` | ⛔ محجوب | مصدر **محرك** Flutter — لا يمكن تثبيت SDK إطلاقاً |
| `pub.dev` | ⛔ محجوب | لا `flutter pub get` (34 حزمة غير مضمّنة في المستودع) |
| `flutter.dev` / `dart.dev` / `fonts.gstatic.com` / `deb.debian.org` | ⛔ محجوبة | لا تنزيل أدوات مساعدة |
| `github.com` / `api.github.com` / `codeload.github.com` | ✅ متاحة | git/gh + سحب ملفات من مستودعات GitHub |
| `pypi.org` | ✅ متاح | أدوات تحقق بايثونية (`fonttools`) |
| `registry.npmjs.org` | ✅ متاح | خادم ملفات ساكن إن لزم |

**ما لا يمكن في هذه البيئة:** تثبيت Flutter، `pub get`، `analyze`، `test`،
أي بناء (APK/Linux/Windows)، وأي معاينة ويب أو noVNC.

**ما يمكن:** قراءة الكود وتدقيقه، تعديل المصادر، فحص الأصول الثنائية
(خطوط/صور) بأدوات بايثون، تشغيل اختبارات منطقية مكتفية بـ `dart:io`،
والاعتماد على **CI في GitHub Actions** (`verify.yml` يشغّل `flutter analyze`
و167+ اختباراً على أربع شرائح، وثلاثة workflows للبناء) كمصدر حقيقة
للتحقق النهائي.

## ٤) بديل المعاينة البصرية بلا Flutter

عند الحاجة لمعاينة **قرار بصري محدد** (خط، لون، تباعد) دون SDK:

- **مقارنة الخطوط مباشرة:** افتح `assets/fonts/*.ttf` في أي عارض خطوط على
  جهازك — الأوزان الستة (400/500/600/700/800/900) كلها Cairo 3.130.
- **تحقق آلي من الهوية:** `python3 scripts/verify_fonts.py` يقرأ جداول
  `name`/`OS/2`/`cmap` داخل الملفات نفسها ويتأكد أن كل وزن مستخدم في
  الشيفرة له ملف حقيقي من عائلة Cairo، وأن التغطية العربية متساوية
  (297 محرفاً في كل وزن).
- **صفحة HTML ساكنة:** يمكن توليد صفحة تعرض ألوان `AppColors` وخط Cairo
  بمحاكاة لشاشة محددة، وتُخدَم على المنفذ 8080 لتظهر في لوح المعاينة.
  هذا **محاكاة بصرية** لا التطبيق — يُستخدم للاتفاق على الشكل قبل البناء.

## ٥) ملفات ذات صلة

- `scripts/env_check.sh` — تشخيص البيئة (SDK/شبكة/حصة/ويب/خطوط).
- `scripts/clean_flutter_env.sh` — تنظيف مخلفات البناء مع حارس ضد حذف
  أي ملف متتبَّع في git.
- `scripts/verify_fonts.py` — فحص أصول الخطوط بلا Flutter.
- `test/qa_ui_font_test.dart` و`admin_app/test/qa_admin_font_test.dart` —
  الحراسة نفسها داخل حزمة الاختبارات (تُشغَّل في CI).
- `البيئة-المحلية.md` — إعداد بيئة Linux كاملة (حيث تتوفر الشبكة).
- `qa/prepare_preview.sh` — مسار noVNC المذكور أعلاه.
