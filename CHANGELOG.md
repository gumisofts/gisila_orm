# Changelog

## Unreleased

- Breaking: `update(...)` and `delete()` without a WHERE clause throw
  `InvalidQueryBuilderException` instead of touching every row. Call
  `.all()` on the builder when you mean the whole table.
- Breaking: `RawSql` parameters are written `$1`, `$2`, ... (counted within
  the fragment) instead of `?`, so the JSONB `?` operators work in raw SQL.
  A fragment whose placeholders don't match its parameters throws
  `ArgumentError`. Fragments are now parenthesised, so `RawSql('a OR b')`
  next to another `where` no longer widens the match.
- Fix: preloading with more than 10,000 parent keys runs in batches instead
  of failing on Postgres' 65,535 bind-parameter limit.
- Fix: migrations drop a removed enum type after the tables and columns that
  used it, not before (`DROP TYPE` failed while a column still used it).
- Fix: `count()` ignores ORDER BY, LIMIT and OFFSET, so it counts every
  matching row (Postgres used to reject the ORDER BY, and an OFFSET past
  the first row threw). With DISTINCT or GROUP BY it counts distinct rows or
  groups through a subquery.
- Fix: `one()` and `first()` no longer change the query they are called on
  (they used to leave `LIMIT 2` / `LIMIT 1` behind for the next call).
- Fix: `eq(null)` / `neq(null)` compile to `IS NULL` / `IS NOT NULL`;
  `= NULL` never matched anything.
- Security: `safeTk` now escapes inner `"` in identifiers and `safe` escapes
  inner `'` in literals. Both pass a value through unchanged only when it is
  already a well-formed quoted token, so column names passed to `select()`,
  `insert()` and `update()` can no longer inject SQL.
- Migrations: the first `generate` run in a project without hand-written
  migrations writes `migrations/<ts>_initial_schema.up.sql` (and `.down.sql`)
  from the snapshot schema, so `migrate up` builds a fresh database. Projects
  with a snapshot but no migrations get it backfilled on the next run.
- Migrations: `discoverIn` uses the `*.gisila.up.sql` baseline when a
  directory holds no other migration (the 0.1.5 regression applied nothing).
- Migrations: databases that applied the baseline under 0.1.4
  (`schema.gisila`) record `<ts>_initial_schema` as applied without
  re-running it.
- Docs: CLI examples use `dart run gisila_orm:migrate` / `gisila_orm:generate`.
- Migrations: `generate` and `migrate diff` refuse to write a migration that
  can lose data (dropped tables, columns or enums, and column type changes
  other than widening such as INTEGER→BIGINT or VARCHAR(n)→TEXT). Nothing is
  written and the snapshot stays put until you re-run with
  `--allow-destructive`. `SchemaDiff.destructiveChanges` lists them, and
  `generateMigrationFile` throws `DestructiveMigrationException` unless
  `allowDestructive: true`.
- Migrations: renames the differ guesses from a drop+add are marked with a
  `-- GUESSED RENAME` comment in the SQL and a warning on stdout, and
  destructive steps with `-- DESTRUCTIVE`.
- Migrations: `up` and `down` hold a Postgres advisory lock (keyed on the
  schema and tracking table) for the whole run, so two deploys migrating
  the same database take turns instead of racing.
- Migrations: the tracking table gains a `checksum` column (added in place
  on first run). `up` refuses with `MigrationChecksumException` when an
  applied migration's file was edited since; `migrate status` marks those.
  Rows applied before this release get their checksum recorded from the
  current file on the next `up`.
- Migrations: a `-- gisila:no-transaction` line runs that file outside the
  per-migration transaction, for statements like
  `CREATE INDEX CONCURRENTLY`.
- `Database.withConnection` runs a callback on one pinned pool connection
  (`ConnectionDbContext`).
- Migrations: a table added after the first migration now gets its foreign
  keys, `is_index`/`indexes:` indexes and many-to-many junction tables, as a
  fresh install would. Foreign keys and junctions are added after every
  table exists. Removing a many-to-many drops its junction table (counted
  as destructive).
- Security: `DATABASE_URL` parsing follows libpq. `sslmode=verify-full` and
  `verify-ca` now verify the certificate (they used to turn TLS off, as did
  everything but `require`); `prefer`/`allow` use TLS when the server offers
  it; unknown values are rejected. `sslrootcert` trusts a CA file (also
  added to the process-wide default context, since `package:postgres`
  ignores a pool's `securityContext`). User, password and database are
  percent-decoded, and the password is split on the first `:` only. New
  `DatabaseConnection.fromUrl`, `DatabaseSslMode`, `sslMode`/`sslRootCert`
  fields and YAML `ssl_mode`/`ssl_root_cert`. `connectionString`
  percent-encodes credentials.

## 0.1.5

- Migrations: `discoverIn` skips `*.gisila.up.sql` / `*.gisila.down.sql`
  build_runner artifacts and sorts by migration id so incremental files under
  `migrations/` cannot run before a baseline schema that sorts later by path.

## 0.1.4

- CLI: `dart run gisila_orm:migrate` now loads config via
  `DatabaseConfig.fromEnvironment`, so **`DATABASE_URL` overrides**
  `database.yaml` (required for file-less deploys such as Gisila Panel).
  Optional `--config` still seeds named connections from YAML when present.
- Package: declare `migrate` and `generate` executables in `pubspec.yaml`.

## 0.1.3

- Migrations: replace the line-comment stripper added in 0.1.2 with a scanner that tracks string literals, quoted identifiers, dollar quotes, and comments, so only top-level semicolons end a statement. 0.1.2 stripped everything after the first `--` on a line even inside a string, corrupting values such as `'cargo build --release'` and leaving an unterminated literal. Anyone on 0.1.2 should upgrade.
- Migrations: dollar-quoted function bodies and block comments (including nested ones) now survive splitting intact.

## 0.1.2

- Migrations: strip `--` line comments before splitting a script into statements. Previously a semicolon inside a comment truncated the comment and fed its remainder to PostgreSQL as a statement, failing the migration with a syntax error.
- Migrations: skip bare `BEGIN` / `COMMIT` statements, since `MigrationManager` already wraps each migration in its own transaction.
- Schema differ: fix UUID foreign-key diffs so a belongs-to column matches the referenced model's actual primary key type instead of a hardcoded `int`.

## 0.1.1

- Unified version with the rest of the gisila ecosystem (`gisila`, `gisila_doc`, `gisila_studio`).
- Fluent query builder: `Query<T>` with a typed `Expr` AST for where-clauses, ordering, limiting, and pagination.
- Mutation builders: `InsertQuery`, `UpdateQuery`, and `DeleteQuery` with `$n`-placeholder SQL emission via `SqlCompiler`.
- Relation and eager preloading support via `Preloader`.
- Migration system: `MigrationManager` discovers `*.up.sql` / `*.down.sql` pairs on disk, tracks applied migrations in a `gisila_migrations` table, and applies/rolls back batches transactionally.
- Schema code generation: `schema_parser` + `dart_emitter` / `sql_emitter` generate typed table classes and DDL from schema definitions.
- `pgvector` support: immutable `Vector` type with round-trip serialization to PostgreSQL's `vector` column type.
- PostgreSQL geometric types and custom type mappings.
- `DatabaseConfig` loaded from a YAML file; connection pooling via `Connections`.
- Structured PostgreSQL exception hierarchy with error-code mapping.

## 0.0.1+5

- Stability improvements and bug fixes.

## 0.0.1

- Initial version.
