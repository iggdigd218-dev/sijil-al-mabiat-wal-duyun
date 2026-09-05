import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'core/db_init.dart';
import 'core/database.dart';
import 'core/theme.dart';
import 'data/providers.dart';
import 'data/repository.dart';
import 'data/sync/sync_engine.dart';
import 'ui/home_shell.dart';
import 'ui/lock_gate.dart';
import 'ui/splash.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  initDbForPlatform();
  await initializeDateFormatting('ar');
  await initializeDateFormatting('en');

  // Repo واحد ومُهيّأ تُستخدمه كل شاشات التطبيق عبر Riverpod.
  final repo = Repo();
  await repo.initSyncInfra();
  final engine = SyncEngine(
    repo: repo,
    dbProvider: () => AppDatabase.instance.database,
  );
  await engine.start();

  var themeMode = ThemeMode.system;
  var hideBalances = false;
  try {
    final st = await repo.settings();
    themeMode = switch (st['theme']) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
    hideBalances = st['hideBalances'] == '1';
  } catch (_) {}

  runApp(ProviderScope(
    overrides: [
      repoProvider.overrideWithValue(repo),
      syncEngineProvider.overrideWithValue(engine),
      themeModeProvider.overrideWith((ref) => themeMode),
      hideBalancesProvider.overrideWith((ref) => hideBalances),
    ],
    child: const NexoraApp(),
  ));
}

class NexoraApp extends ConsumerWidget {
  const NexoraApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp(
      title: 'إدارة البيانات',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ref.watch(themeModeProvider),
      locale: const Locale('ar'),
      supportedLocales: const [Locale('ar'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      builder: (context, child) => Directionality(
        textDirection: TextDirection.rtl,
        child: child ?? const SizedBox.shrink(),
      ),
      home: const SplashScreen(),
    );
  }
}
