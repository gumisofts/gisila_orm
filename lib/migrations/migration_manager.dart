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
        for (final sql in splitSqlStatements(migration.upSql)) {
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
          for (final sql in splitSqlStatements(migration.downSql)) {
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

/// Split a multi-statement SQL script into executable statements.
///
/// Scans the script one character at a time, tracking whether it is inside a
/// string literal, a quoted identifier, or a comment, so that only top-level
/// semicolons terminate a statement. Both forms of naive splitting get this
/// wrong: splitting on every `;` breaks on a semicolon inside a comment or a
/// literal, while stripping everything after the first `--` on a line mangles
/// values such as `'cargo build --release'`.
///
/// Comments are dropped from the output. Bare `BEGIN` / `COMMIT` wrappers are
/// skipped because [MigrationManager] already runs each migration inside its
/// own transaction.
List<String> splitSqlStatements(String sql) {
  final statements = <String>[];
  final buffer = StringBuffer();

  void flush() {
    final statement = buffer.toString().trim();
    buffer.clear();
    if (statement.isEmpty) return;
    final upper = statement.toUpperCase();
    if (upper == 'BEGIN' || upper == 'COMMIT') return;
    statements.add(statement);
  }

  var i = 0;
  while (i < sql.length) {
    final char = sql[i];

    if (char == '-' && i + 1 < sql.length && sql[i + 1] == '-') {
      final newline = sql.indexOf('\n', i);
      i = newline < 0 ? sql.length : newline;
      buffer.write(' ');
      continue;
    }

    if (char == '/' && i + 1 < sql.length && sql[i + 1] == '*') {
      // Block comments nest in PostgreSQL, unlike in the SQL standard.
      var depth = 1;
      i += 2;
      while (i < sql.length && depth > 0) {
        if (sql[i] == '/' && i + 1 < sql.length && sql[i + 1] == '*') {
          depth++;
          i += 2;
        } else if (sql[i] == '*' && i + 1 < sql.length && sql[i + 1] == '/') {
          depth--;
          i += 2;
        } else {
          i++;
        }
      }
      buffer.write(' ');
      continue;
    }

    if (char == r'$') {
      final tag = _dollarQuoteTag(sql, i);
      if (tag != null) {
        final close = sql.indexOf(tag, i + tag.length);
        final end = close < 0 ? sql.length : close + tag.length;
        buffer.write(sql.substring(i, end));
        i = end;
        continue;
      }
    }

    if (char == "'") {
      // In an E'…' string a backslash escapes the next character, so a
      // trailing \' does not close the literal.
      final isEscapeString = i > 0 &&
          (sql[i - 1] == 'e' || sql[i - 1] == 'E') &&
          (i == 1 || !_isIdentifierChar(sql[i - 2]));
      buffer.write(char);
      i++;
      while (i < sql.length) {
        final inner = sql[i];
        if (isEscapeString && inner == r'\' && i + 1 < sql.length) {
          buffer.write(sql.substring(i, i + 2));
          i += 2;
          continue;
        }
        if (inner == "'") {
          if (i + 1 < sql.length && sql[i + 1] == "'") {
            buffer.write("''");
            i += 2;
            continue;
          }
          buffer.write(inner);
          i++;
          break;
        }
        buffer.write(inner);
        i++;
      }
      continue;
    }

    if (char == '"') {
      buffer.write(char);
      i++;
      while (i < sql.length) {
        final inner = sql[i];
        if (inner == '"') {
          if (i + 1 < sql.length && sql[i + 1] == '"') {
            buffer.write('""');
            i += 2;
            continue;
          }
          buffer.write(inner);
          i++;
          break;
        }
        buffer.write(inner);
        i++;
      }
      continue;
    }

    if (char == ';') {
      flush();
      i++;
      continue;
    }

    buffer.write(char);
    i++;
  }

  flush();
  return statements;
}

/// Return the dollar-quote delimiter starting at [start] (`$$` or `$tag$`), or
/// null when the `$` begins something else — most often a `$1` placeholder.
String? _dollarQuoteTag(String sql, int start) {
  var i = start + 1;
  while (i < sql.length && sql[i] != r'$') {
    if (!_isIdentifierChar(sql[i])) return null;
    i++;
  }
  if (i >= sql.length) return null;
  return sql.substring(start, i + 1);
}

bool _isIdentifierChar(String char) {
  final code = char.codeUnitAt(0);
  return (code >= 0x30 && code <= 0x39) || // 0-9
      (code >= 0x41 && code <= 0x5A) || // A-Z
      (code >= 0x61 && code <= 0x7A) || // a-z
      char == '_';
}
