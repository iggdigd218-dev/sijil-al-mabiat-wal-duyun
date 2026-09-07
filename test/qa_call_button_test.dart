import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:nexora_app/core/database.dart';
import 'package:nexora_app/core/sfx.dart';
import 'package:nexora_app/data/providers.dart';
import 'package:nexora_app/data/repository.dart';
import 'package:nexora_app/ui/account_form.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'url_launcher_mock.dart';

Future<void> _drain(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)));
    await tester.pump(const Duration(milliseconds: 80));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  setUpAll(() async {
    await initializeDateFormatting('ar');
    Sfx.setMuted(true);
    setupUrlLauncherMock();
  });

  Widget wrap(Repo repo, Widget child) => ProviderScope(
        overrides: [repoProvider.overrideWithValue(repo)],
        child: MaterialApp(
          locale: const Locale('ar'),
          supportedLocales: const [Locale('ar')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: child,
        ),
      );

  Future<void> _run(
    WidgetTester tester,
    String name,
    Future<void> Function(WidgetTester tester, Repo repo) body,
  ) async {
    late Database db;
    late Repo repo;
    await tester.runAsync(() async {
      db = await databaseFactory.openDatabase(inMemoryDatabasePath,
          options: OpenDatabaseOptions(
            version: 1,
            onConfigure: (d) => d.execute('PRAGMA foreign_keys = ON'),
            onCreate: (d, _) => AppDatabase.createSchema(d),
          ));
      repo = Repo(databaseProvider: () async => db);
    });
    mockLaunchLog.clear();
    mockCanLaunchResult = true;
    try {
      await body(tester, repo);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 40));
      await tester.runAsync(() => db.close());
    }
  }

  testWidgets('زر الاتصال يظهر بجانب حقل الاسم', (tester) async {
    await _run(tester, 'x', (t, repo) async {
      await t.pumpWidget(wrap(repo, const AccountFormScreen()));
      await _drain(t);
      expect(find.widgetWithText(TextFormField, 'اسم الحساب *'), findsWidgets);
      expect(find.byIcon(Icons.call), findsWidgets);
    });
  });

  testWidgets('زر الاتصال بدون رقم لا يطلق أي رابط', (tester) async {
    await _run(tester, 'x', (t, repo) async {
      await t.pumpWidget(wrap(repo, const AccountFormScreen()));
      await _drain(t);
      await t.tap(find.byIcon(Icons.call).first, warnIfMissed: false);
      await _drain(t);
      expect(mockLaunchLog, isEmpty);
    });
  });

  testWidgets('زر الاتصال مع رقم يطلق tel: (تطبيق الهاتف) لا جهات اتصال',
      (tester) async {
    await _run(tester, 'x', (t, repo) async {
      await t.pumpWidget(wrap(repo, const AccountFormScreen()));
      await _drain(t);
      await t.enterText(
          find.widgetWithText(TextFormField, 'اسم الحساب *'), 'عميل تجريبي');
      await t.enterText(
          find.widgetWithText(TextFormField, 'رقم الجوال'), '777123456');
      await t.pump();
      await t.tap(find.byIcon(Icons.call).first, warnIfMissed: false);
      await _drain(t);
      expect(mockLaunchLog, contains('tel:777123456'));
      expect(mockLaunchLog.any((u) => u.contains('contact')), isFalse);
    });
  });
}
