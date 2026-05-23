# gisila_orm

A type-safe, schema-driven PostgreSQL ORM for Dart. Describe your tables in a
small YAML file, run a single `build_runner` command, and get back fully-typed
model classes, a fluent query builder, paired up/down migration SQL, and a
batched eager-loader that prevents N+1 queries.

```dart
final users = await Query<User>(UserTable.metadata)
    .where(UserTable.email.like('%@gumi.com')
        .and(UserTable.isActive.eq(true)))
    .orderBy(UserTable.createdAt, desc: true)
    .preload([User.posts, User.posts.then(Post.comments)])
    .limit(50)
    .all(db);
```

> **New here?** Read the [end-to-end walkthrough](#end-to-end-walkthrough)
> below — it takes you from an empty project to a working schema, migration,
> and tested query in about 15 minutes. The rest of this README is a reference.

---

## Table of contents

1. [Status](#status)
2. [Project layout](#project-layout)
3. [Install](#install)
4. [End-to-end walkthrough](#end-to-end-walkthrough)
5. [Schema YAML reference](#schema-yaml-reference)
6. [Code generation](#code-generation)
7. [Generated artefacts](#generated-artefacts)
8. [Database configuration](#database-configuration)
9. [Connecting and `DbContext`](#connecting-and-dbcontext)
10. [Building queries](#building-queries)
11. [Inserts, updates, deletes](#inserts-updates-deletes)
12. [Transactions](#transactions)
13. [Eager loading (preload)](#eager-loading-preload)
14. [Migrations](#migrations)
15. [CLI reference](#cli-reference)
16. [Testing your code](#testing-your-code)
17. [Error handling](#error-handling)
18. [Architecture](#architecture)
19. [Roadmap](#roadmap)

---

## Status

| Component | State |
| --- | --- |
| Schema YAML + `build_runner` codegen | Ready |
| Runtime: `Database`, `DbContext`, `Pool`/`Tx` | Ready |
| Typed `Query<T>` + `Expr<T>` AST | Ready |
| Eager-loading `Preloader` (HasMany / HasOne / BelongsTo / M2M) | Ready |
| Migrations runner + schema differ | Ready |

The ORM is the data layer of the wider gisila stack. The HTTP router lives in
[`gisila`](../gisila), the OpenAPI generator in
[`gisila_doc`](../gisila_doc), and the web-based admin UI in
[`gisila_studio`](../gisila_studio).

---

## Project layout

```
gisila_orm/
├── bin/
│   ├── generate.dart        # `dart run gisila_orm:generate` → build_runner shim
│   └── migrate.dart         # `dart run gisila_orm:migrate up|down|status`
├── lib/
│   ├── gisila.dart                          # public API barrel
│   ├── config/
│   │   └── database_config.dart             # YAML / env-driven DB config
│   ├── database/
│   │   ├── extensions.dart                  # safeTk / safe SQL helpers
│   │   ├── types.dart                       # DefaultEngine for default-value SQL
│   │   └── postgres/
│   │       ├── core/connections.dart        # Database (pool + tx)
│   │       └── exceptions/                  # PostgresException hierarchy
│   ├── runtime/
│   │   ├── db_context.dart                  # PoolDbContext + TxDbContext
│   │   └── preloadable.dart                 # mixin for eager-loaded relations
│   ├── query/
│   │   ├── expression.dart                  # Expr<T> AST
│   │   ├── compiler.dart                    # SqlCompiler ($n placeholders)
│   │   ├── hydrator.dart                    # Result row → typed model
│   │   ├── relation.dart                    # HasMany/HasOne/BelongsTo/M2M
│   │   ├── preloader.dart                   # batched IN-query eager loader
│   │   ├── table_meta.dart                  # TableMeta<T> metadata
│   │   └── query.dart                       # Query<T> fluent builder + mutations
│   ├── migrations/
│   │   ├── migration_manager.dart           # apply / rollback runner
│   │   └── schema_differ.dart               # diff two schemas → up/down SQL
│   └── generators/
│       ├── schema_parser.dart               # YAML → SchemaDefinition
│       ├── schema_builder.dart              # build_runner builder
│       └── codegen/
│           ├── dart_emitter.dart            # *.g.dart emitter
│           └── sql_emitter.dart             # *.up.sql / *.down.sql emitter
├── example/
│   └── models/blog.gisila.yaml              # sample schema (User, Author, Book, Review)
├── test/
│   ├── support/test_db.dart                 # MockDbContext + withTestDb
│   ├── query_compiler_test.dart             # golden SQL
│   ├── preloader_test.dart                  # N+1 prevention
│   ├── transaction_test.dart                # rollback isolation
│   ├── migration_test.dart                  # apply/rollback
│   └── d_orm_test.dart                      # public-API smoke test
├── docker-compose.yml                       # postgres for integration tests
├── build.yaml                               # build_runner builder config
└── pubspec.yaml
```

---

## Install

```yaml
# pubspec.yaml
dependencies:
  gisila_orm:
    path: ../gisila_orm   # replace with path / git / pub coordinate

dev_dependencies:
  build_runner: ^2.4.0
```

Add a schema file ending in `.gisila.yaml` anywhere under `lib/`, `example/`,
or `test/`. The `build_runner` builder picks them up automatically.

---

## End-to-end walkthrough

This is the shortest path from a blank project to a working query.

### 1. Describe your schema

`lib/models/blog.gisila.yaml`:

```yaml
Author:
  columns:
    name:
      type: varchar
      is_null: false
    email:
      type: varchar
      is_null: false
      is_unique: true
      is_index: true

Post:
  columns:
    title:
      type: varchar
      is_null: false
    body:
      type: text
      is_null: true
    author:
      type: Author
      references: Author
      is_index: true
      reverse_name: posts
```

### 2. Generate models and migration SQL

```bash
dart run build_runner build --delete-conflicting-outputs
# or, equivalently:
dart run gisila:generate
```

This emits, alongside the YAML:

- `blog.gisila.g.dart` — `Author`, `Post`, `AuthorTable`, `PostTable`, `Author.posts`, `Post.author`, …
- `blog.gisila.up.sql` — `CREATE TABLE ...` statements
- `blog.gisila.down.sql` — paired `DROP TABLE ...` statements

### 3. Configure the database

`database.yaml`:

```yaml
default: main
connections:
  main:
    type: postgresql
    host: localhost
    port: 5432
    database: blog
    username: postgres
    password: postgres
    max_connections: 10
```

### 4. Run the migration

```bash
dart run gisila:migrate up --dir lib/models --config database.yaml
```

### 5. Use the ORM

```dart
import 'package:gisila_orm/gisila.dart';
import 'models/blog.gisila.g.dart';

Future<void> main() async {
  final config = await DatabaseConfig.fromFile('database.yaml');
  final db = await Database.connect(config);

  final author = await Query<Author>(AuthorTable.metadata)
      .insert({'name': 'Ada Lovelace', 'email': 'ada@example.com'})
      .one(db);

  await Query<Post>(PostTable.metadata).insert({
    'title': 'On Analytical Engines',
    'body': '...',
    'author_id': author.id,
  }).run(db);

  final authorsWithPosts = await Query<Author>(AuthorTable.metadata)
      .preload([Author.posts])
      .all(db);

  for (final a in authorsWithPosts) {
    print('${a.name}: ${a.postsList.length} posts');
  }

  await db.close();
}
```

---

## Schema YAML reference

### File naming

Every schema file **must** end in `.gisila.yaml` or `.gisila.yml`. Files
matching this pattern under `lib/`, `test/`, or `example/` are picked up
automatically by `build_runner`.

### Top-level shape

Each top-level YAML key declares one model (which becomes one table):

```yaml
ModelName:
  db_table: optional_custom_table_name  # default: snake_case(ModelName)
  columns:
    column_name:
      type: <built-in or model name>
      # ...constraints...
  indexes:
    composite_index_name:
      columns: [col_a, col_b]
      unique: true   # optional
```

### Built-in column types

All column types map to their canonical PostgreSQL type and a Dart type:

| YAML type | Postgres type | Dart type |
| --- | --- | --- |
| `varchar` | `VARCHAR(255)` | `String` |
| `text` | `TEXT` | `String` |
| `integer` | `INTEGER` | `int` |
| `bigint` | `BIGINT` | `int` |
| `boolean` | `BOOLEAN` | `bool` |
| `date` | `DATE` | `DateTime` |
| `timestamp` | `TIMESTAMP WITH TIME ZONE` | `DateTime` |
| `decimal` | `DECIMAL` | `double` |
| `json` | `JSONB` | `Map<String, dynamic>` |
| `uuid` | `UUID` | `String` |

### Column constraints

| Key | Type | Default | Effect |
| --- | --- | --- | --- |
| `is_null` | bool | `true` | Allow `NULL`; if `false`, emits `NOT NULL`. |
| `is_unique` | bool | `false` | Adds `UNIQUE` constraint. |
| `is_index` | bool | `false` | Creates `CREATE INDEX idx_<table>_<column>`. |
| `is_primary` | bool | `false` | Marks column as `PRIMARY KEY`; suppresses the implicit `id` column. |
| `allow_blank` | bool | `true` | Reserved for upcoming model-side validation. |
| `default` | any | `null` | SQL default value. Strings are quoted; `NOW()`, `CURRENT_TIMESTAMP`, `CURRENT_DATE`, `CURRENT_TIME` pass through verbatim. |

If a model declares no `is_primary` column, gisila inserts an implicit
`id BIGSERIAL PRIMARY KEY`.

### Relationships

A column whose `type` is **another model name** (PascalCase, not in the
built-in list) is treated as a relation.

#### Many-to-one (`belongsTo`)

```yaml
Post:
  columns:
    author:
      type: Author
      references: Author      # explicit; can be omitted if same as type
      is_index: true
      reverse_name: posts     # creates Author.posts (HasMany on parent side)
      on_delete: SET NULL     # optional; default SET NULL
      on_update: CASCADE      # optional; default CASCADE
```

This emits `author_id INTEGER` on `post`, with a foreign key to `author(id)`.
On the Dart side you get `Post.author` (BelongsTo) **and** `Author.posts`
(HasMany), both as static typed `Relation` values usable in `.preload(...)`.

#### Many-to-many

```yaml
Book:
  columns:
    reviewers:
      type: User
      many_to_many: true
      references: User
      reverse_name: reviewed_books
```

Emits a junction table `book_user(book_id, user_id, created_at)` and gives
you both `Book.reviewers` and `User.reviewedBooks` as M2M relations.

### Composite indexes

```yaml
Review:
  db_table: reviews
  columns: { ... }
  indexes:
    idx_review_book_reviewer:
      columns: [book, reviewer]
      unique: true
```

### Naming conventions

- Model names: `PascalCase` in YAML, `snake_case` for the resulting table.
- Column names: `snake_case` in YAML, `camelCase` on the Dart side.
- Foreign-key columns: declared as the related model name (`author`),
  stored as `<column>_id` in SQL, exposed as `<column>Id` in Dart.

### Worked example

See [`example/models/blog.gisila.yaml`](example/models/blog.gisila.yaml) for
a four-model schema (User, Author, Book, Review) exercising every feature
above and its [generated `.g.dart`](example/models/blog.gisila.g.dart).

### Schema validation & error reporting

Every `.gisila.yaml` is run through a strict validator before code is
emitted. Mistakes surface as `rustc`-style diagnostics with the file
path, line, column, an arrow under the offending token, and (where
possible) a "did you mean?" suggestion.

The validator collects **every** problem in a single pass — so one
rebuild surfaces every typo at once instead of one-per-build. Severity
is colorized when the terminal supports ANSI escapes; pipe through a
file or set `NO_COLOR=1` to get plain text suitable for CI logs.

Sample input:

```yaml
User:
  collumns:                   # typo'd key
    name:
      type: varchars          # typo'd type
      is_null: yes            # not a bool

Post:
  columns:
    author:
      type: Authour           # unknown model
      references: Authour
      on_delete: CASCAD       # typo'd action
```

Renders:

```text
error[unknown_key]: unknown key "collumns" on model "User"
 --> lib/models/blog.gisila.yaml:2:3
   |
 2 |   collumns:
   |   ^^^^^^^^ did you mean "columns"?

error[invalid_value]: `is_null` on "User.name" must be a boolean (true or false)
 --> lib/models/blog.gisila.yaml:5:16
   |
 5 |       is_null: yes
   |                ^^^ change to `is_null: true` (the default)

error[unknown_type]: unknown column type "varchars"
 --> lib/models/blog.gisila.yaml:4:13
   |
 4 |       type: varchars
   |             ^^^^^^^^ did you mean "varchar"?

error[unknown_reference]: "Post.author" references unknown model "Authour"
 --> lib/models/blog.gisila.yaml:11:19
    |
 11 |       references: Authour
    |                   ^^^^^^^ did you mean "Author"?

error[invalid_referential_action]: `on_delete` must be one of: NO ACTION, RESTRICT, CASCADE, SET NULL, SET DEFAULT
 --> lib/models/blog.gisila.yaml:12:18
    |
 12 |       on_delete: CASCAD
    |                  ^^^^^^ did you mean "CASCADE"?

aborting due to 5 errors
```

Every error has a stable code (`unknown_type`, `unknown_reference`,
`invalid_value`, `duplicate_key`, `missing_columns`,
`reverse_name_collision`, …) so it can be grepped, suppressed, or
documented. Building programmatically? Catch `SchemaValidationException`
and call `e.format(color: false)` to get the same report as a string:

```dart
try {
  final schema = SchemaDefinition.fromYaml(
    yamlContent,
    sourceUrl: Uri.parse('lib/models/blog.gisila.yaml'),
  );
} on SchemaValidationException catch (e) {
  stderr.writeln(e.format(color: false));
  for (final err in e.errors) {
    print('${err.code}: ${err.message} at ${err.span.start.toolString}');
  }
}
```

---

## Code generation

The generator is a `build_runner` Builder registered in `build.yaml`:

```yaml
builders:
  schemaBuilder:
    import: "package:gisila_orm/generators/schema_builder.dart"
    builder_factories: ["schemaBuilder"]
    build_extensions:
      ".gisila.yaml":
        - ".gisila.g.dart"
        - ".gisila.up.sql"
        - ".gisila.down.sql"
    auto_apply: dependents
    build_to: source
```

You don't normally edit `build.yaml`. Run:

```bash
dart run gisila_orm:generate
# equivalent to:
dart run build_runner build --delete-conflicting-outputs
```

Watch mode for development:

```bash
dart run build_runner watch
```

---

## Generated artefacts

For each model `Foo` in your YAML, the generator emits:

### `class Foo with Preloadable`

- Final fields for every column.
- `Foo({...})` constructor; primary keys are nullable in Dart (DB-generated on insert).
- `factory Foo.fromRow(Map<String, dynamic> row)` — used by the hydrator.
- `Map<String, dynamic> toRow()` — used by inserts/updates and the preloader.
- `factory Foo.fromJson` / `Map<String, dynamic> toJson()` — aliases for `fromRow` / `toRow`.
- `Foo copyWith({...})`.
- `static final Relation<Foo, X> someRelation` — one per declared/inverse relation.
- `List<X> get someRelationList` (HasMany / M2M) or `X? get someRelationLoaded` (BelongsTo / HasOne) — typed accessors over the preload cache.

### `class FooTable`

- `static const ColumnRef<T> columnName` for every column — typed handles used in `where(...)` predicates and `orderBy(...)`.
- `static const TableMeta<Foo> metadata` — `Query<Foo>` consumes this.

### `Query<Foo> foos()`

A convenience top-level function returning `Query<Foo>(FooTable.metadata)`,
so you can write `foos().where(...).all(db)` in code.

### `*.up.sql` and `*.down.sql`

PostgreSQL DDL for every model (and its junction tables, if any), wrapped in
a single `BEGIN; ... COMMIT;` block. The down file pairs `DROP TABLE`s in
reverse dependency order.

---

## Database configuration

`DatabaseConfig` accepts one or more named `DatabaseConnection`s with one
designated default.

### From YAML

```yaml
# database.yaml
default: main
connections:
  main:
    type: postgresql
    host: localhost
    port: 5432
    database: gisila_app
    username: postgres
    password: postgres
    ssl: false
    connection_timeout: 30      # seconds
    query_timeout: 30           # seconds
    max_connections: 10
    min_connections: 2
    additional_params:
      application_name: my_service
```

```dart
final config = await DatabaseConfig.fromFile('database.yaml');
```

### From environment variables

`DATABASE_URL` provides the default connection. For multiple connections,
list their names in `DB_CONNECTIONS` and provide each `DB_<NAME>_URL`:

```bash
export DATABASE_URL=postgresql://postgres:postgres@localhost:5432/blog
export DB_CONNECTIONS=replica,analytics
export DB_REPLICA_URL=postgresql://...
export DB_ANALYTICS_URL=postgresql://...
```

```dart
final config = await DatabaseConfig.fromEnvironment(
  configFile: 'database.yaml', // optional base config; env wins
);
```

### Programmatically

```dart
final config = DatabaseConfig(connections: [
  DatabaseConnection.postgresql(
    name: 'main',
    host: 'localhost',
    database: 'blog',
    username: 'postgres',
    password: 'postgres',
  ),
]);
```

> Only `type: postgresql` is supported in this release. The enum is
> reserved for future backends.

---

## Connecting and `DbContext`

`Database.connect` builds named connection pools (lazily, unless `eager: true`)
and exposes one entry point: a `DbContext` per pool, plus a `transaction(...)`
method.

```dart
final db = await Database.connect(
  config,
  eager: true,                  // create all pools up-front
  onOpen: (conn) async {        // optional per-connection setup
    await conn.execute('SET TIME ZONE \'UTC\'');
  },
);
```

You almost never call the pool directly — every query goes through a
`DbContext`:

```dart
final defaultCtx = db.context();           // pool-backed
final replicaCtx = db.context('replica');  // pool-backed, named pool
```

Both `PoolDbContext` and `TxDbContext` implement `DbContext`. The same
`Query<T>` works against either. Errors from `package:postgres` are mapped
into the typed `PostgresException` hierarchy on the way out.

Cheap liveness probe and shutdown:

```dart
await db.ping();
await db.close();
```

---

## Building queries

A `Query<T>` is a chainable builder. Every clause is optional; methods
mutate-and-return so they can be chained, but each call creates an
immutable `CompiledSql` only when you invoke a terminal operation.

### Terminal operations

| Method | Returns | Notes |
| --- | --- | --- |
| `.all(db)` | `Future<List<T>>` | hydrates every row, runs preloads |
| `.one(db)` | `Future<T>` | throws `StateError` on 0 or >1 rows |
| `.first(db)` | `Future<T?>` | first row or `null` |
| `.count(db)` | `Future<int>` | `SELECT COUNT(*)` honoring WHERE/JOINs |
| `.exists(db)` | `Future<bool>` | `SELECT EXISTS(...)` |
| `.stream(db)` | `Stream<T>` | yields hydrated rows lazily |

### Predicates (`where`)

Predicates are built from `ColumnRef<T>` extensions and the boolean
combinators `.and`, `.or`, `.not`. The full operator set:

```dart
UserTable.email.eq('a@b.com')
UserTable.email.neq('x@y.com')
UserTable.age.gt(18)
UserTable.age.gte(18)
UserTable.age.lt(65)
UserTable.age.lte(65)
UserTable.email.like('%@gumi.com')
UserTable.email.ilike('%@GUMI.com')
UserTable.id.inList([1, 2, 3])
UserTable.age.between(18, 65)
UserTable.deletedAt.isNull
UserTable.deletedAt.isNotNull

// Column-vs-column comparisons:
PostTable.userId.eqExpr(UserTable.id)

// JSON / JSONB navigation:
UserTable.preferences.field('theme').eq('dark')   // ->
UserTable.preferences.text('locale').eq('en-US')  // ->>

// Postgres array containment / overlap:
UserTable.tags.contains(['admin'])      // @>
UserTable.tags.overlaps(['admin', 'mod'])  // &&

// Composition:
final q = UserTable.isActive.eq(true).and(UserTable.age.gt(18))
final r = UserTable.email.like('%@gumi.com').or(UserTable.email.like('%@bff.com'))
final n = UserTable.isActive.eq(true).not
```

Multiple `where` calls AND together:

```dart
Query<User>(UserTable.metadata)
    .where(UserTable.isActive.eq(true))
    .where(UserTable.age.gt(18));    // both must hold
```

### Ordering, paging, projection

```dart
Query<User>(UserTable.metadata)
    .orderBy(UserTable.createdAt, desc: true, nullsFirst: false)
    .orderBy(UserTable.id)
    .limit(50)
    .offset(100)
    .distinct()
    .select(['id', 'email']);  // override default projection
```

### Joins

```dart
Query<User>(UserTable.metadata)
    .join(
      'orders',
      const ColumnRef<int>(table: 'orders', column: 'user_id')
          .eqExpr(UserTable.id),
      type: JoinType.left,
    );
```

Supported `JoinType`s: `inner`, `left`, `right`, `full`.

### Group by / having

```dart
Query<User>(UserTable.metadata)
    .groupBy(UserTable.isActive)
    .having(UserTable.age.gt(30));
```

### Escape hatch

For SQL the AST can't model, drop down to `RawSql<T>(sql, params)` inside a
predicate, or pass a `connection.execute(...)` directly via the `DbContext`.

---

## Inserts, updates, deletes

Mutations all return `RETURNING *` by default and hydrate into model
instances.

### Insert

```dart
final user = await Query<User>(UserTable.metadata)
    .insert({'email': 'a@b.com', 'is_active': true})
    .one(db);

// Multi-row:
final users = await Query<User>(UserTable.metadata)
    .insert({'email': 'a@b.com', 'is_active': true})
    .values({'email': 'c@d.com', 'is_active': false})
    .run(db);

// On conflict (no target spec yet):
await Query<User>(UserTable.metadata)
    .insert({'email': 'a@b.com'})
    .onConflictDoNothing()
    .returning(false)
    .run(db);
```

### Update

```dart
// SET parameters and WHERE parameters share the same $n index space, so
// no off-by-one issues.
await Query<User>(UserTable.metadata)
    .where(UserTable.id.eq(99))
    .update({'email': 'new@x.com', 'is_active': false})
    .run(db);
```

### Delete

```dart
await Query<User>(UserTable.metadata)
    .where(UserTable.id.eq(1))
    .delete()
    .run(db);
```

---

## Transactions

`Database.transaction` runs the body inside a Postgres transaction and
hands you a `TxDbContext`. The same `Query<T>` works against it:

```dart
await db.transaction((tx) async {
  final author = await Query<Author>(AuthorTable.metadata)
      .insert({'name': 'Ada'})
      .one(tx);

  await Query<Post>(PostTable.metadata)
      .insert({'title': 'p1', 'author_id': author.id})
      .run(tx);

  // Throwing here rolls back both inserts.
  if (somethingBad) throw StateError('rollback');
});
```

Explicit rollback (rare):

```dart
await db.transaction((tx) async {
  await tx.execute('SAVEPOINT sp');
  // ...
  await tx.rollback();
});
```

Optional driver-level settings (isolation level, deferrable, etc.) pass
through `TransactionSettings`:

```dart
await db.transaction(
  (tx) async => /* ... */,
  settings: TransactionSettings(
    isolationLevel: IsolationLevel.serializable,
  ),
);
```

---

## Eager loading (preload)

Naively walking child relations creates the N+1 problem (one query for the
parent set, one extra query *per parent* for its children). The gisila
`Preloader` collapses each level into a single batched
`WHERE fk IN ($1, $2, ..., $n)` query. Total round-trips equal the
**depth** of the preload tree, not its breadth.

### Single-level

```dart
final authors = await Query<Author>(AuthorTable.metadata)
    .preload([Author.posts])
    .all(db);

// Two queries total:
//   SELECT ... FROM author
//   SELECT ... FROM post WHERE user_id IN ($1, $2, ...)

for (final a in authors) {
  for (final p in a.postsList) print(p.title);  // typed accessor
}
```

### Nested with `.then(...)`

```dart
final authors = await Query<Author>(AuthorTable.metadata)
    .preload([
      Author.posts.then(Post.comments),
    ])
    .all(db);

// Three queries total — one per level.

final post = authors.first.postsList.first;
for (final c in post.commentsList) print(c.body);
```

### Many-to-many

The preloader runs **two** queries per M2M level (junction table lookup,
then a child fetch keyed by the discovered child IDs). Still constant in
the parent count.

### Belongs-to and has-one

For singular relations, the typed accessor returns `T?` instead of
`List<T>`:

```dart
final posts = await Query<Post>(PostTable.metadata)
    .preload([Post.author])
    .all(db);

print(posts.first.authorLoaded?.name);
```

---

## Migrations

The migration system reads `*.up.sql` / `*.down.sql` pairs from disk and
tracks applied IDs in a `gisila_migrations` table created on first run.

### Programmatic API

```dart
final manager = MigrationManager(db);

// Discover every up.sql + matching down.sql under a directory:
final discovered = await manager.discoverIn('lib/models');

// Apply everything pending; each migration runs in its own transaction.
final upRes = await manager.up(discovered);
print('Applied ${upRes.applied.length} (batch #${upRes.batch})');

// Roll back the most recent batch.
await manager.down(discovered: discovered, steps: 1);

// Inspect tracking table.
for (final m in await manager.listApplied()) {
  print('${m.appliedAt}  ${m.id}  (batch ${m.batch})');
}
```

### Tracking table

```sql
CREATE TABLE IF NOT EXISTS "gisila_migrations" (
  "id"         BIGSERIAL PRIMARY KEY,
  "migration"  VARCHAR(255) NOT NULL UNIQUE,
  "batch"      INTEGER      NOT NULL,
  "applied_at" TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP
);
```

Override the table name via `MigrationManager(db, trackingTable: 'my_table')`.

### Diffing two schemas

For migration authoring, `SchemaDiffer` compares two parsed
`SchemaDefinition`s and emits paired up/down DDL with rename detection,
foreign-key add/drop, type/nullability/default changes, and index churn:

```dart
final diff = SchemaDiffer().compareSchemas(oldSchema, newSchema);
await SchemaDiffer().generateMigrationFile(diff, 'migrations/', 'add_users');
```

---

## CLI reference

### `dart run gisila_orm:generate [build_runner args]`

Thin shim around `dart run build_runner build`. Adds
`--delete-conflicting-outputs` by default; pass `--no-delete` to opt out.

### `dart run gisila_orm:migrate <up|down|status> [flags]`

| Flag | Default | Effect |
| --- | --- | --- |
| `--dir <path>` | `lib` | Directory to scan for `*.up.sql` / `*.down.sql` pairs (recursive). |
| `--config <yaml>` | `database.yaml` | Path to the `DatabaseConfig` YAML. |
| `--steps <n>` | `1` | (`down` only) Number of recent batches to roll back. |

Examples:

```bash
dart run gisila_orm:migrate status --dir lib/models
dart run gisila_orm:migrate up --dir lib/models --config database.yaml
dart run gisila_orm:migrate down --dir lib/models --steps 2
```

---

## Testing your code

Two helpers ship under `test/support/test_db.dart`. Both are exported as
test utilities — copy the import path into your own test files.

### `MockDbContext` — pure unit tests

Records every `(sql, params)` pair without ever talking to a database.
Optionally returns canned `Result`s.

```dart
final mock = MockDbContext();

await Query<User>(UserTable.metadata)
    .where(UserTable.email.eq('a@b.com'))
    .all(mock);

expect(mock.sqls.single, contains('FROM "user"'));
expect(mock.params.single, ['a@b.com']);
expect(mock.callCount, 1);
```

Use cases: golden-SQL tests, asserting query counts (e.g. that preloading
collapses N+1 into N+1 round-trips, not 2N), capturing inserts.

### `withTestDb` — integration tests

Spins up against the docker-compose Postgres at `localhost:5454`, allocates
a per-test schema, and tears it down at the end. Returns `null` (and the
test should `markTestSkipped`) if no Postgres is reachable, so the same
suite runs locally and in CI without conditional logic per file.

```dart
test('inserts persist after commit', () async {
  if (!await isTestDbAvailable()) {
    markTestSkipped('No Postgres on localhost:5454');
    return;
  }

  await withTestDb((db, schema) async {
    await db.execute('CREATE TABLE t (id BIGSERIAL PRIMARY KEY)');
    await db.transaction((tx) async {
      await tx.execute('INSERT INTO t DEFAULT VALUES');
    });
    final res = await db.execute('SELECT COUNT(*)::int AS c FROM t');
    expect(res.first.toColumnMap()['c'], 1);
  });
});
```

Bring up the test database with the bundled `docker-compose.yml`:

```bash
docker compose up -d
dart test
```

---

## Error handling

Every driver-level error is translated into the typed exception hierarchy
in `lib/database/postgres/exceptions/`, rooted at `PostgresException`:

```dart
try {
  await Query<User>(UserTable.metadata)
      .insert({'email': existing})
      .run(db);
} on PostgresUniqueViolationException catch (e) {
  print('duplicate row: ${e.message}');
} on PostgresForeignKeyViolationException catch (e) {
  print('FK violation: ${e.message}');
} on PostgresException catch (e) {
  // sqlState (5-char SQLSTATE), errorCode, query, details all available
  print('db error ${e.sqlState}: ${e.message}');
}
```

`PoolDbContext` and `TxDbContext` apply the mapping uniformly, so you get
the same exception type whether the failure happened inside or outside a
transaction.

---

## Architecture

```mermaid
graph TD
  YAML[*.gisila.yaml] --> Builder[build_runner: SchemaBuilder]
  Builder --> Dart[*.gisila.g.dart<br/>User, UserTable, User.posts]
  Builder --> Up[*.gisila.up.sql]
  Builder --> Down[*.gisila.down.sql]

  App[user code] --> Q[Query&lt;T&gt;]
  Dart --> Q
  Q --> Compiler[SqlCompiler<br/>$n placeholders]
  Compiler --> Ctx[DbContext]
  Ctx -->|outside tx| Pool[postgres Pool]
  Ctx -->|inside tx|  Tx[TxSession]
  Pool --> PG[(PostgreSQL)]
  Tx   --> PG

  Q --> Preloader[Preloader<br/>batched IN-queries]
  Preloader --> Q

  Up --> Mig[MigrationManager]
  Mig --> PG
```

Single invariant: **every** SQL statement that hits Postgres is built by
`SqlCompiler` from a typed AST and binds parameters with `$n`
placeholders, never `?`. There is one query pipeline; the
`package:postgres` driver pool is the only pool.

---

## Related packages

| Package | What it adds |
| ------- | ------------ |
| [`gisila`](../gisila) | Shelf-based HTTP router with annotation-driven controllers, auth guards, CORS, rate-limiting, and structured logging. |
| [`gisila_doc`](../gisila_doc) | OpenAPI 3.1 spec generation from annotated controllers; bundled Swagger UI and ReDoc. |
| [`gisila_studio`](../gisila_studio) | Web-based Django-style admin interface auto-generated from `TableMeta` registrations. |
