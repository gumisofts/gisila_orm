/// Runtime executor for gisila migrations.
///
/// A [MigrationManager] discovers `*.up.sql` / `*.down.sql` pairs on
/// disk, tracks which ones have been applied via the
/// `gisila_migrations` table, and can apply or roll back a batch
/// transactionally through a [Database].
library gisila.migrations.migration_manager;

import 'dart:async';
import 'dart:io';

import 'package:gisila_orm/database/postgres/core/connections.dart';
import 'package:gisila_orm/database/postgres/exceptions/exceptions.dart';

/// One discovered migration on disk: an up SQL plus an optional down
/// SQL with the same prefix.
class Migration {
  /// Stable identifier, normally the file's base name (e.g.
  /// `20260101_create_users` or `blog.gisila`).
  final String id;

  /// SQL applied when migrating up. Typically multi-statement.
  final String upSql;

  /// SQL applied when rolling back. May be empty if no down SQL was
  /// provided alongside the up file.
  final String downSql;

  /// Source path of the up SQL file (informational).
  final String? sourcePath;

  const Migration({
    required this.id,
    required this.upSql,
    this.downSql = '',
    this.sourcePath,
  });
}

/// One row from `gisila_migrations` describing a previously applied
/// migration.
class AppliedMigration {
  final String id;
  final DateTime appliedAt;
  final int batch;

  const AppliedMigration({
    required this.id,
    required this.appliedAt,
    required this.batch,
  });
}

/// Outcome returned by [MigrationManager.up] / [MigrationManager.down].
class MigrationResult {
  final List<Migration> applied;
  final List<Migration> rolledBack;
  final int batch;

  const MigrationResult({
    this.applied = const [],
    this.rolledBack = const [],
    this.batch = 0,
  });
}

class MigrationManager {
  final Database _db;
  final String _trackingTable;

  /// Build a manager that talks to [database] and tracks state in the
  /// configured [trackingTable] (default `gisila_migrations`).
  MigrationManager(
    Database database, {
    String trackingTable = 'gisila_migrations',
  })  : _db = database,
        _trackingTable = trackingTable;

  /// Ensure the tracking table exists. Idempotent.
  ///
  /// Uses `BIGSERIAL PRIMARY KEY` (Postgres-native) and `$n`
  /// placeholders throughout - no SQLite-style SQL leaks here.
  Future<void> ensureSchema() async {
    final sql = '''
      CREATE TABLE IF NOT EXISTS "$_trackingTable" (
        "id"         BIGSERIAL PRIMARY KEY,
        "migration"  VARCHAR(255) NOT NULL UNIQUE,
        "batch"      INTEGER      NOT NULL,
        "applied_at" TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP
      );
    ''';
    await _db.execute(sql);
  }

  /// Read every applied migration, oldest-first.
  Future<List<AppliedMigration>> listApplied() async {
    await ensureSchema();
    final rows = await _db.execute(
      'SELECT "migration", "applied_at", "batch" FROM "$_trackingTable" '
      'ORDER BY "id" ASC',
    );
    return [
      for (final row in rows)
        AppliedMigration(
          id: row.toColumnMap()['migration'] as String,
          appliedAt: row.toColumnMap()['applied_at'] as DateTime,
          batch: row.toColumnMap()['batch'] as int,
        ),
    ];
  }

  /// Discover all migrations in [directory]. Files ending in
  /// `.up.sql` are paired with same-prefix `.down.sql` files.
  Future<List<Migration>> discoverIn(String directory) async {
    final dir = Directory(directory);
    if (!await dir.exists()) {
      throw FileSystemException('Migrations directory not found', directory);
    }
    final entries = await dir.list(recursive: true).toList();
    final files = entries.whereType<File>().toList()
      ..sort((a, b) => a.path.compareTo(b.path));

    final upFiles = files.where((f) => f.path.endsWith('.up.sql'));
    final result = <Migration>[];
    for (final up in upFiles) {
      final base = up.path.substring(0, up.path.length - '.up.sql'.length);
      final id = _idFromPath(base);
      final downPath = '$base.down.sql';
      final downFile = File(downPath);
      result.add(Migration(
        id: id,
        upSql: await up.readAsString(),
        downSql: await downFile.exists() ? await downFile.readAsString() : '',
        sourcePath: up.path,
      ));
    }
    return result;
  }

  /// Apply every pending migration from [discovered] in order.
  /// Each migration runs in its own transaction so a failure stops
  /// the batch but leaves prior migrations safely committed.
  Future<MigrationResult> up(List<Migration> discovered) async {
    await ensureSchema();
    final applied = await listApplied();
    final appliedIds = applied.map((m) => m.id).toSet();
    final pending =
        discovered.where((m) => !appliedIds.contains(m.id)).toList();
    if (pending.isEmpty) {
      return const MigrationResult();
    }

    final nextBatch = applied.isEmpty
        ? 1
        : (applied.map((m) => m.batch).reduce((a, b) => a > b ? a : b) + 1);

    final ranThis = <Migration>[];
    for (final migration in pending) {
      await _db.transaction((tx) async {
        final upSqls = migration.upSql
            .split(';')
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty);
        for (final sql in upSqls) {
          await tx.execute(sql);
        }

        await tx.execute(
          'INSERT INTO "$_trackingTable" ("migration", "batch") '
          'VALUES (\$1, \$2)',
          parameters: [migration.id, nextBatch],
        );
      });
      ranThis.add(migration);
    }
    return MigrationResult(applied: ranThis, batch: nextBatch);
  }

  /// Roll back the most recently applied batch (or every batch if
  /// [steps] exceeds the total number of batches recorded). Migrations
  /// in a batch are reverted in reverse order.
  Future<MigrationResult> down({
    required List<Migration> discovered,
    int steps = 1,
  }) async {
    await ensureSchema();
    final applied = await listApplied();
    if (applied.isEmpty || steps <= 0) {
      return const MigrationResult();
    }

    // Group by batch, descending.
    final byBatch = <int, List<AppliedMigration>>{};
    for (final m in applied) {
      byBatch.putIfAbsent(m.batch, () => []).add(m);
    }
    final batches = byBatch.keys.toList()..sort((a, b) => b.compareTo(a));
    final batchesToReverse = batches.take(steps).toList();

    final byId = {for (final m in discovered) m.id: m};
    final rolled = <Migration>[];
    int? lastBatch;

    for (final batch in batchesToReverse) {
      final inBatch = byBatch[batch]!.toList()
        ..sort((a, b) => b.appliedAt.compareTo(a.appliedAt));
      lastBatch = batch;
      for (final applied in inBatch) {
        final migration = byId[applied.id];
        if (migration == null) {
          throw MigrationRollbackException(
            'Cannot roll back migration "${applied.id}": file not found '
            'in discovered set. Pass the original migration directory '
            'when calling down().',
          );
        }
        if (migration.downSql.trim().isEmpty) {
          throw MigrationRollbackException(
            'Cannot roll back migration "${applied.id}": no down SQL '
            'was found alongside its up file.',
          );
        }
        await _db.transaction((tx) async {
          final downSqls = migration.downSql
              .split(';')
              .map((s) => s.trim())
              .where((s) => s.isNotEmpty);
          for (final sql in downSqls) {
            await tx.execute(sql);
          }
          await tx.execute(
            'DELETE FROM "$_trackingTable" WHERE "migration" = \$1',
            parameters: [applied.id],
          );
        });
        rolled.add(migration);
      }
    }
    return MigrationResult(rolledBack: rolled, batch: lastBatch ?? 0);
  }

  String _idFromPath(String basePath) {
    final slash = basePath.lastIndexOf(Platform.pathSeparator);
    return slash < 0 ? basePath : basePath.substring(slash + 1);
  }
}
