// bin/generate.dart
//
// 用法：
// 1) 默认读 pubspec.yaml 的 i18n_tr 配置：
//    dart run i18n_tr:generate
// 2) 指定外部配置文件（yaml/json），覆盖 pubspec：
//    dart run i18n_tr:generate --config i18n_tr_config.yaml
//
// 配置格式：
// A) pubspec.yaml
// i18n_tr:
//   project_lib: lib
//   i18n_dir: lib/i18n
//   source_file: lib/i18n/_source_text.dart
//   config_file: lib/i18n/i18n_config.dart
//   source_locale: zh_CN
//   fallback_locale: zh_CN
//   system_label: 跟随系统
//   prune_unused: false
//   migrations:
//     - from: 旧文案
//       to: 新文案
//   langs:
//     - locale: zh_CN
//       file: zh_cn.dart
//       map: zhCN
//       label: 简体中文
//     - locale: en_US
//       file: en_us.dart
//       map: enUS
//       label: English
//
// B) i18n_tr_config.yaml（同结构，顶层无需 i18n_tr 包裹）
// project_lib: lib
// i18n_dir: lib/i18n
// source_file: lib/i18n/_source_text.dart
// config_file: lib/i18n/i18n_config.dart
// source_locale: zh_CN
// fallback_locale: zh_CN
// system_label: 跟随系统
// prune_unused: false
// migrations:
//   - from: 旧文案
//     to: 新文案
// langs:
//   - locale: zh_CN
//     file: zh_cn.dart
//     map: zhCN
//     label: 简体中文

import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:crypto/crypto.dart';
import 'package:yaml/yaml.dart';

const _exitUsage = 1;
const _exitConflict = 2;
const _exitPlaceholder = 3;
const _exitStale = 4;

final RegExp _trPattern = RegExp(
  r'''tr\(\s*(['"])((?:\\.|(?!\1).)*)\1''',
  dotAll: true,
);

class GeneratorException implements Exception {
  final int exitCode;
  final String message;
  final bool useStdout;

  GeneratorException(this.exitCode, this.message, {this.useStdout = false});
}

class LangSpec {
  final String locale; // zh_CN（仅用于标识/可读）
  final String filePath; // lib/i18n/zh_cn.dart（最终路径）
  final String mapName; // zhCN
  final String label; // 简体中文

  LangSpec({
    required this.locale,
    required this.filePath,
    required this.mapName,
    required this.label,
  });
}

class I18nTrConfig {
  final String projectLib; // lib
  final String i18nDir; // lib/i18n
  final String sourceFile; // lib/i18n/_source_text.dart
  final String configFile; // lib/i18n/i18n_config.dart
  final String sourceLocale; // zh_CN
  final String fallbackLocale; // zh_CN
  final String systemLabel; // 跟随系统
  final bool pruneUnused;
  final List<MigrationSpec> migrations;
  final List<LangSpec> langs;

  I18nTrConfig({
    required this.projectLib,
    required this.i18nDir,
    required this.sourceFile,
    required this.configFile,
    required this.sourceLocale,
    required this.fallbackLocale,
    required this.systemLabel,
    required this.pruneUnused,
    required this.migrations,
    required this.langs,
  });
}

class MigrationSpec {
  final String fromText;
  final String toText;

  MigrationSpec({required this.fromText, required this.toText});
}

class LoadedConfig {
  final I18nTrConfig config;
  final bool? pruneOverride;
  final bool checkMode;

  LoadedConfig({
    required this.config,
    required this.pruneOverride,
    required this.checkMode,
  });
}

Future<void> main(List<String> args) async {
  final exitCode = await runGenerator(args);
  if (exitCode != 0) {
    exit(exitCode);
  }
}

Future<int> runGenerator(List<String> args) async {
  try {
    final loaded = await _loadConfig(args);
    final cfg = loaded.config;
    final pruneUnused = loaded.pruneOverride ?? cfg.pruneUnused;

    final foundTexts = await _scanTexts(cfg);
    stdout.writeln('🔍 找到 ${foundTexts.length} 条 tr 文案（任意语言）');

    final sourceMap = _loadSourceMap(cfg.sourceFile); // key -> text
    final langData = <LangSpec, Map<String, String>>{};
    final existingKeys = Set<String>.from(sourceMap.keys);
    final migratedTextKeys = <String, String>{};
    var migratedCount = 0;
    var prunedCount = 0;

    // 读取已有语言文件（保留已翻译内容）
    for (final lang in cfg.langs) {
      langData[lang] = _loadLangMap(lang.filePath, lang.mapName);
    }

    // 文案迁移（保留历史翻译）
    if (cfg.migrations.isNotEmpty) {
      migratedCount = _applyMigrations(
        cfg.migrations,
        sourceMap,
        langData,
        migratedTextKeys,
      );
    }

    // 生成 key + 补齐语言包
    for (final text in foundTexts) {
      final key = _keyForText(text, migratedTextKeys);

      // 校验：hash 对应的文案是否一致（防止文案变化导致复用旧 key）
      final old = sourceMap[key];
      if (old != null && old != text) {
        throw GeneratorException(
          _exitConflict,
          '❌ Hash 冲突或文案被修改: $key\n'
          '旧: $old\n'
          '新: $text\n'
          '建议：不要直接修改 tr(原文案)，或提供迁移机制。',
        );
      }

      sourceMap[key] = text;

      // 补齐各语言包缺失 key：先用原文案占位（保留可读）
      for (final lang in cfg.langs) {
        final map = langData[lang]!;
        map.putIfAbsent(key, () => text);
      }
    }

    // 可选：清理未使用 key
    if (pruneUnused) {
      final usedKeys =
          foundTexts.map((t) => _keyForText(t, migratedTextKeys)).toSet();
      final toRemove =
          sourceMap.keys.where((k) => !usedKeys.contains(k)).toList();
      for (final key in toRemove) {
        sourceMap.remove(key);
        for (final lang in cfg.langs) {
          langData[lang]!.remove(key);
        }
      }
      prunedCount = toRemove.length;
    }

    final placeholderErrors = _validatePlaceholders(cfg, sourceMap, langData);
    if (placeholderErrors.isNotEmpty) {
      throw GeneratorException(
        _exitPlaceholder,
        '❌ 占位符校验失败：\n'
        '${placeholderErrors.map((e) => '  - $e').join('\n')}',
      );
    }

    final outputs = <String, String>{};
    for (final lang in cfg.langs) {
      outputs[lang.filePath] = _buildLangFileContent(
        lang.mapName,
        langData[lang]!,
      );
    }
    outputs[cfg.sourceFile] = _buildSourceDartMapContent(sourceMap);
    outputs[cfg.configFile] = _buildRuntimeConfigContent(cfg);

    final addedCount = foundTexts
        .map((t) => _keyForText(t, migratedTextKeys))
        .where((k) => !existingKeys.contains(k))
        .length;
    stdout.writeln(
        '📦 新增 $addedCount 个 key，迁移 $migratedCount 个 key，清理 $prunedCount 个 key');
    _printMissingReport(cfg, sourceMap, langData);

    if (loaded.checkMode) {
      final staleFiles = _findStaleGeneratedFiles(outputs);
      if (staleFiles.isNotEmpty) {
        throw GeneratorException(
          _exitStale,
          '❌ 生成文件不是最新，请运行 dart run i18n_tr:generate\n'
          '${staleFiles.map((path) => '  - $path').join('\n')}',
        );
      }
      stdout.writeln('✅ --check 通过，生成文件已是最新');
      return 0;
    }

    for (final entry in outputs.entries) {
      _writeTextFile(entry.key, entry.value);
    }

    stdout.writeln('✅ 国际化语言文件 & 校验文件已更新完成');
    return 0;
  } on GeneratorException catch (e) {
    if (e.message.isNotEmpty) {
      if (e.useStdout) {
        stdout.writeln(e.message);
      } else {
        stderr.writeln(e.message);
      }
    }
    return e.exitCode;
  } on ArgParserException catch (e) {
    stderr.writeln('❌ ${e.message}');
    return _exitUsage;
  } on FormatException catch (e) {
    stderr.writeln('❌ ${e.message}');
    return _exitUsage;
  }
}

/// =====================
/// 扫描 lib 下所有 dart 文件：提取 tr("...") 文案
/// =====================
Future<Set<String>> _scanTexts(I18nTrConfig cfg) async {
  final libDir = Directory(cfg.projectLib);
  if (!libDir.existsSync()) {
    throw GeneratorException(_exitUsage, '❌ 找不到目录：${cfg.projectLib}');
  }

  final found = <String>{};

  await for (final entity in libDir.list(recursive: true, followLinks: false)) {
    if (entity is! File) continue;
    final path = entity.path;

    if (!path.endsWith('.dart')) continue;

    // 跳过 i18n 目录（避免扫描语言文件自身）
    if (_isUnderDir(path, cfg.i18nDir)) continue;

    final content = await entity.readAsString();

    final astTexts = _extractTextsFromAst(content, path);
    if (astTexts != null) {
      found.addAll(astTexts);
      continue;
    }

    for (final m in _trPattern.allMatches(content)) {
      final text = m.group(2);
      if (text == null) continue;
      final unescaped = _unescapeDartString(text);
      if (_shouldTreatAsText(unescaped)) {
        found.add(unescaped);
      }
    }
  }

  return found;
}

Set<String>? _extractTextsFromAst(String content, String path) {
  try {
    final result = parseString(
      content: content,
      path: path,
      throwIfDiagnostics: false,
    );
    final collector = _TrAstCollector();
    result.unit.visitChildren(collector);
    return collector.texts;
  } catch (_) {
    return null;
  }
}

class _TrAstCollector extends RecursiveAstVisitor<void> {
  final Set<String> texts = <String>{};

  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (node.methodName.name != 'tr') {
      return super.visitMethodInvocation(node);
    }

    final args = node.argumentList.arguments;
    if (args.isEmpty) {
      return super.visitMethodInvocation(node);
    }

    final first = args.first;
    final value = _stringLiteralValue(first);
    if (value != null && _shouldTreatAsText(value)) {
      texts.add(value);
    }

    return super.visitMethodInvocation(node);
  }
}

String? _stringLiteralValue(Expression expr) {
  if (expr is NamedExpression) {
    return _stringLiteralValue(expr.expression);
  }
  if (expr is StringInterpolation) {
    return null;
  }
  if (expr is StringLiteral) {
    final value = expr.stringValue;
    if (value == null) return null;
    return _normalizeMultilineText(value);
  }
  return null;
}

String _normalizeMultilineText(String value) {
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

bool _isUnderDir(String filePath, String dirPath) {
  final p = _normalizePath(filePath);
  final d = _normalizePath(dirPath);
  return p.startsWith('$d/');
}

/// 文案判定：不限制中文，任何语言都算；但过滤明显不是文案的
bool _shouldTreatAsText(String text) {
  final t = text.trim();
  if (t.isEmpty) return false;
  if (RegExp(r'^\d+$').hasMatch(t)) return false; // 纯数字
  if (RegExp(r'^(https?:)?//').hasMatch(t)) return false; // URL
  if (t.contains('www.')) return false;
  return true;
}

/// =====================
/// Hash Key：MD5 前 12 位（与 Python hashlib.md5 保持一致）
/// =====================
String _toHashKey(String text) {
  final bytes = utf8.encode(text);
  final digest = md5.convert(bytes).toString(); // 32位hex
  return 'h_${digest.substring(0, 12)}';
}

String _keyForText(String text, Map<String, String> migratedTextKeys) {
  return migratedTextKeys[text] ?? _toHashKey(text);
}

/// =====================
/// 读取/写入 source 文件：key -> 原始文案（Dart Map）
/// =====================
Map<String, String> _loadSourceMap(String path) {
  final file = File(path);
  if (!file.existsSync()) return {};

  if (path.endsWith('.json')) {
    final obj = jsonDecode(file.readAsStringSync());
    if (obj is! Map) return {};
    return obj.map((k, v) => MapEntry(k.toString(), v.toString()));
  }

  return _loadDartStringMap(file.readAsStringSync(), 'i18nSourceText');
}

String _buildSourceDartMapContent(Map<String, String> sourceMap) {
  final keys = sourceMap.keys.toList()..sort();
  final sorted = <String, String>{
    for (final k in keys) k: sourceMap[k]!,
  };

  final sb = StringBuffer();
  sb.writeln('const Map<String, String> i18nSourceText = {');
  for (final e in sorted.entries) {
    sb.writeln(
      "  ${_dartString(e.key)}: ${_dartString(e.value)},",
    );
  }
  sb.writeln('};\n');
  return sb.toString();
}

/// =====================
/// 读取/写入语言 Dart 文件。
/// 结构为：const Map of String to String mapName = { 'h_xxx': 'value' };
/// =====================
Map<String, String> _loadLangMap(String path, String mapName) {
  final file = File(path);
  if (!file.existsSync()) return {};

  final content = file.readAsStringSync();
  return _loadDartStringMap(content, mapName);
}

Map<String, String> _loadDartStringMap(String content, String variableName) {
  final astMap = _loadDartStringMapFromAst(content, variableName);
  if (astMap != null && astMap.isNotEmpty) return astMap;

  final reg = RegExp(
    'const\\s+Map<String,\\s*String>\\s+$variableName\\s*=\\s*\\{([\\s\\S]*?)\\};',
    multiLine: true,
  );
  final match = reg.firstMatch(content);
  if (match == null) return {};

  final body = match.group(1) ?? '';

  // 支持 \' 转义
  final entryReg = RegExp(
    r'''(['"])((?:\\.|(?!\1).)*)\1\s*:\s*(['"])((?:\\.|(?!\3).)*)\3''',
    multiLine: true,
  );

  final map = <String, String>{};
  for (final m in entryReg.allMatches(body)) {
    final k = _unescapeDartString(m.group(2) ?? '');
    final v = _unescapeDartString(m.group(4) ?? '');
    map[k] = v;
  }
  return map;
}

Map<String, String>? _loadDartStringMapFromAst(
  String content,
  String variableName,
) {
  try {
    final result = parseString(content: content, throwIfDiagnostics: false);
    for (final declaration in result.unit.declarations) {
      if (declaration is! TopLevelVariableDeclaration) continue;
      for (final variable in declaration.variables.variables) {
        if (variable.name.lexeme != variableName) continue;
        final initializer = variable.initializer;
        if (initializer is! SetOrMapLiteral || !initializer.isMap) {
          return <String, String>{};
        }
        return _stringMapFromLiteral(initializer);
      }
    }
  } catch (_) {
    return null;
  }
  return null;
}

Map<String, String> _stringMapFromLiteral(SetOrMapLiteral literal) {
  final map = <String, String>{};
  for (final element in literal.elements) {
    if (element is! MapLiteralEntry) continue;
    final key = _stringLiteralValue(element.key);
    final value = _stringLiteralValue(element.value);
    if (key == null || value == null) continue;
    map[key] = value;
  }
  return map;
}

String _buildLangFileContent(String mapName, Map<String, String> data) {
  final keys = data.keys.toList()..sort();

  final sb = StringBuffer();
  sb.writeln("const Map<String, String> $mapName = {");
  for (final k in keys) {
    sb.writeln(
      "  ${_dartString(k)}: ${_dartString(data[k] ?? '')},",
    );
  }
  sb.writeln('};\n');

  return sb.toString();
}

/// =====================
/// 生成运行期配置文件（i18n_tr/lib/i18n_config.dart）
/// =====================
String _buildRuntimeConfigContent(I18nTrConfig cfg) {
  final imports = <String>{};
  imports.add(_relativeImportPath(cfg.configFile, cfg.sourceFile));
  for (final lang in cfg.langs) {
    imports.add(_relativeImportPath(cfg.configFile, lang.filePath));
  }

  final sb = StringBuffer();
  sb.writeln(
    '// This file is automatically generated. DO NOT EDIT, all your changes would be lost.',
  );
  sb.writeln("import 'package:i18n_tr/i18n_config.dart';");
  for (final p in imports) {
    sb.writeln("import '$p';");
  }
  sb.writeln();
  sb.writeln('const I18nRuntimeConfig i18nConfig = I18nRuntimeConfig(');
  sb.writeln('  systemLabel: ${_dartString(cfg.systemLabel)},');
  sb.writeln('  sourceLocale: ${_dartStringNullable(cfg.sourceLocale)},');
  sb.writeln('  fallbackLocale: ${_dartStringNullable(cfg.fallbackLocale)},');
  sb.writeln('  sourceText: i18nSourceText,');
  sb.writeln('  langs: [');
  for (final lang in cfg.langs) {
    sb.writeln('    I18nLangDef(');
    sb.writeln('      locale: ${_dartString(lang.locale)},');
    sb.writeln('      label: ${_dartString(lang.label)},');
    sb.writeln('      map: ${lang.mapName},');
    sb.writeln('    ),');
  }
  sb.writeln('  ],');
  sb.writeln(');');

  return sb.toString();
}

void _writeTextFile(String path, String content) {
  final file = File(path);
  final dir = Directory(file.parent.path);
  if (!dir.existsSync()) dir.createSync(recursive: true);
  file.writeAsStringSync(content);
}

List<String> _findStaleGeneratedFiles(Map<String, String> outputs) {
  final stale = <String>[];
  for (final entry in outputs.entries) {
    final file = File(entry.key);
    if (!file.existsSync()) {
      stale.add(entry.key);
      continue;
    }
    if (file.readAsStringSync() != entry.value) {
      stale.add(entry.key);
    }
  }
  return stale;
}

String _relativeImportPath(String fromFile, String targetFile) {
  final fromNorm = fromFile.replaceAll('\\', '/');
  final targetNorm = targetFile.replaceAll('\\', '/');

  final fromDir = fromNorm.contains('/')
      ? fromNorm.substring(0, fromNorm.lastIndexOf('/'))
      : '';

  final fromSegs = fromDir.split('/').where((s) => s.isNotEmpty).toList();
  final toSegs = targetNorm.split('/').where((s) => s.isNotEmpty).toList();

  var i = 0;
  while (i < fromSegs.length && i < toSegs.length && fromSegs[i] == toSegs[i]) {
    i++;
  }

  final up = List.filled(fromSegs.length - i, '..');
  final down = toSegs.sublist(i);
  final parts = [...up, ...down];

  return parts.isEmpty ? targetNorm : parts.join('/');
}

String _dartString(String value) {
  return "'${_escapeDartString(value)}'";
}

String _dartStringNullable(String? value) {
  if (value == null) return 'null';
  return _dartString(value);
}

String _escapeDartString(String value) {
  return value
      .replaceAll('\\', r'\\')
      .replaceAll("'", r"\'")
      .replaceAll('\n', r'\n')
      .replaceAll('\r', r'\r')
      .replaceAll('\t', r'\t')
      .replaceAll(r'$', r'\$');
}

String _unescapeDartString(String value) {
  final sb = StringBuffer();
  for (var i = 0; i < value.length; i++) {
    final c = value[i];
    if (c != '\\') {
      sb.write(c);
      continue;
    }
    if (i == value.length - 1) {
      sb.write('\\');
      continue;
    }
    final next = value[i + 1];
    switch (next) {
      case 'n':
        sb.write('\n');
        i++;
        break;
      case 'r':
        sb.write('\r');
        i++;
        break;
      case 't':
        sb.write('\t');
        i++;
        break;
      case r'$':
        sb.write(r'$');
        i++;
        break;
      case "'":
        sb.write("'");
        i++;
        break;
      case '\\':
        sb.write('\\');
        i++;
        break;
      default:
        sb.write('\\');
        break;
    }
  }
  return sb.toString();
}

String _normalizePath(String path) {
  return File(path)
      .absolute
      .path
      .replaceAll('\\', '/')
      .replaceAll(RegExp(r'/$'), '');
}

/// =====================
/// 配置加载：支持 A(pubspec) + B(--config yaml/json)
/// =====================
Future<LoadedConfig> _loadConfig(List<String> args) async {
  final parser = ArgParser()
    ..addOption('config',
        abbr: 'c', help: '配置文件路径（yaml/json），优先级高于 pubspec.yaml')
    ..addFlag('prune', negatable: false, help: '清理未使用的 key（覆盖配置）')
    ..addFlag('check', negatable: false, help: '只校验生成文件是否最新，不写入文件')
    ..addFlag('help', abbr: 'h', negatable: false, help: '查看帮助');

  final res = parser.parse(args);

  if (res['help'] == true) {
    throw GeneratorException(0, _helpText(parser), useStdout: true);
  }

  final configPath = (res['config'] as String?)?.trim();
  if (configPath != null && configPath.isNotEmpty) {
    return LoadedConfig(
      config: _loadFromConfigFile(configPath),
      pruneOverride: res['prune'] == true ? true : null,
      checkMode: res['check'] == true,
    );
  }

  return LoadedConfig(
    config: _loadFromPubspec(),
    pruneOverride: res['prune'] == true ? true : null,
    checkMode: res['check'] == true,
  );
}

I18nTrConfig _loadFromPubspec() {
  final pubspec = File('pubspec.yaml');
  if (!pubspec.existsSync()) {
    _failWithTemplate('找不到 pubspec.yaml，且未指定 --config');
  }

  final root = loadYaml(pubspec.readAsStringSync());
  if (root is! YamlMap || root['i18n_tr'] == null) {
    _failWithTemplate('pubspec.yaml 未配置 i18n_tr，且未指定 --config');
  }

  final node = root['i18n_tr'];
  final map = _yamlToPlain(node);
  if (map is! Map<String, dynamic>) {
    _failWithTemplate('pubspec.yaml 的 i18n_tr 配置格式不正确');
  }

  return _parseConfig(map, from: 'pubspec.yaml -> i18n_tr');
}

I18nTrConfig _loadFromConfigFile(String path) {
  final f = File(path);
  if (!f.existsSync()) {
    _failWithTemplate('找不到配置文件：$path');
  }

  final text = f.readAsStringSync();
  Map<String, dynamic> map;

  if (path.endsWith('.json')) {
    final obj = jsonDecode(text);
    if (obj is! Map) {
      _failWithTemplate('配置 JSON 顶层必须是对象：$path');
    }
    map = obj.map((k, v) => MapEntry(k.toString(), v));
  } else {
    final y = loadYaml(text);
    final plain = _yamlToPlain(y);
    if (plain is! Map<String, dynamic>) {
      _failWithTemplate('配置 YAML 顶层必须是映射：$path');
    }
    map = plain;
  }

  // 允许外部文件也用 i18n_tr: {...}
  if (map.containsKey('i18n_tr') && map['i18n_tr'] is Map) {
    map = Map<String, dynamic>.from(map['i18n_tr'] as Map);
  }

  return _parseConfig(map, from: path);
}

I18nTrConfig _parseConfig(Map<String, dynamic> m, {required String from}) {
  String getStr(String k, {String? def}) {
    final v = m[k];
    if (v == null) {
      if (def != null) return def;
      throw FormatException('[$from] 缺少必填字段：$k');
    }
    return v.toString();
  }

  final projectLib = getStr('project_lib', def: 'lib');
  final i18nDir = getStr('i18n_dir', def: 'lib/i18n');
  final sourceFile = getStr('source_file', def: '$i18nDir/_source_text.dart');
  final configFile = getStr('config_file', def: '$i18nDir/i18n_config.dart');
  final sourceLocale = getStr('source_locale', def: 'zh');
  final fallbackLocale = getStr('fallback_locale', def: 'en');
  final systemLabel = getStr('system_label', def: '跟随系统');
  final pruneUnused = _getBool(m['prune_unused'], def: false);
  final migrations = _parseMigrations(m['migrations'], from: from);

  final langsRaw = m['langs'];
  if (langsRaw is! List || langsRaw.isEmpty) {
    throw FormatException('[$from] langs 必须是非空数组');
  }

  final langs = <LangSpec>[];
  for (final item in langsRaw) {
    final plain = _yamlToPlain(item);
    if (plain is! Map<String, dynamic>) {
      throw FormatException('[$from] langs 项必须是对象：$item');
    }

    final locale = (plain['locale'] ?? '').toString().trim();
    final file = (plain['file'] ?? '').toString().trim();
    final mapName = (plain['map'] ?? '').toString().trim();
    final label = (plain['label'] ?? '').toString().trim();

    if (locale.isEmpty || file.isEmpty || mapName.isEmpty) {
      throw FormatException('[$from] langs 项必须包含 locale/file/map：$plain');
    }

    final filePath =
        file.contains('/') || file.contains('\\') ? file : '$i18nDir/$file';

    langs.add(LangSpec(
      locale: locale,
      filePath: filePath,
      mapName: mapName,
      label: label.isEmpty ? locale : label,
    ));
  }

  // 简单校验：mapName 不重复 / filePath 不重复
  final mapNames = <String>{};
  final filePaths = <String>{};
  for (final l in langs) {
    if (!mapNames.add(l.mapName)) {
      throw FormatException('[$from] map 重复：${l.mapName}');
    }
    if (!filePaths.add(l.filePath)) {
      throw FormatException('[$from] file 重复：${l.filePath}');
    }
  }

  return I18nTrConfig(
    projectLib: projectLib,
    i18nDir: i18nDir,
    sourceFile: sourceFile,
    configFile: configFile,
    sourceLocale: sourceLocale,
    fallbackLocale: fallbackLocale,
    systemLabel: systemLabel,
    pruneUnused: pruneUnused,
    migrations: migrations,
    langs: langs,
  );
}

/// 将 YamlMap/YamlList 递归转换为普通 Dart Map/List（便于处理）
dynamic _yamlToPlain(dynamic node) {
  if (node is YamlMap) {
    return <String, dynamic>{
      for (final e in node.entries) e.key.toString(): _yamlToPlain(e.value),
    };
  }
  if (node is YamlList) {
    return node.map(_yamlToPlain).toList();
  }
  return node;
}

String _helpText(ArgParser parser) {
  return 'i18n_tr generator\n\n'
      '用法：\n'
      '  dart run i18n_tr:generate\n'
      '  dart run i18n_tr:generate --config i18n_tr_config.yaml\n\n'
      '${parser.usage}';
}

Never _failWithTemplate(String msg) {
  throw GeneratorException(
    _exitUsage,
    '❌ $msg\n\n'
    '你可以选择：\n\n'
    'A) 在 pubspec.yaml 添加：\n'
    'i18n_tr:\n'
    '  i18n_dir: lib/i18n\n'
    '  # source_file: lib/i18n/_source_text.dart\n'
    '  # config_file: lib/i18n/i18n_config.dart\n'
    '  source_locale: zh_CN\n'
    '  fallback_locale: en_US\n'
    '  system_label: 跟随系统\n'
    '  langs:\n'
    '    - locale: zh_CN\n'
    '      file: zh_cn.dart\n'
    '      map: zhCN\n'
    '      label: 简体中文\n'
    '    - locale: en_US\n'
    '      file: en_us.dart\n'
    '      map: enUS\n\n'
    'B) 或创建 i18n_tr_config.yaml，并运行：\n'
    'dart run i18n_tr:generate --config i18n_tr_config.yaml',
  );
}

List<MigrationSpec> _parseMigrations(dynamic node, {required String from}) {
  if (node == null) return <MigrationSpec>[];
  final plain = _yamlToPlain(node);
  if (plain is! List) {
    throw FormatException('[$from] migrations 必须是数组');
  }
  final out = <MigrationSpec>[];
  for (final item in plain) {
    if (item is! Map) {
      throw FormatException('[$from] migrations 项必须是对象：$item');
    }
    final m = Map<String, dynamic>.from(item);
    final fromText =
        (m['from'] ?? m['old'] ?? m['source'] ?? '').toString().trim();
    final toText = (m['to'] ?? m['new'] ?? m['target'] ?? '').toString().trim();
    if (fromText.isEmpty || toText.isEmpty) {
      throw FormatException('[$from] migrations 项必须包含 from/to：$item');
    }
    out.add(MigrationSpec(fromText: fromText, toText: toText));
  }
  return out;
}

bool _getBool(dynamic value, {required bool def}) {
  if (value == null) return def;
  if (value is bool) return value;
  final s = value.toString().toLowerCase();
  if (s == 'true' || s == '1' || s == 'yes' || s == 'y') return true;
  if (s == 'false' || s == '0' || s == 'no' || s == 'n') return false;
  return def;
}

int _applyMigrations(
  List<MigrationSpec> migrations,
  Map<String, String> sourceMap,
  Map<LangSpec, Map<String, String>> langData,
  Map<String, String> migratedTextKeys,
) {
  var migrated = 0;
  for (final m in migrations) {
    final oldKey =
        _findSourceKeyByText(sourceMap, m.fromText) ?? _toHashKey(m.fromText);
    final newKey = _toHashKey(m.toText);

    final oldText = sourceMap[oldKey];
    final newText = sourceMap[newKey];

    if (newKey != oldKey && newText != null && newText != m.toText) {
      throw GeneratorException(
        _exitConflict,
        '❌ 迁移冲突：$newKey 已存在不同文案\n旧: $newText\n新: ${m.toText}',
      );
    }

    if (oldText != null && oldText != m.fromText && oldText != m.toText) {
      stderr.writeln(
        '⚠️ 迁移警告：旧 key 文案不一致，跳过迁移\nkey: $oldKey\n期望: ${m.fromText}\n实际: $oldText',
      );
      continue;
    }

    if (oldText == null && newText == null) {
      stderr.writeln(
        '⚠️ 迁移警告：未找到旧文案 key，跳过迁移\nfrom: ${m.fromText}',
      );
      continue;
    }

    if (oldText == null && newText == m.toText) {
      migratedTextKeys[m.toText] = newKey;
      continue;
    }

    for (final entry in langData.entries) {
      final map = entry.value;
      final oldValue = map[oldKey];
      final newValue = newKey == oldKey ? null : map[newKey];

      if (oldValue == null) {
        map[oldKey] = newValue ?? m.toText;
      } else if (oldValue == m.fromText) {
        map[oldKey] = m.toText;
      }

      if (newKey != oldKey && newValue != null) {
        final stableValue = map[oldKey]!;
        final newValueLooksGenerated =
            newValue == m.fromText || newValue == m.toText;
        final stableValueLooksGenerated =
            stableValue == m.fromText || stableValue == m.toText;

        if (stableValueLooksGenerated && !newValueLooksGenerated) {
          map[oldKey] = newValue;
        }
        map.remove(newKey);
      }
    }

    sourceMap[oldKey] = m.toText;
    if (newKey != oldKey) {
      sourceMap.remove(newKey);
    }
    migratedTextKeys[m.toText] = oldKey;
    migrated++;
  }
  return migrated;
}

String? _findSourceKeyByText(Map<String, String> sourceMap, String text) {
  for (final entry in sourceMap.entries) {
    if (entry.value == text) {
      return entry.key;
    }
  }
  return null;
}

List<String> _validatePlaceholders(
  I18nTrConfig cfg,
  Map<String, String> sourceMap,
  Map<LangSpec, Map<String, String>> langData,
) {
  final errors = <String>[];
  final keys = sourceMap.keys.toList()..sort();

  for (final key in keys) {
    final sourceText = sourceMap[key];
    if (sourceText == null) continue;

    final expected = _placeholderNames(sourceText);
    for (final lang in cfg.langs) {
      final translated = langData[lang]?[key];
      if (translated == null) continue;

      final actual = _placeholderNames(translated);
      if (_sameStringSet(expected, actual)) continue;

      errors.add(
        '${lang.locale} $key 占位符不一致，source=${_formatSet(expected)}，'
        'actual=${_formatSet(actual)}，text=$translated',
      );
    }
  }

  return errors;
}

Set<String> _placeholderNames(String text) {
  final reg = RegExp(r'\{([A-Za-z_][A-Za-z0-9_]*)\}');
  return {
    for (final match in reg.allMatches(text)) match.group(1)!,
  };
}

bool _sameStringSet(Set<String> a, Set<String> b) {
  return a.length == b.length && a.containsAll(b);
}

String _formatSet(Set<String> values) {
  if (values.isEmpty) return '{}';
  final sorted = values.toList()..sort();
  return '{${sorted.join(', ')}}';
}

void _printMissingReport(
  I18nTrConfig cfg,
  Map<String, String> sourceMap,
  Map<LangSpec, Map<String, String>> langData,
) {
  final keys = sourceMap.keys.toList();
  if (keys.isEmpty) return;

  final nonSourceLangs =
      cfg.langs.where((l) => l.locale != cfg.sourceLocale).toList();
  if (nonSourceLangs.isEmpty) return;

  var missing = 0;
  final missingTexts = <String>[];
  for (final k in keys) {
    final src = sourceMap[k];
    if (src == null) continue;

    var anyTranslated = false;
    for (final lang in nonSourceLangs) {
      final map = langData[lang]!;
      final v = map[k];
      if (v != null && v != src) {
        anyTranslated = true;
        break;
      }
    }

    if (!anyTranslated) {
      missing++;
      missingTexts.add(src);
    }
  }

  stdout.writeln('📝 未翻译 $missing 条: [${missingTexts.join(', ')}]');
}
