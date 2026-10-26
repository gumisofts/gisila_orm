#!/usr/bin/env dart
//
// Discovers all `*.gisila.yaml` files, merges them into one project schema,
// emits a single Dart + up/down SQL bundle, and auto-generates an incremental
// migration by diffing against the previous merged snapshot.
//
// A migration that would lose data (dropped tables/columns/enums, narrowing
// type changes) is refused unless --allow-destructive is passed.

import 'dart:io';

import 'package:gisila_orm/generators/project_codegen.dart';
import 'package:gisila_orm/generators/schema_parser.dart';
import 'package:gisila_orm/migrations/schema_differ.dart';

Future<void> main(List<String> args) async {
  // Legacy build_runner passthrough: if the user passes --build-runner,
  // keep the old shim behaviour for single-file workflows that still rely
  // on SchemaBuilder. Default path is project merge codegen.
  if (args.contains('--build-runner')) {
    final extra = args.where((a) => a != '--build-runner').toList();
    final passDelete = !extra.contains('--no-delete');
    if (passDelete && !extra.contains('--delete-conflicting-outputs')) {
      extra.add('--delete-conflicting-outputs');
    }
    final result = await Process.start(
      'dart',
      [
        'run',
        'build_runner',
        'build',
        ...extra.where((a) => a != '--no-delete'),
      ],
      mode: ProcessStartMode.inheritStdio,
    );
    exit(await result.exitCode);
  }

  final root = Directory.current;
  try {
    final result = await generateProjectSchema(root);
    final relDart = _relativePath(root.path, result.dartFile.path);
    final relUp = _relativePath(root.path, result.upSqlFile.path);
    stdout.writeln(
      'Generated ${result.sourceFiles.length} schema file(s) → $relDart, $relUp',
    );

    final migration = await generateProjectIncrementalMigration(
      root,
      schema: result.schema,
      allowDestructive: args.contains('--allow-destructive'),
    );
    if (migration != null) {
      stdout.writeln('Auto incremental migration generated: $migration');
    }
  } on SchemaValidationException catch (e) {
    stderr.writeln(e.format());
    exit(1);
  } on DestructiveMigrationException catch (e) {
    stderr.writeln(e);
    exit(1);
  } catch (e, st) {
    stderr.writeln('Codegen failed: $e');
    stderr.writeln(st);
    exit(1);
  }
}

String _relativePath(String rootPath, String absolutePath) {
  final normalizedRoot = rootPath.endsWith(Platform.pathSeparator)
      ? rootPath
      : '$rootPath${Platform.pathSeparator}';
  if (absolutePath.startsWith(normalizedRoot)) {
    return absolutePath.substring(normalizedRoot.length);
  }
  return absolutePath;
}
