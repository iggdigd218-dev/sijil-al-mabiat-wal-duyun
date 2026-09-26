// 🔑 QA — ترقية بطاقات المشتركين والبحث وبيانات التراخيص (2026-09-24).
//
// يختبر هذا الملف:
//  LIC-ADM01: تحويل وقراءة حقول المشترك (اسم المحل، العميل، الهاتف، كود الترخيص، معرف الجهاز)
//  LIC-ADM02: تحويل السجلات وتوليد المفتاح التلقائي عند غيابه عبر fromSubscriptionMap
//  LIC-ADM03: تصميم بطاقة المشترك الجديد (اسم المحل بارز مع الأيقونة، أزرار الاتصال وواتساب، أزرار النسخ)
//  LIC-ADM04: بطاقة بدون اسم منشأة تعرض الاسم الافتراضي بسلاسة
//  LIC-ADM05: توسيع البحث ليشمل اسم المحل والعميل والهاتف ومعرف الجهاز وكود الترخيص
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:license_admin/main.dart';
import 'package:license_admin/rtdb.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUpAll(() async {
    await initializeDateFormatting('ar', null);
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('License Admin Data Layer Tests', () {
    test('LIC-ADM01 قراءة وتحويل حقول المشترك كاملة في SubscriberEntry', () {
      const entry = SubscriberEntry(
        workspaceId: 'WS-TEST-001',
        clientName: 'عبدالرحمن باوزير',
        storeName: 'مركز المدينة التجاري',
        phone: '777000111',
        deviceId: 'DEVICE-ABCD1234',
        licenseKey: 'NX-ABCD-1234-EF56',
        deviceRef: 'DEVICE-ABCD1234',
        planType: 'enterprise',
        maxDevices: 5,
        expiresAtMs: 1800000000000,
        status: 'active',
        activatedAtMs: 1700000000000,
      );

      expect(entry.clientName, 'عبدالرحمن باوزير');
      expect(entry.storeName, 'مركز المدينة التجاري');
      expect(entry.phone, '777000111');
      expect(entry.deviceId, 'DEVICE-ABCD1234');
      expect(entry.licenseKey, 'NX-ABCD-1234-EF56');
      expect(entry.workspaceId, 'WS-TEST-001');
      expect(entry.maxDevices, 5);
      expect(entry.status, 'active');
    });

    test('LIC-ADM02 تحويل السجلات وتوليد المفتاح التلقائي عند غيابه', () {
      final entry = SubscriberEntry.fromSubscriptionMap(
        'WS-FALLBACK',
        {
          'clientName': 'سالم صالح',
          'storeName': 'بقالة البركة',
          'phone': '733123456',
          'device_id': 'DEVICE-XYZ999',
          'plan_type': 'individual',
          'max_devices': 1,
          'expires_at': 1800000000000,
          'status': 'trial',
        },
      );

      expect(entry.clientName, 'سالم صالح');
      expect(entry.storeName, 'بقالة البركة');
      expect(entry.phone, '733123456');
      expect(entry.deviceId, 'DEVICE-XYZ999');
      // بما أن licenseKey لم يُحدد، يجب توليده تلقائياً من معرف الجهاز
      expect(entry.licenseKey.startsWith('NX-'), isTrue);
      expect(entry.status, 'trial');
    });
  });

  group('SubscriberCard Widget Tests', () {
    testWidgets('LIC-ADM03 عرض اسم المحل بارزاً والعميل والهاتف وأزرار التواصل والنسخ',
        (tester) async {
      tester.view.physicalSize = const Size(800, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      final entry = SubscriberEntry(
        workspaceId: 'WS-CARD-01',
        clientName: 'طارق الأهدل',
        storeName: 'صيدلية النور الحديثة',
        phone: '777888999',
        deviceId: 'DEVICE-CARD-001',
        licenseKey: 'NX-CARD-0001-2026',
        deviceRef: 'DEVICE-CARD-001',
        planType: 'enterprise',
        maxDevices: 3,
        expiresAtMs: DateTime.now().add(const Duration(days: 45)).millisecondsSinceEpoch,
        status: 'active',
        activatedAtMs: DateTime.now().subtract(const Duration(days: 10)).millisecondsSinceEpoch,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SubscriberCard(
              entry: entry,
              onExtend: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 1. اسم المحل بارز مع أيقونة المحل
      expect(find.text('صيدلية النور الحديثة'), findsOneWidget);
      expect(find.byIcon(Icons.storefront_rounded), findsOneWidget);

      // 2. اسم العميل ورقم الهاتف
      expect(find.text('طارق الأهدل'), findsOneWidget);
      expect(find.text('777888999'), findsOneWidget);

      // 3. أزرار التواصل (اتصال سريع + واتساب بنقرة)
      expect(find.byIcon(Icons.phone_in_talk), findsOneWidget);
      expect(find.text('اتصال سريع'), findsOneWidget);
      expect(find.byIcon(Icons.chat_bubble_outline), findsOneWidget);
      expect(find.text('واتساب بنقرة'), findsOneWidget);

      // 4. كود الترخيص ومعرف الجهاز وأزرار النسخ
      expect(find.text('NX-CARD-0001-2026'), findsOneWidget);
      expect(find.text('DEVICE-CARD-001'), findsOneWidget);
      expect(find.byIcon(Icons.copy), findsNWidgets(2));

      // 5. زر التمديد السريع وشارة الخطة
      expect(find.text('تمديد بنقرة'), findsOneWidget);
      expect(find.text('فعّال'), findsOneWidget);
      expect(find.text('باقة مؤسسة (3 أجهزة مصرحة)'), findsOneWidget);
    });

    testWidgets('LIC-ADM04 بطاقة بدون اسم منشأة تعرض الاسم الافتراضي بسلاسة',
        (tester) async {
      tester.view.physicalSize = const Size(800, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      final entry = SubscriberEntry(
        workspaceId: 'WS-ANON-01',
        clientName: '',
        storeName: '',
        phone: '',
        deviceId: 'DEVICE-ANON-01',
        licenseKey: 'NX-ANON-0000-0001',
        deviceRef: 'DEVICE-ANON-01',
        planType: 'individual',
        maxDevices: 1,
        expiresAtMs: DateTime.now().add(const Duration(days: 5)).millisecondsSinceEpoch,
        status: 'trial',
        activatedAtMs: DateTime.now().millisecondsSinceEpoch,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SubscriberCard(
              entry: entry,
              onExtend: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // التحقق من التراجع التلقائي
      expect(find.text('WS-ANON-01'), findsOneWidget);
      expect(find.text('مسؤول غير محدد'), findsOneWidget);
      expect(find.text('تجريبي'), findsOneWidget);
      expect(find.text('باقة فردية (جهاز واحد مصرح)'), findsOneWidget);
    });
  });

  group('Search Filtering Logic Tests', () {
    test('LIC-ADM05 التحقق من تغطية البحث لكافة الحقول الخمسة', () {
      const entries = [
        SubscriberEntry(
          workspaceId: 'WS-SEARCH-01',
          clientName: 'ياسر الشميري',
          storeName: 'سوبرماركت البركة',
          phone: '771122334',
          deviceId: 'DEVICE-DEV01-ABC',
          licenseKey: 'NX-ALBR-0001-2026',
          deviceRef: 'DEVICE-DEV01-ABC',
          planType: 'enterprise',
          maxDevices: 5,
          expiresAtMs: 1800000000000,
          status: 'active',
          activatedAtMs: 1700000000000,
        ),
        SubscriberEntry(
          workspaceId: 'WS-SEARCH-02',
          clientName: 'فؤاد المخلافي',
          storeName: 'مكتبة الفجر',
          phone: '733445566',
          deviceId: 'DEVICE-DEV02-XYZ',
          licenseKey: 'NX-FAJR-0002-2026',
          deviceRef: 'DEVICE-DEV02-XYZ',
          planType: 'individual',
          maxDevices: 1,
          expiresAtMs: 1800000000000,
          status: 'trial',
          activatedAtMs: 1700000000000,
        ),
      ];

      // 1. البحث باسم المحل
      bool filter(SubscriberEntry e, String q) {
        final query = q.trim().toLowerCase();
        return e.storeName.toLowerCase().contains(query) ||
            e.clientName.toLowerCase().contains(query) ||
            e.phone.toLowerCase().contains(query) ||
            e.deviceId.toLowerCase().contains(query) ||
            e.licenseKey.toLowerCase().contains(query) ||
            e.workspaceId.toLowerCase().contains(query);
      }

      expect(entries.where((e) => filter(e, 'البركة')).length, 1);
      expect(entries.where((e) => filter(e, 'البركة')).first.storeName, 'سوبرماركت البركة');

      // 2. البحث باسم العميل
      expect(entries.where((e) => filter(e, 'المخلافي')).length, 1);
      expect(entries.where((e) => filter(e, 'المخلافي')).first.clientName, 'فؤاد المخلافي');

      // 3. البحث برقم الهاتف
      expect(entries.where((e) => filter(e, '771122334')).length, 1);
      expect(entries.where((e) => filter(e, '771122334')).first.phone, '771122334');

      // 4. البحث بمعرف الجهاز
      expect(entries.where((e) => filter(e, 'DEV02-XYZ')).length, 1);
      expect(entries.where((e) => filter(e, 'DEV02-XYZ')).first.deviceId, 'DEVICE-DEV02-XYZ');

      // 5. البحث بكود الترخيص
      expect(entries.where((e) => filter(e, 'NX-FAJR')).length, 1);
      expect(entries.where((e) => filter(e, 'NX-FAJR')).first.licenseKey, 'NX-FAJR-0002-2026');
    });

    test('LIC-ADM06 دقة فلترة النشطين والتجريبيين والمنتهين', () {
      final now = DateTime.now().millisecondsSinceEpoch;
      final list = [
        SubscriberEntry(
          workspaceId: 'WS-ACTIVE-01',
          planType: 'individual',
          status: 'active',
          maxDevices: 1,
          expiresAtMs: now + 86400000 * 20,
          activatedAtMs: now,
          deviceRef: 'DEV-1',
        ),
        SubscriberEntry(
          workspaceId: 'WS-TRIAL-01',
          planType: 'individual',
          status: 'trial',
          maxDevices: 1,
          expiresAtMs: now + 86400000 * 5,
          activatedAtMs: now,
          deviceRef: 'DEV-2',
        ),
        SubscriberEntry(
          workspaceId: 'WS-EXPIRED-01',
          planType: 'individual',
          status: 'active',
          maxDevices: 1,
          expiresAtMs: now - 86400000,
          activatedAtMs: now - 86400000 * 30,
          deviceRef: 'DEV-3',
        ),
      ];

      // فلتر النشطين يستثني التجريبيين بدقة
      final active = list.where((s) =>
          !s.isFrozen &&
          s.status != 'trial' &&
          s.status != 'suspended' &&
          (s.expiresAtMs > now || s.isLifetime)).toList();
      expect(active.length, 1);
      expect(active.first.workspaceId, 'WS-ACTIVE-01');

      // فلتر التجريبيين
      final trials = list.where((s) =>
          !s.isFrozen &&
          s.status == 'trial' &&
          (s.expiresAtMs > now || s.isLifetime)).toList();
      expect(trials.length, 1);
      expect(trials.first.workspaceId, 'WS-TRIAL-01');

      // فلتر المنتهين
      final expired = list.where((s) =>
          !s.isFrozen &&
          !s.isLifetime &&
          s.expiresAtMs <= now).toList();
      expect(expired.length, 1);
      expect(expired.first.workspaceId, 'WS-EXPIRED-01');
    });

    test('LIC-ADM07 عرض قائمة الأجهزة وعدد الأعضاء في SubscriberEntry', () {
      const entry = SubscriberEntry(
        workspaceId: 'WS-DEVICES-01',
        storeName: 'مركز عثمان الوصابي',
        clientName: 'فخامة المدير',
        phone: '774190040',
        planType: 'enterprise',
        status: 'active',
        maxDevices: 5,
        expiresAtMs: 1800000000000,
        activatedAtMs: 1700000000000,
        deviceRef: 'DEVICE-01',
        devicesList: ['فخامة المدير', 'ايمن', 'مستخدم جديد', 'حموود'],
        memberCount: 4,
      );

      expect(entry.devicesList.length, 4);
      expect(entry.memberCount, 4);
      expect(entry.devicesList.contains('فخامة المدير'), isTrue);
      expect(entry.storeName, 'مركز عثمان الوصابي');
      expect(entry.clientName, 'فخامة المدير');
    });
  });
}
