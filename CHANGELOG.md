# Changelog

## Unreleased

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
