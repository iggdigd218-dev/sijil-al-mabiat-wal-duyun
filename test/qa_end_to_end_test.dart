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

Future<void> _drain(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
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
        final rows = await repo.transactions();
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
      await tester.pumpWidget(const SizedBox.shrink());
      engine.stop();
      await tester.runAsync(() async {
        await db.close();
        db = await databaseFactory.openDatabase('${tmp.path}/e2e.db');
        expect(await repo.transactions(), hasLength(1));
        expect(await repo.balanceOf((await repo.account(accountId))!), 1500);
        await db.close();
        await tmp.delete(recursive: true);
      });
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    }
  });
}
