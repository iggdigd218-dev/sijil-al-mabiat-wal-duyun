import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:nexora_app/core/accounting.dart';
import 'package:nexora_app/core/database.dart';
import 'package:nexora_app/core/models.dart';
import 'package:nexora_app/core/sfx.dart';
import 'package:nexora_app/core/theme.dart';
import 'package:nexora_app/data/providers.dart';
import 'package:nexora_app/data/repository.dart';
import 'package:nexora_app/data/sync/sync_engine.dart';
import 'package:nexora_app/ui/home_shell.dart';
import 'package:nexora_app/ui/tx_form.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:nexora_app/core/cloud_config.dart';

/// (استقرار CI) الكتابة إلى SQLite تتم في مهمة غير متزامنة بعد إغلاق
/// النموذج؛ تحت حمل الآلة قد تتأخر بضعة أجزاء من الثانية، والتأكيد
/// الفوري كان يرى صفر صفوف في fail متقلّب. ننتظر وصول الصف بحدّ زمني
/// واضح، ثم نُبقي التأكيد نفسه (hasLength(1)) صارماً في كشف التكرار.
Future<List<Tx>> _awaitTransactions(Repo repo, {int expected = 1}) async {
  for (var i = 0; i < 80; i++) {
    final rows = await repo.transactions();
    if (rows.length >= expected) return rows;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  return repo.transactions();
}

Future<void> _drain(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  // هذه الحزمة تحاكي سيناريوهات «لا سحابة» — نلغي الرابط الافتراضي
  // المضمن (Zero-Config) حتى تبقى فرضياتها صالحة.
  debugDefaultBackendUrlOverride = '';
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  testWidgets(
      'QA-E2E real HomeShell button to validation to SQLite to list and balance refresh to reopen',
      (tester) async {
    late Directory tmp;
    late Database db;
    late Repo repo;
    late SyncEngine engine;
    late int accountId;
    await tester.runAsync(() async {
      await initializeDateFormatting('ar');
      await initializeDateFormatting('en');
      await (FontLoader('Tajawal')
            ..addFont(rootBundle.load('assets/fonts/Tajawal-Regular.ttf')))
          .load();
      tmp = await Directory.systemTemp.createTemp('nexora_e2e_');
      db = await databaseFactory.openDatabase('${tmp.path}/e2e.db',
          options: OpenDatabaseOptions(
              onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON')));
      await AppDatabase.createSchema(db);
      repo = Repo(databaseProvider: () async => db);
      await repo.initSyncInfra(); // (دفعة 57) هوية الجهاز إلزامية قبل الكتابة.
      final now = DateTime(2026, 9, 6);
      accountId = await repo.saveAccount(Account(
          name: 'QA E2E customer',
          kind: AccountKind.customer,
          openingBalance: 1000,
          notifyChannel: 'none',
          createdAt: now,
          updatedAt: now));
      engine = SyncEngine(repo: repo, dbProvider: () async => db);
    });
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 900);
    Sfx.setMuted(true);
    try {
      await tester.pumpWidget(ProviderScope(
          overrides: [
            repoProvider.overrideWithValue(repo),
            syncEngineProvider.overrideWithValue(engine),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            locale: const Locale('ar'),
            supportedLocales: const [Locale('ar')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            home: const HomeShell(),
          )));
      await _drain(tester);
      // في الواجهة الجديدة شاشة العمليات تُفتح من أيقونة «المعاملات» على لوحة
      // التحكم (ولم يعد «العمليات» عنصراً في الشريط السفلي).
      final txTile = find.text('المعاملات');
      await tester.ensureVisible(txTile);
      await tester.pumpAndSettle();
      await tester.tap(txTile, warnIfMissed: false);
      await _drain(tester);
      final fab = find.text('تسجيل عملية');
      await tester.ensureVisible(fab);
      await tester.pumpAndSettle();
      await tester.tap(fab, warnIfMissed: false);
      await _drain(tester);
      await tester.tap(find.text('عليه'));
      await tester.enterText(
          find.widgetWithText(TextFormField, 'المبلغ *'), '٥٠٠');
      await tester.enterText(
          find.widgetWithText(TextFormField, 'البيان / الوصف'), 'QA UI SAVE');
      final save = find.text('حفظ العملية');
      await tester.ensureVisible(save);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(save);
      await tester
          .tap(save); // Same frame: there must still be exactly one write.
      await tester.pump(const Duration(milliseconds: 70));
      await _drain(tester);
      await _drain(tester);
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(TxForm), findsNothing);
      // (دفعة 58 — متطلب 10) البطاقة تعرض «الوصف · HH:MM» — نطابق جزئياً.
      expect(find.textContaining('QA UI SAVE'), findsOneWidget);
      await tester.runAsync(() async {
        final rows = await _awaitTransactions(repo);
        expect(rows, hasLength(1));
        expect(rows.single.amount, 500);
        expect(rows.single.reference, '1');
        expect(rows.single.accountId, accountId);
        expect(await repo.balanceOf((await repo.account(accountId))!), 1500);
      });
      // عرض 1000 > عتبة سطح المكتب (900): الشريط السفلي استُبدل بشريط
      // جانبي (Rail) — ننقر عنوان «دفتر الحسابات والديون» فيه.
      await tester.tap(find.text('دفتر الحسابات والديون'));
      await _drain(tester);
      expect(find.textContaining('1,500'), findsWidgets);
      expect(tester.takeException(), isNull);
    } finally {
      // ═══ تشخيص مرحلي مؤقت (يُحذف بعد تحديد موضع الفقد) ═══
      await tester.runAsync(() async {
        print('DIAG-A قبل الهدم: tx=${(await db.query('transactions')).length}'
            ' accounts=${(await db.query('accounts')).length}');
      });
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        print('DIAG-B بعد pumpWidget: tx=${(await db.query('transactions')).length}'
            ' accounts=${(await db.query('accounts')).length}');
      });
      engine.stop();
      await tester.runAsync(() async {
        print('DIAG-C بعد engine.stop: tx=${(await db.query('transactions')).length}'
            ' accounts=${(await db.query('accounts')).length}');
      });
      await tester.runAsync(() async {
        // (استقرار CI) لا تُقرأ الصفوف عبر مقبض `repo` بعد هدم الشجرة:
        // المقبض مرتبط بدورة حياة الواجهة، وأي مهمة معلّقة قد تُكتب بعد
        // الهدم فتُقلب النتيجة — ترك ذلك الاختبار رهينةً لتجميع الشُعب
        // في CI (تغيّر التجميع ينقله بين النجاح والفشل بلا سبب في الكود).
        // الإثبات الحقيقي للاستمرارية يتم أدناه عبر نسخة من ملف القاعدة
        // بمقبض منفصل تماماً.
        // (استقرار CI) إثبات الاستمرارية على القرص يتم عبر **نسخة** من
        // ملف القاعدة ومقبض منفصل تماماً — بلا إغلاق مقبض `repo` أثناء
        // حياته. النمط القديم (إغلاق ثم إعادة فتح المسار نفسه) كان يترك
        // نافذة زمنية ترى فيها أي عملية معلّقة مقبضاً مغلقاً
        // (DatabaseException: database_closed) — فشل متقلّب ظهر مع
        // تقسيم الاختبارات في CI (تجميع مختلف للمهام).
        // ملاحظة: sqflite يعيد النسخة نفسها للمسار الواحد، لذا فتح مسار
        // ثانٍ قبل إغلاق الأول لا يعطي مقبضاً مستقلاً — النسخ تحلّها.
        final src = '${tmp.path}/e2e.db';
        final copy = '${tmp.path}/e2e_verify.db';
        await File(src).copy(copy);
        for (final suf in const ['-wal', '-shm']) {
          final f = File('$src$suf');
          if (await f.exists()) await f.copy('$copy$suf');
        }
        final verify = await databaseFactory.openDatabase(copy);
        try {
          print('DIAG-D على النسخة: tx=${(await verify.query('transactions')).length}'
              ' accounts=${(await verify.query('accounts')).length}');
          final txRows = await verify.query('transactions');
          expect(txRows, hasLength(1),
              reason: 'عملية واحدة بالضبط على القرص — لا تكرار ولا فقد');
          expect(txRows.single['deleted_at'] ?? '', '',
              reason: 'العملية ليست محذوفة ناعماً');
          expect(txRows.single['amount'], 500);
          expect(txRows.single['reference'], '1');
          expect(await verify.query('accounts'), hasLength(1));
        } finally {
          await verify.close();
        }
        await db.close();
        await tmp.delete(recursive: true);
      });
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    }
  });
}
