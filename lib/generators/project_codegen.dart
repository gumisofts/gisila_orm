/// Project-level schema discovery, merge, and codegen.
///
/// Discovers every `*.gisila.yaml` under a package root, merges them into
/// one [SchemaDefinition], and emits a single Dart + up/down SQL bundle.
library gisila.generators.project_codegen;

import 'dart:io';

import 'package:dart_style/dart_style.dart';
import 'package:gisila_orm/database/postgres/exceptions/exceptions.dart';
import 'package:gisila_orm/generators/codegen/dart_emitter.dart';
import 'package:gisila_orm/generators/codegen/sql_emitter.dart';
import 'package:gisila_orm/generators/schema_parser.dart';
import 'package:gisila_orm/migrations/schema_differ.dart';
import 'package:path/path.dart' as p;

/// Roots scanned for schema files (relative to the package root).
const projectSchemaRoots = ['lib', 'test', 'example'];

const projectSnapshotRelativePath =
    '.gisila/schema_snapshots/project.gisila.yaml';

/// Result of [generateProjectSchema].
class ProjectCodegenResult {
  final SchemaDefinition schema;
  final List<File> sourceFiles;
  final Directory outputDir;
  final String stem;
  final File dartFile;
  final File upSqlFile;
  final File downSqlFile;

  const ProjectCodegenResult({
    required this.schema,
    required this.sourceFiles,
    required this.outputDir,
    required this.stem,
    required this.dartFile,
    required this.upSqlFile,
    required this.downSqlFile,
  });

  bool get isMultiFile => sourceFiles.length > 1;
}

/// Discover `*.gisila.yaml` / `*.gisila.yml` under [root].
///
/// Scans [projectSchemaRoots] when present; skips `.gisila/` snapshots.
/// Results are sorted by relative path for deterministic merges.
Future<List<File>> discoverSchemaFiles(Directory root) async {
  final files = <File>[];
  final rootPath = p.normalize(root.absolute.path);

  for (final name in projectSchemaRoots) {
    final dir = Directory(p.join(rootPath, name));
    if (!await dir.exists()) continue;
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      if (!_isSchemaYamlPath(entity.path)) continue;
      if (_shouldSkipSchemaPath(entity.path, rootPath)) continue;
      files.add(entity);
    }
  }

  files.sort((a, b) =>
      p.relative(a.path, from: rootPath).compareTo(
            p.relative(b.path, from: rootPath),
          ));
  return files;
}

/// Merge project schemas and write the Dart + SQL bundle under [root].
///
/// - One schema file → emit beside it using that file's stem
///   (`blog.gisila.g.dart`, …).
/// - Two or more → emit `schema.gisila.*` under `lib/models/` (created if
///   needed) or under the common parent of the discovered files when
///   `lib/` is absent.
Future<ProjectCodegenResult> generateProjectSchema(Directory root) async {
  final files = await discoverSchemaFiles(root);
  final schema = await SchemaDefinition.fromProject(files);

  final outputDir = await _resolveOutputDir(root, files);
  await outputDir.create(recursive: true);

  final stem = files.length == 1 ? _schemaStem(files.first.path) : 'schema';
  final dartFile = File(p.join(outputDir.path, '$stem.gisila.g.dart'));
  final upSqlFile = File(p.join(outputDir.path, '$stem.gisila.up.sql'));
  final downSqlFile = File(p.join(outputDir.path, '$stem.gisila.down.sql'));

  final rawDart = emitDart(schema);
  String formatted;
  try {
    formatted =
        DartFormatter(languageVersion: DartFormatter.latestLanguageVersion)
            .format(rawDart);
  } catch (_) {
    formatted = rawDart;
  }
  await dartFile.writeAsString(formatted);

  try {
    await upSqlFile.writeAsString(emitUpSql(schema));
  } on DefaultValueException {
    rethrow;
  }
  await downSqlFile.writeAsString(emitDownSql(schema));

  return ProjectCodegenResult(
    schema: schema,
    sourceFiles: files,
    outputDir: outputDir,
    stem: stem,
    dartFile: dartFile,
    upSqlFile: upSqlFile,
    downSqlFile: downSqlFile,
  );
}

/// Diff the merged project schema against the previous snapshot and write
/// an incremental migration when there are changes.
///
/// Snapshot path: [projectSnapshotRelativePath].
/// Returns the migration name when a file was written, otherwise `null`.
Future<String?> generateProjectIncrementalMigration(
  Directory root, {
  SchemaDefinition? schema,
  Directory? migrationsDir,
}) async {
  final files = await discoverSchemaFiles(root);
  final current = schema ?? await SchemaDefinition.fromProject(files);
  final snapshotFile = File(p.join(root.path, projectSnapshotRelativePath));
  await snapshotFile.parent.create(recursive: true);

  final yaml = emitSchemaYaml(current);

  if (!await snapshotFile.exists()) {
    await snapshotFile.writeAsString(yaml);
    return null;
  }

  final oldSchema = SchemaDefinition.fromYaml(
    await snapshotFile.readAsString(),
    sourceUrl: snapshotFile.uri,
  );
  final differ = SchemaDiffer();
  final diff = differ.compareSchemas(oldSchema, current);
  if (diff.isEmpty) {
    await snapshotFile.writeAsString(yaml);
    return null;
  }

  final outDir = migrationsDir ??
      await _resolveMigrationsDir(root, files);
  await outDir.create(recursive: true);

  const migrationName = 'auto_project_changes';
  await differ.generateMigrationFile(diff, outDir.path, migrationName);
  await snapshotFile.writeAsString(yaml);
  return migrationName;
}

Future<Directory> _resolveOutputDir(Directory root, List<File> files) async {
  if (files.length == 1) {
    return files.first.parent;
  }

  final libDir = Directory(p.join(root.path, 'lib'));
  final modelsDir = Directory(p.join(root.path, 'lib', 'models'));
  if (await modelsDir.exists() || await libDir.exists()) {
    return modelsDir;
  }
  return _commonParentDir(files);
}

Future<Directory> _resolveMigrationsDir(
  Directory root,
  List<File> files,
) async {
  final outputDir = await _resolveOutputDir(root, files);
  return Directory(p.join(outputDir.path, 'migrations'));
}

Directory _commonParentDir(List<File> files) {
  if (files.isEmpty) {
    return Directory.current;
  }
  var common = p.normalize(files.first.parent.absolute.path);
  for (final file in files.skip(1)) {
    final dir = p.normalize(file.parent.absolute.path);
    common = _longestCommonPrefixPath(common, dir);
  }
  return Directory(common.isEmpty ? files.first.parent.path : common);
}

String _longestCommonPrefixPath(String a, String b) {
  final aParts = p.split(a);
  final bParts = p.split(b);
  final out = <String>[];
  final n = aParts.length < bParts.length ? aParts.length : bParts.length;
  for (var i = 0; i < n; i++) {
    if (aParts[i] != bParts[i]) break;
    out.add(aParts[i]);
  }
  if (out.isEmpty) return a;
  return p.joinAll(out);
}

bool _isSchemaYamlPath(String path) {
  final lower = path.toLowerCase();
  return lower.endsWith('.gisila.yaml') || lower.endsWith('.gisila.yml');
}

bool _shouldSkipSchemaPath(String path, String rootPath) {
  final rel = p.relative(p.normalize(path), from: rootPath);
  final parts = p.split(rel);
  if (parts.contains('.gisila')) return true;
  // Snapshot filename written under lib by mistake.
  final base = p.basename(path).toLowerCase();
  if (base == 'project.gisila.yaml') return true;
  return false;
}

String _schemaStem(String path) {
  final file = p.basename(path);
  final lower = file.toLowerCase();
  if (lower.endsWith('.gisila.yaml')) {
    return file.substring(0, file.length - '.gisila.yaml'.length);
  }
  if (lower.endsWith('.gisila.yml')) {
    return file.substring(0, file.length - '.gisila.yml'.length);
  }
  return p.basenameWithoutExtension(file);
}
