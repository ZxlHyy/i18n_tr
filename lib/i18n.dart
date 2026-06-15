import 'dart:ui';

import 'package:flutter/material.dart';
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
    String? fallbackLocale,
  }) {
    final normalizedName = I18n.normalizeLocaleKey(name);
    final normalizedFallback = I18n.normalizeLocaleKey(fallbackLocale);
    if (normalizedName == null || normalizedName == 'system') {
      return LanguageMode.system(systemLabel);
    }

    final match = langs.firstWhere(
      (l) => l.locale == normalizedName,
      orElse: () => langs.firstWhere(
        (l) => l.locale == normalizedFallback,
        orElse: () => langs.first,
      ),
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

  SharedPreferences? prefs;

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
  bool _isObservingSystemLocale = false;

  LanguageMode get mode => _mode;

  String get localeKey => _localeKey;

  Locale get locale => _toLocale(_localeKey);

  List<LanguageMode> get modes => _modes;

  /// ✅ Flutter 所需 supportedLocales
  List<Locale> get supportedLocales => _langMaps.keys.map(_toLocale).toList();

  static String? normalizeLocaleKey(String? key) {
    final value = key?.trim();
    if (value == null || value.isEmpty) return null;
    final parts =
        value.split(RegExp(r'[-_]')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return null;
    if (parts.length == 1) return parts.first.toLowerCase();

    final normalized = <String>[parts[0].toLowerCase()];
    for (var i = 1; i < parts.length; i++) {
      final part = parts[i];
      if (part.length == 4) {
        normalized.add(
          part.substring(0, 1).toUpperCase() + part.substring(1).toLowerCase(),
        );
      } else {
        normalized.add(part.toUpperCase());
      }
    }
    return normalized.join('_');
  }

  /// =====================
  /// 初始化（App 启动）
  /// =====================
  Future<void> init({
    String? languageName,
    I18nRuntimeConfig? config,
    bool force = false,
  }) async {
    if (isInit && !force) {
      if (config != null && !identical(config, _runtimeConfig)) {
        throw StateError(
          'I18n has already been initialized. '
          'Pass force: true to reconfigure it explicitly.',
        );
      }
      return;
    }
    if (config != null) {
      _applyRuntimeConfig(config);
    }
    isInit = true;
    prefs ??= await SharedPreferences.getInstance();
    final name = languageName ?? prefs!.getString(_spKey);
    _mode = LanguageMode.fromName(
      name,
      _config.langs,
      systemLabel: _config.systemLabel,
      fallbackLocale: _fallbackLocale,
    );
    _localeKey = _resolveLocaleKey(_mode);
    _sourceValueToKey = _buildValueToKey(_runtimeConfig.sourceText);
    if (!_isObservingSystemLocale) {
      WidgetsBinding.instance.addObserver(_SystemLocaleObserver.instance);
      _isObservingSystemLocale = true;
    }
  }

  void _applyRuntimeConfig(I18nRuntimeConfig config) {
    _runtimeConfig = config;
    _config = _configFromRuntime(config);
    if (_config.langs.isEmpty) {
      throw StateError('I18n config must include at least one language.');
    }
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

    if (prefs != null) {
      await prefs!.setString(_spKey, mode.name);
    }
    notifyListeners();
  }

  void _handleSystemLocaleChanged() {
    if (!_mode.isSystem) return;
    final next = _resolveLocaleKey(_mode);
    if (next == _localeKey) return;
    _localeKey = next;
    notifyListeners();
  }

  @visibleForTesting
  Future<void> resetForTest() async {
    if (_isObservingSystemLocale) {
      WidgetsBinding.instance.removeObserver(_SystemLocaleObserver.instance);
      _isObservingSystemLocale = false;
    }
    isInit = false;
    prefs = null;
    _runtimeConfig = i18nConfig;
    _config = _configFromRuntime(_runtimeConfig);
    _langMaps = _buildLangMaps(_config);
    _sourceLocale = _resolveSourceLocale(_config);
    _fallbackLocale = _resolveFallbackLocale(_config, _sourceLocale);
    _sourceValueToKey = {};
    _modes = _buildModes(_config);
    _mode = LanguageMode.system(_config.systemLabel);
    _localeKey = _config.fallbackLocale ?? _config.langs.first.locale;
  }

  /// =====================
  /// 翻译
  /// =====================
  String tr(String input, [Map<String, dynamic>? params]) {
    final normalizedInput = _normalizeText(input);
    final key = _sourceValueToKey[normalizedInput] ?? normalizedInput;

    final langMap = _langMaps[_localeKey] ??
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
    final scriptCode = locale.scriptCode;
    final countryCode = locale.countryCode;
    if (scriptCode != null && scriptCode.isNotEmpty) {
      if (countryCode != null && countryCode.isNotEmpty) {
        final exact = '${langCode}_${scriptCode}_$countryCode';
        if (_langMaps.containsKey(exact)) {
          return exact;
        }
      }
      final scriptOnly = '${langCode}_$scriptCode';
      if (_langMaps.containsKey(scriptOnly)) {
        return scriptOnly;
      }
    }
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
    if (parts.length >= 3) {
      return Locale.fromSubtags(
        languageCode: parts[0],
        scriptCode: parts[1],
        countryCode: parts[2],
      );
    }
    if (parts.length == 2 && parts[1].length == 4) {
      return Locale.fromSubtags(languageCode: parts[0], scriptCode: parts[1]);
    }
    return parts.length >= 2 ? Locale(parts[0], parts[1]) : Locale(parts[0]);
  }

  static Map<String, LangMap> _buildLangMaps(I18nConfig config) {
    return {for (final l in config.langs) l.locale: l.map};
  }

  static Map<String, String> _buildValueToKey(LangMap sourceMap) {
    return {for (final e in sourceMap.entries) _normalizeText(e.value): e.key};
  }

  static String _normalizeText(String value) {
    if (!value.contains('\n')) {
      return value.trim();
    }
    final lines = value.split('\n').map((l) => l.trim()).toList();
    while (lines.isNotEmpty && lines.first.isEmpty) {
      lines.removeAt(0);
    }
    while (lines.isNotEmpty && lines.last.isEmpty) {
      lines.removeLast();
    }
    return lines.join('\n');
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

class _SystemLocaleObserver with WidgetsBindingObserver {
  const _SystemLocaleObserver._();

  static const _SystemLocaleObserver instance = _SystemLocaleObserver._();

  @override
  void didChangeLocales(List<Locale>? locales) {
    I18n.instance._handleSystemLocaleChanged();
  }
}

I18nConfig _configFromRuntime(I18nRuntimeConfig runtime) {
  final i18nLang = runtime.langs;
  final langs = <I18nLang>[
    for (final l in i18nLang)
      I18nLang(
        locale: I18n.normalizeLocaleKey(l.locale) ?? l.locale,
        label: l.label,
        map: l.map,
      ),
  ];

  if (langs.isEmpty) {
    throw StateError('I18n config must include at least one language.');
  }

  return I18nConfig(
    langs: langs,
    sourceLocale: I18n.normalizeLocaleKey(runtime.sourceLocale),
    fallbackLocale: I18n.normalizeLocaleKey(runtime.fallbackLocale),
    systemLabel: runtime.systemLabel,
  );
}
