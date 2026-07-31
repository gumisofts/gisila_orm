# Changelog

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
