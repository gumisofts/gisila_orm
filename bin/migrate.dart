#!/usr/bin/env dart
//
// gisila migration runner.
//
// Usage:
//   dart run gisila_orm:migrate up     [--dir <path>] [--config <yaml>]
//   dart run gisila_orm:migrate down   [--dir <path>] [--config <yaml>] [--steps N]
//   dart run gisila_orm:migrate status [--dir <path>] [--config <yaml>]
//   dart run gisila_orm:migrate diff   --old <path> --new <path> --name <slug> [--out <dir>]
//                                      [--allow-destructive]
//
// Connection: prefers DATABASE_URL (and optional database.yaml overlays) via
// DatabaseConfig.fromEnvironment — required for file-less deploys (Gisila Panel).

import 'dart:io';

import 'package:gisila_orm/gisila.dart';
import 'package:gisila_orm/generators/schema_parser.dart';

const _defaultDir = 'lib';
const _defaultConfig = 'database.yaml';
const _defaultDiffOutputDir = 'lib/migrations';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    _usage();
    exit(64);
  }

  final command = args.first;
  final allowDestructive = args.contains('--allow-destructive');
  final flags = _parseFlags(
      args.sublist(1).where((a) => a != '--allow-destructive').toList());

  if (command == 'diff') {
    await _runDiff(flags, allowDestructive: allowDestructive);
    return;
  }

  final configPath = flags['config'] ?? _defaultConfig;
  final dir = flags['dir'] ?? _defaultDir;
  final steps = int.tryParse(flags['steps'] ?? '1') ?? 1;

  // DATABASE_URL (and DB_* overrides) win over --config YAML.
  final config = await DatabaseConfig.fromEnvironment(configFile: configPath);
  if (Platform.environment.containsKey('DATABASE_URL')) {
    stdout.writeln('Using DATABASE_URL from environment.');
  } else if (File(configPath).existsSync()) {
    stdout.writeln(
      'DATABASE_URL not set — using $configPath. '
      'Set DATABASE_URL for panel/production deploys.',
    );
  } else {
    stderr.writeln(
      'No DATABASE_URL and no $configPath found. '
      'Export DATABASE_URL or create a database.yaml.',
    );
    exit(64);
  }

  final db = await Database.connect(config);
  final manager = MigrationManager(db);

  try {
    final discovered = await manager.discoverIn(dir);
    switch (command) {
      case 'up':
        final result = await manager.up(discovered);
        if (result.applied.isEmpty) {
          stdout.writeln('Nothing to apply. Database is up to date.');
        } else {
          stdout.writeln(
              'Applied ${result.applied.length} migration(s) in batch ${result.batch}:');
          for (final m in result.applied) {
            stdout.writeln('  - ${m.id}');
          }
        }
        break;

      case 'down':
        final result = await manager.down(discovered: discovered, steps: steps);
        if (result.rolledBack.isEmpty) {
          stdout.writeln('Nothing to roll back.');
        } else {
          stdout
              .writeln('Rolled back ${result.rolledBack.length} migration(s):');
          for (final m in result.rolledBack) {
            stdout.writeln('  - ${m.id}');
          }
        }
        break;

      case 'status':
        final applied = await manager.listApplied();
        final appliedIds = applied.map((a) => a.id).toSet();
        final edited = (await manager.editedSinceApplied(discovered)).toSet();
        stdout.writeln(
            'Discovered: ${discovered.length}, applied: ${applied.length}');
        for (final m in discovered) {
          final mark = appliedIds.contains(m.id) ? '[x]' : '[ ]';
          final note =
              edited.contains(m.id) ? '  (edited after it was applied)' : '';
          stdout.writeln('  $mark ${m.id}$note');
        }
        break;

      default:
        _usage();
        exit(64);
    }
  } on MigrationChecksumException catch (e) {
    stderr.writeln(e);
    exitCode = 1;
  } finally {
    await db.close();
  }
}

Map<String, String> _parseFlags(List<String> argv) {
  final out = <String, String>{};
  for (var i = 0; i < argv.length; i++) {
    final a = argv[i];
    if (a.startsWith('--') && i + 1 < argv.length) {
      out[a.substring(2)] = argv[i + 1];
      i++;
    }
  }
  return out;
}

void _usage() {
  stdout.writeln(
    'gisila_orm migrate <up|down|status|diff> '
    '[--dir <path>] [--config <yaml>] [--steps N] '
    '[--old <path>] [--new <path>] [--name <slug>] [--out <path>] '
    '[--allow-destructive]',
  );
}

Future<void> _runDiff(Map<String, String> flags,
    {required bool allowDestructive}) async {
  final oldPath = flags['old'];
  final newPath = flags['new'];
  final name = flags['name'];
  final outDir = flags['out'] ?? _defaultDiffOutputDir;

  if (oldPath == null || newPath == null || name == null) {
    stderr.writeln(
      'Missing required flags for `diff`: '
      '--old <path> --new <path> --name <slug>',
    );
    _usage();
    exit(64);
  }

  final oldSchema = await SchemaDefinition.fromFile(oldPath);
  final newSchema = await SchemaDefinition.fromFile(newPath);

  final differ = SchemaDiffer();
  final diff = differ.compareSchemas(oldSchema, newSchema);
  if (diff.isEmpty) {
    stdout.writeln('No schema changes detected. No migration generated.');
    return;
  }

  try {
    await differ.generateMigrationFile(diff, outDir, name,
        allowDestructive: allowDestructive);
  } on DestructiveMigrationException catch (e) {
    stderr.writeln(e);
    exit(1);
  }
}
