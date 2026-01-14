import 'zh_cn.dart';

class I18nLangDef {
  final String locale;
  final String label;
  final Map<String, String> map;

  const I18nLangDef({
    required this.locale,
    required this.label,
    required this.map,
  });
}

class I18nRuntimeConfig {
  final String systemLabel;
  final String? sourceLocale;
  final String? fallbackLocale;
  final Map<String, String> sourceText;
  final List<I18nLangDef> langs;

  const I18nRuntimeConfig({
    required this.systemLabel,
    required this.sourceLocale,
    required this.fallbackLocale,
    required this.sourceText,
    required this.langs,
  });
}

const I18nRuntimeConfig i18nConfig = I18nRuntimeConfig(
  systemLabel: '跟随系统',
  sourceLocale: 'zh_CN',
  fallbackLocale: 'zh_CN',
  sourceText: {},
  langs: [
    I18nLangDef(
      locale: 'zh_CN',
      label: '简体中文',
      map: zhCN,
    ),
  ],
);
