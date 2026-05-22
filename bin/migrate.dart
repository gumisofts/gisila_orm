#!/usr/bin/env dart
//
// gisila migration runner.
//
// Usage:
//   dart run gisila:migrate up     [--dir <path>] [--config <yaml>]
//   dart run gisila:migrate down   [--dir <path>] [--config <yaml>] [--steps N]
//   dart run gisila:migrate status [--dir <path>] [--config <yaml>]
//   dart run gisila:migrate diff   --old <path> --new <path> --name <slug> [--out <dir>]

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
  final flags = _parseFlags(args.sublist(1));

  if (command == 'diff') {
    await _runDiff(flags);
    return;
  }

  final configPath = flags['config'] ?? _defaultConfig;
  final dir = flags['dir'] ?? _defaultDir;
  final steps = int.tryParse(flags['steps'] ?? '1') ?? 1;

  final config = await DatabaseConfig.fromFile(configPath);
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
        stdout.writeln(
            'Discovered: ${discovered.length}, applied: ${applied.length}');
        for (final m in discovered) {
          final mark = appliedIds.contains(m.id) ? '[x]' : '[ ]';
          stdout.writeln('  $mark ${m.id}');
        }
        break;

      default:
        _usage();
        exit(64);
    }
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
    'gisila migrate <up|down|status|diff> '
    '[--dir <path>] [--config <yaml>] [--steps N] '
    '[--old <path>] [--new <path>] [--name <slug>] [--out <path>]',
  );
}

Future<void> _runDiff(Map<String, String> flags) async {
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

  await differ.generateMigrationFile(diff, outDir, name);
}
