#!/usr/bin/env dart
//
// Runs `build_runner` and auto-generates incremental migrations by
// diffing each current schema against its last generated snapshot.

import 'dart:io';

import 'package:gisila/generators/schema_parser.dart';
import 'package:gisila/migrations/schema_differ.dart';

const _snapshotRoot = '.gisila/schema_snapshots';

Future<void> main(List<String> args) async {
  final extra = args.toList();
  final passDelete = !extra.contains('--no-delete');
  if (passDelete && !extra.contains('--delete-conflicting-outputs')) {
    extra.add('--delete-conflicting-outputs');
  }

  final result = await Process.start(
    'dart',
    ['run', 'build_runner', 'build', ...extra.where((a) => a != '--no-delete')],
    mode: ProcessStartMode.inheritStdio,
  );
  final code = await result.exitCode;
  if (code != 0) exit(code);

  await _generateIncrementalDiffs();
  exit(0);
}

Future<void> _generateIncrementalDiffs() async {
  final root = Directory.current;
  final snapshotDir = Directory('${root.path}/$_snapshotRoot');
  await snapshotDir.create(recursive: true);

  final schemaFiles = await _discoverSchemaFiles(root);
  final differ = SchemaDiffer();

  for (final schemaFile in schemaFiles) {
    final relPath = _relativePath(root.path, schemaFile.path);
    final snapshotPath = '${snapshotDir.path}/$relPath';
    final snapshotFile = File(snapshotPath);
    await snapshotFile.parent.create(recursive: true);

    if (!await snapshotFile.exists()) {
      await snapshotFile.writeAsString(await schemaFile.readAsString());
      continue;
    }

    final oldSchema = await SchemaDefinition.fromFile(snapshotFile.path);
    final newSchema = await SchemaDefinition.fromFile(schemaFile.path);
    final diff = differ.compareSchemas(oldSchema, newSchema);
    if (diff.isEmpty) {
      await snapshotFile.writeAsString(await schemaFile.readAsString());
      continue;
    }

    final schemaStem = _schemaStem(relPath);
    final migrationName = 'auto_${_toSnakeCase(schemaStem)}_changes';
    final outDir = '${schemaFile.parent.path}/migrations';
    await differ.generateMigrationFile(diff, outDir, migrationName);

    stdout.writeln('Auto incremental migration generated for $relPath');
    await snapshotFile.writeAsString(await schemaFile.readAsString());
  }
}

Future<List<File>> _discoverSchemaFiles(Directory root) async {
  final files = <File>[];
  await for (final entity in root.list(recursive: true, followLinks: false)) {
    if (entity is! File) continue;
    final path = entity.path.toLowerCase();
    if (path.endsWith('.gisila.yaml') || path.endsWith('.gisila.yml')) {
      if (path.contains('/.gisila/')) continue;
      files.add(entity);
    }
  }
  files.sort((a, b) => a.path.compareTo(b.path));
  return files;
}

String _relativePath(String rootPath, String absolutePath) {
  final normalizedRoot =
      rootPath.endsWith(Platform.pathSeparator) ? rootPath : '$rootPath${Platform.pathSeparator}';
  if (absolutePath.startsWith(normalizedRoot)) {
    return absolutePath.substring(normalizedRoot.length);
  }
  return absolutePath;
}

String _schemaStem(String path) {
  final file = path.split(Platform.pathSeparator).last;
  final lower = file.toLowerCase();
  if (lower.endsWith('.gisila.yaml')) {
    return file.substring(0, file.length - '.gisila.yaml'.length);
  }
  if (lower.endsWith('.gisila.yml')) {
    return file.substring(0, file.length - '.gisila.yml'.length);
  }
  return file;
}

String _toSnakeCase(String value) => value
    .replaceAllMapped(RegExp(r'[A-Z]'), (m) => '_${m.group(0)!.toLowerCase()}')
    .replaceAll(RegExp(r'[^a-zA-Z0-9_]+'), '_')
    .replaceAll(RegExp(r'_+'), '_')
    .replaceAll(RegExp(r'^_'), '')
    .replaceAll(RegExp(r'_$'), '');
