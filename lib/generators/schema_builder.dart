/// build_runner [Builder] that consumes `*.gisila.yaml` schema files.
///
/// **Single-file packages:** emits Dart + SQL beside the input stem
/// (`blog.gisila.g.dart`, …), matching historical behaviour.
///
/// **Multi-file packages:** does not emit (build_runner cannot write a
/// shared `schema.gisila.*` bundle from multiple inputs). Use
/// `dart run gisila_orm:generate` instead, which merges all schemas via
/// [generateProjectSchema].
library gisila.generators.schema_builder;

import 'dart:async';

import 'package:build/build.dart';
import 'package:dart_style/dart_style.dart';
import 'package:gisila_orm/database/postgres/exceptions/exceptions.dart';
import 'package:gisila_orm/generators/codegen/dart_emitter.dart';
import 'package:gisila_orm/generators/codegen/sql_emitter.dart';
import 'package:gisila_orm/generators/schema_parser.dart';
import 'package:glob/glob.dart';

/// Factory referenced from `build.yaml`.
Builder schemaBuilder(BuilderOptions _) => SchemaBuilder();

class SchemaBuilder implements Builder {
  @override
  Map<String, List<String>> get buildExtensions => const {
        '.gisila.yaml': [
          '.gisila.g.dart',
          '.gisila.up.sql',
          '.gisila.down.sql',
        ],
        '.gisila.yml': [
          '.gisila.g.dart',
          '.gisila.up.sql',
          '.gisila.down.sql',
        ],
      };

  @override
  Future<void> build(BuildStep buildStep) async {
    final input = buildStep.inputId;

    final assets = await buildStep
        .findAssets(Glob('**.gisila.yaml'))
        .where((id) => !_isSnapshotAsset(id.path))
        .toList();
    final ymlAssets = await buildStep
        .findAssets(Glob('**.gisila.yml'))
        .where((id) => !_isSnapshotAsset(id.path))
        .toList();
    final all = [...assets, ...ymlAssets]
      ..sort((a, b) => a.path.compareTo(b.path));

    if (all.length > 1) {
      // Only the lexicographically first input logs once; others no-op.
      if (input == all.first) {
        log.info(
          'Multiple *.gisila.yaml files detected (${all.length}). '
          'build_runner cannot emit a shared project bundle; run '
          '`dart run gisila_orm:generate` (see project_codegen.dart).',
        );
      }
      return;
    }

    // Single-file: merge API still used so behaviour matches generate.
    final yaml = await buildStep.readAsString(input);
    final SchemaDefinition schema;
    try {
      schema = SchemaDefinition.fromYaml(
        yaml,
        sourceUrl: Uri.parse(input.uri.toString()),
      );
    } on SchemaValidationException catch (e) {
      log.severe('\n${e.format()}');
      throw _SchemaBuildException(input.path, e);
    }

    final dartId = _outputId(input, '.gisila.g.dart');
    final raw = emitDart(schema);
    String formatted;
    try {
      formatted =
          DartFormatter(languageVersion: DartFormatter.latestLanguageVersion)
              .format(raw);
    } catch (_) {
      formatted = raw;
    }
    await buildStep.writeAsString(dartId, formatted);

    final upId = _outputId(input, '.gisila.up.sql');
    final downId = _outputId(input, '.gisila.down.sql');
    String upSql;
    try {
      upSql = emitUpSql(schema);
    } on DefaultValueException catch (e) {
      log.severe('\nerror[invalid_default]: ${e.msg}\n --> ${input.path}');
      throw _SchemaBuildException.withMessage(input.path, e.msg);
    }
    await buildStep.writeAsString(upId, upSql);
    await buildStep.writeAsString(downId, emitDownSql(schema));
  }

  bool _isSnapshotAsset(String path) {
    final lower = path.toLowerCase();
    return lower.contains('/.gisila/') ||
        lower.endsWith('/project.gisila.yaml');
  }

  /// Strips the input's full `.gisila.yaml` / `.gisila.yml` suffix and
  /// appends the requested [newExtension].
  AssetId _outputId(AssetId input, String newExtension) {
    final path = input.path;
    final lower = path.toLowerCase();
    String basePath;
    if (lower.endsWith('.gisila.yaml')) {
      basePath = path.substring(0, path.length - '.gisila.yaml'.length);
    } else if (lower.endsWith('.gisila.yml')) {
      basePath = path.substring(0, path.length - '.gisila.yml'.length);
    } else {
      basePath = path;
    }
    return AssetId(input.package, '$basePath$newExtension');
  }
}

/// Raised when [SchemaBuilder] aborts a build because a schema file
/// failed validation (or, via [withMessage], because SQL emission hit
/// an invalid `default:` value).
class _SchemaBuildException implements Exception {
  _SchemaBuildException(this.path, this.cause) : _shortMessage = null;

  _SchemaBuildException.withMessage(this.path, String message)
      : cause = null,
        _shortMessage = message;

  final String path;
  final SchemaValidationException? cause;
  final String? _shortMessage;

  @override
  String toString() {
    if (_shortMessage != null) {
      return 'Schema build failed for $path: $_shortMessage';
    }
    final n = cause!.errors.length;
    return 'Schema validation failed for $path '
        '($n ${n == 1 ? "error" : "errors"})';
  }
}
