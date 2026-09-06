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

  // التقاط أي خطأ غير مُعالج في إطار الـ UI بدل تعليق الشاشة بيضاء.
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    debugPrint('FlutterError: ${details.exceptionAsString()}\n${details.stack}');
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    debugPrint('Uncaught error: $error\n$stack');
    return true;
  };

  // Repo واحد ومُهيّأ تُستخدمه كل شاشات التطبيق عبر Riverpod.
  // كل خطوة بمهلة قصوى حتى لا يعلق الإقلاع للأبد في حالة فساد قاعدة البيانات أو انسداد المقبس.
  final repo = Repo();
  try {
    await repo.initSyncInfra().timeout(const Duration(seconds: 8));
  } catch (e) {
    debugPrint('initSyncInfra timeout/error: $e');
  }
  SyncEngine engine;
  try {
    engine = SyncEngine(
      repo: repo,
      dbProvider: () => AppDatabase.instance.database,
    );
    await engine.start().timeout(const Duration(seconds: 6));
  } catch (e) {
    debugPrint('engine.start timeout/error: $e');
    engine = SyncEngine(
      repo: repo,
      dbProvider: () => AppDatabase.instance.database,
    );
  }

  var themeMode = ThemeMode.system;
  var hideBalances = false;
  Map<String, String> initialSettings = const {};
  try {
    initialSettings = await repo.settings().timeout(const Duration(seconds: 4));
    themeMode = switch (initialSettings['theme']) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
    hideBalances = initialSettings['hideBalances'] == '1';
  } catch (e) {
    debugPrint('initial settings failed: $e');
  }

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
