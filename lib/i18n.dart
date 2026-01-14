import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:i18n_tr/zh_cn.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'i18n_config.dart';

/// =====================
/// 语言模式
/// =====================
class LanguageMode {
  final String name;
  final String label;
  final String? localeKey;

  const LanguageMode._(this.name, this.label, this.localeKey);

  factory LanguageMode.system([String label = '跟随系统']) {
    return LanguageMode._('system', label, null);
  }

  factory LanguageMode.locale(I18nLang lang) {
    return LanguageMode._(lang.locale, lang.label, lang.locale);
  }

  bool get isSystem => localeKey == null;

  static LanguageMode fromName(
    String? name,
    List<I18nLang> langs, {
    required String systemLabel,
  }) {
    if (name == null || name.isEmpty || name == 'system') {
      return LanguageMode.system(systemLabel);
    }

    final match = langs.firstWhere(
      (l) => l.locale == name,
      orElse: () => langs.first,
    );
    return LanguageMode.locale(match);
  }
}

/// =====================
/// 对外方法
/// =====================
String tr(String key, [Map<String, dynamic>? params]) {
  return I18n.instance.tr(key, params);
}

typedef LangMap = Map<String, String>;

class I18nLang {
  final String locale;
  final String label;
  final LangMap map;

  const I18nLang({required this.locale, required this.map, String? label})
    : label = label ?? locale;
}

class I18nConfig {
  final List<I18nLang> langs;
  final String? sourceLocale;
  final String? fallbackLocale;
  final String systemLabel;

  const I18nConfig({
    required this.langs,
    this.sourceLocale,
    this.fallbackLocale,
    this.systemLabel = '跟随系统',
  });
}

/// =====================
/// I18n 核心
/// =====================
class I18n extends ChangeNotifier {
  I18n._();

  static final I18n instance = I18n._();

  static bool isInit = false;

  late final SharedPreferences prefs;

  static const _spKey = 'i18n_language_mode';

  late I18nRuntimeConfig _runtimeConfig = i18nConfig;
  late I18nConfig _config = _configFromRuntime(_runtimeConfig);
  late Map<String, LangMap> _langMaps = _buildLangMaps(_config);
  late String _sourceLocale = _resolveSourceLocale(_config);
  late String _fallbackLocale = _resolveFallbackLocale(_config, _sourceLocale);
  Map<String, String> _sourceValueToKey = {};
  late List<LanguageMode> _modes = _buildModes(_config);

  late LanguageMode _mode = LanguageMode.system(_config.systemLabel);
  late String _localeKey = _config.fallbackLocale ?? _config.langs.first.locale;

  LanguageMode get mode => _mode;

  String get localeKey => _localeKey;

  Locale get locale => _toLocale(_localeKey);

  List<LanguageMode> get modes => _modes;

  /// ✅ Flutter 所需 supportedLocales
  List<Locale> get supportedLocales => _langMaps.keys.map(_toLocale).toList();

  /// =====================
  /// 初始化（App 启动）
  /// =====================
  Future<void> init({
    String? themeModeName,
    I18nRuntimeConfig? config,
  }) async {
    if (isInit) return;
    isInit = true;
    if (config != null) {
      _applyRuntimeConfig(config);
    }
    var name = themeModeName;
    if (name == null) {
      prefs = await SharedPreferences.getInstance();
      name = prefs.getString(_spKey);
    }
    _mode = LanguageMode.fromName(
      name,
      _config.langs,
      systemLabel: _config.systemLabel,
    );
    _localeKey = _resolveLocaleKey(_mode);
    _sourceValueToKey = _buildValueToKey(_runtimeConfig.sourceText);
  }

  void _applyRuntimeConfig(I18nRuntimeConfig config) {
    _runtimeConfig = config;
    _config = _configFromRuntime(config);
    _langMaps = _buildLangMaps(_config);
    _sourceLocale = _resolveSourceLocale(_config);
    _fallbackLocale = _resolveFallbackLocale(_config, _sourceLocale);
    _modes = _buildModes(_config);
  }

  /// =====================
  /// 切换语言
  /// =====================
  Future<void> change(LanguageMode mode) async {
    _mode = mode;
    _localeKey = _resolveLocaleKey(mode);

    prefs.setString(_spKey, mode.name);
    notifyListeners();
  }

  /// =====================
  /// 翻译
  /// =====================
  String tr(String input, [Map<String, dynamic>? params]) {
    final key = _sourceValueToKey[input] ?? input;

    final langMap =
        _langMaps[_localeKey] ??
        _langMaps[_fallbackLocale] ??
        _langMaps.values.first;

    var text = langMap[key] ?? _langMaps[_fallbackLocale]?[key] ?? input;

    if (params != null) {
      for (final e in params.entries) {
        text = text.replaceAll('{${e.key}}', e.value.toString());
      }
    }
    return text;
  }

  /// =====================
  /// locale 解析
  /// =====================
  String _resolveLocaleKey(LanguageMode mode) {
    if (!mode.isSystem) {
      return mode.localeKey!;
    }
    return _normalizeSystemLocale(PlatformDispatcher.instance.locale);
  }

  String _normalizeSystemLocale(Locale locale) {
    final langCode = locale.languageCode;
    final countryCode = locale.countryCode;
    if (countryCode != null && countryCode.isNotEmpty) {
      final exact = '${langCode}_$countryCode';
      if (_langMaps.containsKey(exact)) {
        return exact;
      }
    }

    return _langMaps.keys.firstWhere(
      (k) => k.split('_').first == langCode,
      orElse: () => _fallbackLocale,
    );
  }

  static Locale _toLocale(String key) {
    final parts = key.split('_');
    return Locale(parts[0], parts[1]);
  }

  static Map<String, LangMap> _buildLangMaps(I18nConfig config) {
    return {for (final l in config.langs) l.locale: l.map};
  }

  static Map<String, String> _buildValueToKey(LangMap sourceMap) {
    return {for (final e in sourceMap.entries) e.value: e.key};
  }

  static String _resolveSourceLocale(I18nConfig config) {
    final requested = config.sourceLocale;
    if (requested != null && config.langs.any((l) => l.locale == requested)) {
      return requested;
    }
    return config.langs.first.locale;
  }

  static String _resolveFallbackLocale(I18nConfig config, String sourceLocale) {
    final requested = config.fallbackLocale;
    if (requested != null && config.langs.any((l) => l.locale == requested)) {
      return requested;
    }
    return sourceLocale;
  }

  static List<LanguageMode> _buildModes(I18nConfig config) {
    return [
      LanguageMode.system(config.systemLabel),
      for (final l in config.langs) LanguageMode.locale(l),
    ];
  }

}

I18nConfig _configFromRuntime(I18nRuntimeConfig runtime) {
  final i18nLang = runtime.langs;
  final langs = <I18nLang>[
    for (final l in i18nLang)
      I18nLang(locale: l.locale, label: l.label, map: l.map),
  ];

  if (langs.isEmpty) {
    return const I18nConfig(
      langs: [I18nLang(locale: 'zh_CN', label: '简体中文', map: zhCN)],
      sourceLocale: 'zh_CN',
      fallbackLocale: 'zh_CN',
      systemLabel: '跟随系统',
    );
  }

  return I18nConfig(
    langs: langs,
    sourceLocale: runtime.sourceLocale,
    fallbackLocale: runtime.fallbackLocale,
    systemLabel: runtime.systemLabel,
  );
}
