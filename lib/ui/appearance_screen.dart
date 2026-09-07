// شاشة المظهر المستقلة: السمة (فاتح/داكن/حسب النظام)، إخفاء الأرصدة،
// حجم الخط، والأصوات/الاهتزاز — كل إعدادات العرض والتغذية الراجعة في مكان واحد.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/sfx.dart';
import '../data/providers.dart';

class AppearanceScreen extends ConsumerWidget {
  const AppearanceScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.watch(settingsProvider).valueOrNull ?? {};
    final mode = ref.watch(themeModeProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('المظهر والأصوات')),
      body: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.brightness_6_outlined),
                  title: const Text('السمة'),
                  subtitle: Text(switch (mode) {
                    ThemeMode.light => 'فاتح',
                    ThemeMode.dark => 'داكن',
                    ThemeMode.system => 'حسب النظام',
                  }),
                  trailing: SegmentedButton<ThemeMode>(
                    segments: const [
                      ButtonSegment(
                          value: ThemeMode.light,
                          icon: Icon(Icons.light_mode_outlined)),
                      ButtonSegment(
                          value: ThemeMode.system,
                          icon: Icon(Icons.brightness_auto_outlined)),
                      ButtonSegment(
                          value: ThemeMode.dark,
                          icon: Icon(Icons.dark_mode_outlined)),
                    ],
                    selected: {mode},
                    showSelectedIcon: false,
                    onSelectionChanged: (s) async {
                      final v = s.first;
                      ref.read(themeModeProvider.notifier).state = v;
                      await ref
                          .read(repoProvider)
                          .setSetting('theme', v.name);
                    },
                  ),
                ),
                const Divider(height: 1),
                SwitchListTile(
                  secondary: const Icon(Icons.visibility_off_outlined),
                  title: const Text('إخفاء الأرصدة افتراضيًا'),
                  subtitle: const Text('تظهر الأرصدة كنقاط حتى تكشفها'),
                  value: ref.watch(hideBalancesProvider),
                  onChanged: (v) async {
                    ref.read(hideBalancesProvider.notifier).state = v;
                    await ref
                        .read(repoProvider)
                        .setSetting('hideBalances', v ? '1' : '0');
                  },
                ),
                const Divider(height: 1),
                SwitchListTile(
                  secondary: const Icon(Icons.format_size),
                  title: const Text('خط أكبر في لوحة التحكم'),
                  subtitle: const Text('تكبير الأرقام والعناوين'),
                  value: (st['bigText'] ?? '1') == '1',
                  onChanged: (v) async {
                    await ref
                        .read(repoProvider)
                        .setSetting('bigText', v ? '1' : '0');
                    ref.invalidate(settingsProvider);
                  },
                ),
                const Divider(height: 1),
                SwitchListTile(
                  secondary: const Icon(Icons.volume_up_outlined),
                  title: const Text('الأصوات'),
                  subtitle: const Text('نغمات النجاح والخطأ والأزرار'),
                  value: (st['sfxSound'] ?? '1') == '1',
                  onChanged: (v) async {
                    await ref
                        .read(repoProvider)
                        .setSetting('sfxSound', v ? '1' : '0');
                    Sfx.applySettings(
                        sound: v, haptic: (st['sfxHaptic'] ?? '1') == '1');
                    if (v) Sfx.pop();
                    ref.invalidate(settingsProvider);
                  },
                ),
                const Divider(height: 1),
                SwitchListTile(
                  secondary: const Icon(Icons.vibration_outlined),
                  title: const Text('الاهتزاز'),
                  subtitle: const Text('ردود اهتزازية عند الحفظ والدفع'),
                  value: (st['sfxHaptic'] ?? '1') == '1',
                  onChanged: (v) async {
                    await ref
                        .read(repoProvider)
                        .setSetting('sfxHaptic', v ? '1' : '0');
                    Sfx.applySettings(
                        sound: (st['sfxSound'] ?? '1') == '1', haptic: v);
                    if (v) Sfx.success();
                    ref.invalidate(settingsProvider);
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
