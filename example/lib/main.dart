import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:i18n_tr/i18n.dart';
import 'package:i18n_tr_example/i18n/i18n_config.dart';


void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await I18n.instance.init(
    config: i18nConfig,
  );
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: I18n.instance,
      builder: (context, _) {
        return MaterialApp(
          locale: I18n.instance.locale,
          supportedLocales: I18n.instance.supportedLocales,
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: const HomePage(),
        );
      },
    );
  }
}

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    final i18n = I18n.instance;
    final mode = I18n.instance.mode;
    final modes = I18n.instance.modes;

    return Scaffold(
      appBar: AppBar(
        title: Text(tr('国际化')),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Locale: ${I18n.instance.localeKey}'),
            const SizedBox(height: 12),
            Text('Current mode: ${mode.label}'),
            const SizedBox(height: 12),

            Text(tr('你好，{name}', {'name': tr('世界')})),
            Text(tr('登录')),
            Text(tr('Logout')),
            Text(tr('キャンセル')),
            Text(tr('新增')),
            Text(tr('迁移')),
            Text(tr('清理')),
            Text(tr('''
            这是一段测试文本。
            ''')),

            const Divider(height: 32),

            Text(
              tr('当前语言'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(i18n.localeKey),

            const SizedBox(height: 16),

            Text(
              tr('选择语言'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),

            Column(
              spacing: 8,
              children: [
                for (final m in modes)
                  ElevatedButton(
                    onPressed: () => I18n.instance.change(m),
                    child: Text(m.label),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
