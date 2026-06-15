import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:i18n_tr/i18n.dart';
import 'package:i18n_tr/i18n_config.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../bin/generate.dart' as generator;

const _sourceText = <String, String>{
  'hello_key': '你好',
  'param_key': '你好，{name}',
  'fallback_key': '仅中文',
  'document_key': '这是一段测试文本。',
};

const _testConfig = I18nRuntimeConfig(
  systemLabel: 'System',
  sourceLocale: 'zh_CN',
  fallbackLocale: 'zh_CN',
  sourceText: _sourceText,
  langs: [
    I18nLangDef(
      locale: 'zh_CN',
      label: '简体中文',
      map: {
        'hello_key': '你好',
        'param_key': '你好，{name}',
        'fallback_key': '仅中文',
        'document_key': '这是一段测试文本。',
      },
    ),
    I18nLangDef(
      locale: 'en_US',
      label: 'English',
      map: {
        'hello_key': 'Hello',
        'param_key': 'Hello, {name}',
        'document_key': 'This is a test paragraph.',
      },
    ),
  ],
);

const _alternateConfig = I18nRuntimeConfig(
  systemLabel: 'System',
  sourceLocale: 'zh_CN',
  fallbackLocale: 'zh_CN',
  sourceText: {'title_key': '标题'},
  langs: [
    I18nLangDef(
      locale: 'zh_CN',
      label: '简体中文',
      map: {'title_key': '标题'},
    ),
  ],
);

const _hyphenLocaleConfig = I18nRuntimeConfig(
  systemLabel: 'System',
  sourceLocale: 'zh-CN',
  fallbackLocale: 'en-US',
  sourceText: {'hello_key': '你好'},
  langs: [
    I18nLangDef(
      locale: 'zh-CN',
      label: '简体中文',
      map: {'hello_key': '你好'},
    ),
    I18nLangDef(
      locale: 'en-US',
      label: 'English',
      map: {'hello_key': 'Hello'},
    ),
    I18nLangDef(
      locale: 'zh-Hans-CN',
      label: '简体中文',
      map: {'hello_key': '简体'},
    ),
  ],
);

const _emptyConfig = I18nRuntimeConfig(
  systemLabel: 'System',
  sourceLocale: null,
  fallbackLocale: null,
  sourceText: {},
  langs: [],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await I18n.instance.resetForTest();
  });

  test('translates text, replaces params, and falls back to fallback locale',
      () async {
    await I18n.instance.init(config: _testConfig, languageName: 'en_US');

    expect(tr('你好'), 'Hello');
    expect(tr('你好，{name}', {'name': 'Codex'}), 'Hello, Codex');
    expect(
      tr('''
            这是一段测试文本。
            '''),
      'This is a test paragraph.',
    );
    expect(tr('仅中文'), '仅中文');
    expect(I18n.instance.locale, const Locale('en', 'US'));
    expect(
      I18n.instance.supportedLocales,
      const [Locale('zh', 'CN'), Locale('en', 'US')],
    );
  });

  test('persists changed language mode', () async {
    await I18n.instance.init(config: _testConfig);

    final englishMode =
        I18n.instance.modes.firstWhere((mode) => mode.localeKey == 'en_US');
    await I18n.instance.change(englishMode);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('i18n_language_mode'), 'en_US');
    expect(I18n.instance.localeKey, 'en_US');
  });

  test('persists changed language mode after explicit initial language',
      () async {
    await I18n.instance.init(config: _testConfig, languageName: 'zh_CN');

    final englishMode =
        I18n.instance.modes.firstWhere((mode) => mode.localeKey == 'en_US');
    await I18n.instance.change(englishMode);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('i18n_language_mode'), 'en_US');
  });

  test('guards repeated init unless force is explicit', () async {
    await I18n.instance.init(config: _testConfig, languageName: 'en_US');

    await expectLater(
      I18n.instance.init(config: _alternateConfig),
      throwsA(isA<StateError>()),
    );

    await I18n.instance.init(
      config: _alternateConfig,
      languageName: 'zh_CN',
      force: true,
    );

    expect(tr('标题'), '标题');
  });

  test('normalizes hyphen locale keys and unknown modes use fallback',
      () async {
    await I18n.instance
        .init(config: _hyphenLocaleConfig, languageName: 'fr-FR');

    expect(I18n.instance.localeKey, 'en_US');
    expect(I18n.instance.locale, const Locale('en', 'US'));
    expect(tr('你好'), 'Hello');
    expect(
      I18n.instance.supportedLocales,
      const [
        Locale('zh', 'CN'),
        Locale('en', 'US'),
        Locale.fromSubtags(
          languageCode: 'zh',
          scriptCode: 'Hans',
          countryCode: 'CN',
        ),
      ],
    );
  });

  test('normalizes script locale language names', () async {
    await I18n.instance.init(
      config: _hyphenLocaleConfig,
      languageName: 'zh-hans-cn',
    );

    expect(I18n.instance.localeKey, 'zh_Hans_CN');
    expect(
      I18n.instance.locale,
      const Locale.fromSubtags(
        languageCode: 'zh',
        scriptCode: 'Hans',
        countryCode: 'CN',
      ),
    );
    expect(tr('你好'), '简体');
  });

  test('empty runtime config fails without poisoning later init', () async {
    await expectLater(
      I18n.instance.init(config: _emptyConfig),
      throwsA(isA<StateError>()),
    );
    expect(I18n.isInit, isFalse);

    await I18n.instance.init(config: _testConfig, languageName: 'en_US');
    expect(tr('你好'), 'Hello');
  });

  test('generator keeps migrated key stable and scans single character text',
      () async {
    final originalCurrent = Directory.current;
    final root = Directory.systemTemp.createTempSync('i18n_tr_generator_test_');

    try {
      Directory.current = root;
      Directory('lib/i18n').createSync(recursive: true);

      final oldKey = _hashKey('旧文案');
      final newKey = _hashKey('新文案');
      final singleCharKey = _hashKey('是');

      File('lib/main.dart').writeAsStringSync("""
import 'package:i18n_tr/i18n.dart';

void main() {
  tr('新文案');
  tr('是');
}
""");

      File('lib/i18n/_source_text.dart').writeAsStringSync("""
const Map<String, String> i18nSourceText = {
  '$oldKey': '旧文案',
};
""");

      File('lib/i18n/zh_cn.dart').writeAsStringSync("""
const Map<String, String> zhCN = {
  '$oldKey': '旧翻译',
};
""");

      File('lib/i18n/en_us.dart').writeAsStringSync("""
const Map<String, String> enUS = {
  '$oldKey': 'Old translation',
};
""");

      File('i18n_tr_config.yaml').writeAsStringSync("""
i18n_dir: lib/i18n
source_locale: zh_CN
fallback_locale: zh_CN
langs:
  - locale: zh_CN
    label: 简体中文
    file: zh_cn.dart
    map: zhCN
  - locale: en_US
    label: English
    file: en_us.dart
    map: enUS
prune_unused: true
migrations:
  - from: 旧文案
    to: 新文案
""");

      final code = await generator.runGenerator(
        ['--config', 'i18n_tr_config.yaml'],
      );
      expect(code, 0);

      final sourceText = File('lib/i18n/_source_text.dart').readAsStringSync();
      final enText = File('lib/i18n/en_us.dart').readAsStringSync();

      expect(sourceText, contains("'$oldKey': '新文案'"));
      expect(sourceText, isNot(contains(newKey)));
      expect(sourceText, contains("'$singleCharKey': '是'"));
      expect(enText, contains("'$oldKey': 'Old translation'"));

      final checkCode = await generator.runGenerator(
        ['--config', 'i18n_tr_config.yaml', '--check'],
      );
      expect(checkCode, 0);

      File('lib/main.dart').writeAsStringSync("""
import 'package:i18n_tr/i18n.dart';

void main() {
  tr('新文案');
  tr('是');
  tr('新增');
}
""");

      final staleCheckCode = await generator.runGenerator(
        ['--config', 'i18n_tr_config.yaml', '--check'],
      );
      expect(staleCheckCode, 4);
      expect(
        File('lib/i18n/_source_text.dart').readAsStringSync(),
        isNot(contains(_hashKey('新增'))),
      );
    } finally {
      Directory.current = originalCurrent;
      root.deleteSync(recursive: true);
    }
  });

  test('generator fails when translated placeholders do not match source',
      () async {
    final originalCurrent = Directory.current;
    final root =
        Directory.systemTemp.createTempSync('i18n_tr_placeholder_test_');

    try {
      Directory.current = root;
      Directory('lib/i18n').createSync(recursive: true);

      final key = _hashKey('你好，{name}');

      File('lib/main.dart').writeAsStringSync("""
import 'package:i18n_tr/i18n.dart';

void main() {
  tr('你好，{name}');
}
""");

      File('lib/i18n/_source_text.dart').writeAsStringSync("""
const Map<String, String> i18nSourceText = {
  '$key': '你好，{name}',
};
""");

      File('lib/i18n/zh_cn.dart').writeAsStringSync("""
const Map<String, String> zhCN = {
  '$key': '你好，{name}',
};
""");

      File('lib/i18n/en_us.dart').writeAsStringSync("""
const Map<String, String> enUS = {
  '$key': 'Hello',
};
""");

      File('i18n_tr_config.yaml').writeAsStringSync("""
i18n_dir: lib/i18n
source_locale: zh_CN
fallback_locale: zh_CN
langs:
  - locale: zh_CN
    label: 简体中文
    file: zh_cn.dart
    map: zhCN
  - locale: en_US
    label: English
    file: en_us.dart
    map: enUS
""");

      final code = await generator.runGenerator(
        ['--config', 'i18n_tr_config.yaml'],
      );
      expect(code, 3);
    } finally {
      Directory.current = originalCurrent;
      root.deleteSync(recursive: true);
    }
  });

  test('generator preserves translations from double quoted dart maps',
      () async {
    final originalCurrent = Directory.current;
    final root = Directory.systemTemp.createTempSync('i18n_tr_ast_map_test_');

    try {
      Directory.current = root;
      Directory('lib/i18n').createSync(recursive: true);

      final key = _hashKey('你好');

      File('lib/main.dart').writeAsStringSync("""
import 'package:i18n_tr/i18n.dart';

void main() {
  tr('你好');
}
""");

      File('lib/i18n/_source_text.dart').writeAsStringSync('''
const Map<String, String> i18nSourceText = {
  "$key": "你好",
};
''');

      File('lib/i18n/zh_cn.dart').writeAsStringSync('''
const Map<String, String> zhCN = {
  "$key": "你好",
};
''');

      File('lib/i18n/en_us.dart').writeAsStringSync('''
const Map<String, String> enUS = {
  "$key": "Hello",
};
''');

      File('i18n_tr_config.yaml').writeAsStringSync("""
i18n_dir: lib/i18n
source_locale: zh_CN
fallback_locale: zh_CN
langs:
  - locale: zh_CN
    label: 简体中文
    file: zh_cn.dart
    map: zhCN
  - locale: en_US
    label: English
    file: en_us.dart
    map: enUS
""");

      final code = await generator.runGenerator(
        ['--config', 'i18n_tr_config.yaml'],
      );
      expect(code, 0);

      final enText = File('lib/i18n/en_us.dart').readAsStringSync();
      expect(enText, contains("'$key': 'Hello'"));
    } finally {
      Directory.current = originalCurrent;
      root.deleteSync(recursive: true);
    }
  });

  test('generator returns usage code instead of exiting on missing config',
      () async {
    final originalCurrent = Directory.current;
    final root =
        Directory.systemTemp.createTempSync('i18n_tr_missing_config_test_');

    try {
      Directory.current = root;

      final code = await generator.runGenerator(const []);
      expect(code, 1);
    } finally {
      Directory.current = originalCurrent;
      root.deleteSync(recursive: true);
    }
  });
}

String _hashKey(String text) {
  final digest = md5.convert(utf8.encode(text)).toString();
  return 'h_${digest.substring(0, 12)}';
}
