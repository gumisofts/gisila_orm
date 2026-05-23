/// build_runner [Builder] that consumes `*.gisila.yaml` schema files
/// and emits the Dart model code (`*.g.dart`) and SQL migration
/// pair (`*.up.sql` + `*.down.sql`) alongside.
library gisila.generators.schema_builder;

import 'dart:async';

import 'package:build/build.dart';
import 'package:dart_style/dart_style.dart';
import 'package:gisila_orm/generators/codegen/dart_emitter.dart';
import 'package:gisila_orm/generators/codegen/sql_emitter.dart';
import 'package:gisila_orm/generators/schema_parser.dart';

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
    final yaml = await buildStep.readAsString(input);

    final SchemaDefinition schema;
    try {
      // Pass the input asset's URI so error spans render the real
      // file path rather than `<unknown>`.
      schema = SchemaDefinition.fromYaml(yaml,
          sourceUrl: Uri.parse(input.uri.toString()));
    } on SchemaValidationException catch (e) {
      // Render the rich, span-highlighted diagnostics through
      // build_runner's logger so the user sees one block per file
      // with line numbers, carets, and hints. Re-throw to fail the
      // build cleanly.
      log.severe('\n${e.format()}');
      throw _SchemaBuildException(input.path, e);
    }

    // Dart output ----------------------------------------------------------
    final dartId = _outputId(input, '.gisila.g.dart');
    final raw = emitDart(schema);
    String formatted;
    try {
      formatted = DartFormatter(
              languageVersion: DartFormatter.latestLanguageVersion)
          .format(raw);
    } catch (_) {
      // If formatting fails (e.g. malformed generated code), still
      // write the unformatted output so the user can debug it.
      formatted = raw;
    }
    await buildStep.writeAsString(dartId, formatted);

    // SQL outputs ---------------------------------------------------------
    final upId = _outputId(input, '.gisila.up.sql');
    final downId = _outputId(input, '.gisila.down.sql');
    await buildStep.writeAsString(upId, emitUpSql(schema));
    await buildStep.writeAsString(downId, emitDownSql(schema));
  }

  /// Strips the input's full `.gisila.yaml` / `.gisila.yml` suffix and
  /// appends the requested [newExtension]. We intentionally do not use
  /// [AssetId.changeExtension] because that operates on the last `.`
  /// segment only, which would leave the `.gisila` middle segment in
  /// place and produce `foo.gisila.g.dart` outputs that mismatch the
  /// `build_extensions` declaration.
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
/// failed validation. Wraps the underlying [SchemaValidationException]
/// so callers (or build hooks) can re-render the diagnostics if they
/// captured stderr. The detailed message has already been emitted via
/// `log.severe`; this exception's [toString] returns a short, single
/// line so build_runner doesn't repeat the full report.
class _SchemaBuildException implements Exception {
  _SchemaBuildException(this.path, this.cause);
  final String path;
  final SchemaValidationException cause;

  @override
  String toString() {
    final n = cause.errors.length;
    return 'Schema validation failed for $path '
        '($n ${n == 1 ? "error" : "errors"})';
  }
}
