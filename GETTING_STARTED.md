# Getting started with gisila

A step-by-step tutorial that takes you from an empty directory to a working
PostgreSQL ORM with typed models, migrations, and tests. By the end you'll
have a small two-table blog application backed by gisila.

> **Time required:** 15 minutes.
> **You will need:** Dart SDK 3.3+, Docker (or any local PostgreSQL 13+).
> **You will write:** one YAML schema, one config file, ~50 lines of Dart.

If you just want a reference, see [README.md](README.md). This document is
the tutorial; it deliberately repeats things that are also documented there
in shorter form.

---

## Table of contents

1. [Prerequisites](#1-prerequisites)
2. [Create a new Dart project](#2-create-a-new-dart-project)
3. [Add gisila as a dependency](#3-add-gisila-as-a-dependency)
4. [Run PostgreSQL locally](#4-run-postgresql-locally)
5. [Configure the database](#5-configure-the-database)
6. [Write your first schema](#6-write-your-first-schema)
7. [Generate model code](#7-generate-model-code)
8. [Apply your first migration](#8-apply-your-first-migration)
9. [Connect from your app](#9-connect-from-your-app)
10. [Insert, query, update, delete](#10-insert-query-update-delete)
11. [Add a relation and preload it](#11-add-a-relation-and-preload-it)
12. [Wrap multiple writes in a transaction](#12-wrap-multiple-writes-in-a-transaction)
13. [Evolve your schema with a new migration](#13-evolve-your-schema-with-a-new-migration)
14. [Write a unit test against MockDbContext](#14-write-a-unit-test-against-mockdbcontext)
15. [Write an integration test against real Postgres](#15-write-an-integration-test-against-real-postgres)
16. [Project layout recap](#16-project-layout-recap)
17. [Where to go next](#17-where-to-go-next)

---

## 1. Prerequisites

Verify your toolchain:

```bash
dart --version          # >= 3.3.0
docker --version        # any recent version, optional but recommended
psql --version          # optional; only if you bring your own Postgres
```

If you don't have Docker and don't want to install Postgres locally, you can
use any reachable PostgreSQL 13+ instance (managed cloud, VM, etc.). The
only thing gisila needs is a connection string and credentials with
`CREATE TABLE` privileges.

---

## 2. Create a new Dart project

```bash
dart create -t console blog_demo
cd blog_demo
```

You now have:

```
blog_demo/
├── analysis_options.yaml
├── bin/blog_demo.dart      # entry point we'll edit later
├── lib/                     # we'll add models here
├── pubspec.yaml
└── test/
```

---

## 3. Add gisila as a dependency

```bash
dart pub add gisila
dart pub add --dev build_runner
```

Your `pubspec.yaml` should now contain:

```yaml
dependencies:
  gisila: ^0.0.1

dev_dependencies:
  build_runner: ^2.4.0
  test: ^1.24.0
```

You don't need to add `analyzer`, `source_gen`, or `json_annotation` —
gisila's code generator depends only on `package:build` and ships its own
emitters.

---

## 4. Run PostgreSQL locally

The fastest path is Docker. Create `docker-compose.yml` in the project
root:

```yaml
services:
  pg:
    image: postgres:16-alpine
    restart: unless-stopped
    ports:
      - "5432:5432"
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
      POSTGRES_DB: blog_demo
    volumes:
      - blog_pg_data:/var/lib/postgresql/data

volumes:
  blog_pg_data:
```

Bring it up:

```bash
docker compose up -d
docker compose ps      # confirm "pg" is healthy
```

> **Bring-your-own Postgres:** create an empty database
> (`CREATE DATABASE blog_demo;`) and a user that owns it. Skip the rest
> of this section.

---

## 5. Configure the database

gisila reads a `database.yaml` to know how to connect. Create it in the
project root:

```yaml
default: main
connections:
  main:
    type: postgresql
    host: localhost
    port: 5432
    database: blog_demo
    username: postgres
    password: postgres
    ssl: false
    connection_timeout: 30
    query_timeout: 30
    max_connections: 10
    min_connections: 2
```

You can later add multiple named connections (read replica, analytics
warehouse, …) under the same `connections:` map and pick which one to use
at runtime via `db.context('replica')`.

> Prefer environment variables in production. gisila's
> `DatabaseConfig.fromEnvironment` reads `DATABASE_URL` for the default
> pool and `DB_<NAME>_URL` for additional named pools.

---

## 6. Write your first schema

gisila is **schema-driven**: you describe your tables in YAML and the
codegen produces Dart models, migration SQL, and typed query helpers.

Schema files **must** end in `.gisila.yaml` (or `.gisila.yml`) so the
builder picks them up. Create `lib/models/blog.gisila.yaml`:

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
    created_at:
      type: timestamp
      is_null: false
      default: "NOW()"

Post:
  columns:
    title:
      type: varchar
      is_null: false
    body:
      type: text
      is_null: true
    published:
      type: boolean
      is_null: false
      default: false
    author:
      type: Author          # PascalCase, not in built-in list → relation
      references: Author
      is_index: true
      reverse_name: posts   # creates Author.posts on the parent side
    created_at:
      type: timestamp
      is_null: false
      default: "NOW()"
```

Things worth noting:

- We didn't declare an `id` column on either model. gisila adds an
  implicit `id BIGSERIAL PRIMARY KEY` when no `is_primary: true` column
  is present.
- `author: { type: Author, references: Author }` declares a
  many-to-one relationship. The generated SQL stores it as
  `author_id INTEGER` with a foreign key to `author(id)`.
- `reverse_name: posts` makes the inverse navigable in code as
  `Author.posts` (a `HasMany<Author, Post>`).
- `default: "NOW()"` is passed through verbatim. Quote it so YAML treats
  it as a string; the SQL emitter recognises functions like `NOW()`,
  `CURRENT_TIMESTAMP`, `CURRENT_DATE`, `CURRENT_TIME` and emits them
  unquoted in the DDL.

Full reference for column types, constraints, indexes, M2M relations and
custom table names lives in the [README's schema section](README.md#schema-yaml-reference).

---

## 7. Generate model code

Run the gisila code generator:

```bash
dart run gisila_orm:generate
```

With one schema file you'll see three new files appear next to your YAML
(the source stem is preserved):

```
lib/models/
├── blog.gisila.yaml          # you wrote this
├── blog.gisila.g.dart        # ← typed Dart models
├── blog.gisila.up.sql        # ← CREATE TABLE statements
└── blog.gisila.down.sql      # ← paired DROP TABLE statements
```

If you later split models across multiple `*.gisila.yaml` files, the same
command emits a shared bundle instead (`schema.gisila.g.dart` + up/down
SQL under `lib/models/`). Cross-file relations work; import
`models/schema.gisila.g.dart`. See the README
[Multi-file schemas](README.md#multi-file-schemas) section.

Open `blog.gisila.g.dart`. Each YAML model produced:

- A class `with Preloadable` carrying every column as a typed field.
- A constructor (primary keys are nullable since the DB generates them).
- `fromRow` / `toRow` / `fromJson` / `toJson` / `copyWith`.
- A companion class (`AuthorTable`, `PostTable`) with `static const`
  `ColumnRef<T>` handles for every column and a `static const TableMeta`.
- `static final` `Relation` values for every navigable edge:
  - `Post.author` (`BelongsTo<Post, Author>`)
  - `Author.posts` (`HasMany<Author, Post>`)
- Typed accessors over the eager-load cache:
  - `post.authorLoaded` returns `Author?`
  - `author.postsList` returns `List<Post>`

Also commit `lib/models/blog.gisila.g.dart` and the two `.sql` files to
your repo. They are deterministic outputs of the YAML; CI re-generation is
useful as a drift check, not as a build step.

While iterating on a **single-file** schema you can also use
`dart run build_runner watch`. Multi-file projects should re-run
`dart run gisila_orm:generate` after YAML edits.

---

## 8. Apply your first migration

The generator already produced `blog.gisila.up.sql`. The `gisila:migrate`
CLI applies it.

```bash
dart run gisila:migrate up --dir lib/models --config database.yaml
```

Expected output:

```
Applied 1 migration(s) in batch 1:
  - lib/models/blog.gisila
```

What just happened:

1. `gisila:migrate` connected using `database.yaml`.
2. It created the bookkeeping table `gisila_migrations` if missing.
3. It scanned `lib/models/` for `*.up.sql` files with paired `*.down.sql`,
   compared their IDs against `gisila_migrations`, and ran every pending
   one inside its own transaction.
4. It recorded the applied IDs into `gisila_migrations` with a shared
   `batch` number.

Sanity check:

```bash
dart run gisila:migrate status --dir lib/models --config database.yaml
# Discovered: 1, applied: 1
#   [x] lib/models/blog.gisila
```

In Postgres:

```bash
docker compose exec pg psql -U postgres -d blog_demo -c '\dt'
```

You should see `author`, `post`, and `gisila_migrations`.

---

## 9. Connect from your app

Open `bin/blog_demo.dart` and replace it with:

```dart
import 'package:gisila/gisila.dart';
import '../lib/models/blog.gisila.g.dart';

Future<void> main() async {
  final config = await DatabaseConfig.fromFile('database.yaml');
  final db = await Database.connect(config);

  try {
    await db.ping();
    print('connected to ${config.defaultConnection.database}');
  } finally {
    await db.close();
  }
}
```

Run it:

```bash
dart run
# connected to blog_demo
```

`Database.connect` builds the named pools described by `DatabaseConfig`
but doesn't open sockets until they're needed. Pass `eager: true` to open
them up-front, and `onOpen: (conn) async { ... }` to run setup like
`SET TIME ZONE 'UTC'` for every newly acquired physical connection.

---

## 10. Insert, query, update, delete

Replace `main` with a CRUD demo:

```dart
import 'package:gisila/gisila.dart';
import '../lib/models/blog.gisila.g.dart';

Future<void> main() async {
  final db = await Database.connect(
    await DatabaseConfig.fromFile('database.yaml'),
  );

  try {
    // INSERT … RETURNING * — returns a fully hydrated Author.
    final ada = await Query<Author>(AuthorTable.metadata)
        .insert({
          'name': 'Ada Lovelace',
          'email': 'ada@example.com',
          'created_at': DateTime.now().toUtc(),
        })
        .one(db);

    print('inserted author #${ada.id}');

    // INSERT a post for Ada.
    await Query<Post>(PostTable.metadata).insert({
      'title': 'On Analytical Engines',
      'body': '…',
      'published': true,
      'author_id': ada.id,
      'created_at': DateTime.now().toUtc(),
    }).run(db);

    // SELECT with WHERE + ORDER BY + LIMIT.
    final recentPosts = await Query<Post>(PostTable.metadata)
        .where(PostTable.published.eq(true))
        .orderBy(PostTable.createdAt, desc: true)
        .limit(10)
        .all(db);

    print('found ${recentPosts.length} published post(s)');

    // UPDATE … RETURNING.
    final updated = await Query<Post>(PostTable.metadata)
        .where(PostTable.id.eq(recentPosts.first.id!))
        .update({'title': 'On Analytical Engines (rev 2)'})
        .one(db);

    print('renamed post: ${updated.title}');

    // COUNT.
    final total = await Query<Post>(PostTable.metadata).count(db);
    print('post count: $total');

    // DELETE.
    await Query<Post>(PostTable.metadata)
        .where(PostTable.id.eq(updated.id!))
        .delete()
        .run(db);
  } finally {
    await db.close();
  }
}
```

Predicate operators you'll reach for most often (all on `ColumnRef<T>`):
`.eq` / `.neq` / `.gt` / `.gte` / `.lt` / `.lte` / `.like` / `.ilike` /
`.inList` / `.between(a, b)` / `.isNull` / `.isNotNull`. Combine with
`.and`, `.or`, `.not`. Compare two columns with `colA.eqExpr(colB)`.

Array columns are declared in YAML (e.g. `type: varchar[]`) and generate
`List<T>` fields plus `ColumnRef<List<T>>`, so containment works:

```yaml
Post:
  columns:
    tags:
      type: varchar[]
      default: '{}'
```

```dart
await Query<Post>(PostTable.metadata)
    .where(PostTable.tags.contains(['dart', 'orm']))
    .all(db);
```

Enums, CHECK constraints, and geometric columns (`point` / `box` / …) are
documented in the [README schema reference](README.md#schema-yaml-reference).

For the full operator catalogue (JSON navigation, array containment,
joins, group-by/having, raw SQL escape hatch), see the
[README query-building section](README.md#building-queries).

---

## 11. Add a relation and preload it

We declared `author: { type: Author }` on `Post`, so the generator
produced `Author.posts` and `Post.author`. Use `.preload(...)` to fetch
related rows in a **single batched query per level** instead of N+1.

```dart
final authors = await Query<Author>(AuthorTable.metadata)
    .preload([Author.posts])
    .all(db);

// Two queries total, regardless of how many authors there are:
//   SELECT … FROM "author"
//   SELECT … FROM "post" WHERE "author_id" IN ($1, $2, …)

for (final a in authors) {
  print('${a.name}: ${a.postsList.length} posts');  // typed accessor
  for (final p in a.postsList) {
    print('  - ${p.title}');
  }
}
```

Nested preloads chain with `.then(...)`:

```dart
await Query<Author>(AuthorTable.metadata)
    .preload([
      Author.posts.then(Post.comments),    // requires Comment in your schema
    ])
    .all(db);
// Three queries total — one per level.
```

For belongs-to, the typed accessor returns `T?` instead of `List<T>`:

```dart
final posts = await Query<Post>(PostTable.metadata)
    .preload([Post.author])
    .all(db);

print(posts.first.authorLoaded?.name);
```

The accessor name is derived from the relation field: a column named
`reviewers` becomes `reviewersList` for HasMany/M2M and `reviewersLoaded`
for HasOne/BelongsTo.

---

## 12. Wrap multiple writes in a transaction

Anything that has to commit-or-rollback as a unit goes through
`Database.transaction`. The same `Query<T>` API works against the
transactional context.

```dart
await db.transaction((tx) async {
  final author = await Query<Author>(AuthorTable.metadata)
      .insert({'name': 'Grace Hopper', 'email': 'grace@example.com'})
      .one(tx);

  for (final title in ['Compilers', 'COBOL', 'Nanoseconds']) {
    await Query<Post>(PostTable.metadata).insert({
      'title': title,
      'published': true,
      'author_id': author.id,
      'created_at': DateTime.now().toUtc(),
    }).run(tx);
  }

  // If any of the above throws, EVERY insert in this block rolls back.
  // Throwing inside the body is the idiomatic way to abort.
  if (author.email.contains('@bad.example')) {
    throw StateError('refusing to commit');
  }
});
```

Need a specific isolation level? Pass `TransactionSettings`:

```dart
await db.transaction(
  (tx) async => /* … */,
  settings: TransactionSettings(
    isolationLevel: IsolationLevel.serializable,
  ),
);
```

---

## 13. Evolve your schema with a new migration

Schemas change. Suppose you want to add a `slug` column to `Post`. Two
common workflows:

### Option A — regenerate the schema, hand-write the migration

Edit `lib/models/blog.gisila.yaml` to add the column:

```yaml
Post:
  columns:
    # …
    slug:
      type: varchar
      is_null: false
      is_unique: true
      is_index: true
```

Re-run the generator:

```bash
dart run gisila:generate
```

The `*.g.dart` updates immediately. **But `blog.gisila.up.sql` regenerates
to the *current* schema**, so you cannot use it as an incremental
migration — it's a full `CREATE TABLE` script. For incremental changes,
hand-write a new migration pair next to your YAML:

```bash
mkdir -p lib/models/migrations
```

`lib/models/migrations/0002_add_post_slug.up.sql`:

```sql
BEGIN;
ALTER TABLE "post" ADD COLUMN "slug" VARCHAR(255) NOT NULL DEFAULT '';
ALTER TABLE "post" ADD CONSTRAINT "post_slug_unique" UNIQUE ("slug");
CREATE INDEX "idx_post_slug" ON "post" ("slug");
COMMIT;
```

`lib/models/migrations/0002_add_post_slug.down.sql`:

```sql
BEGIN;
DROP INDEX IF EXISTS "idx_post_slug";
ALTER TABLE "post" DROP CONSTRAINT IF EXISTS "post_slug_unique";
ALTER TABLE "post" DROP COLUMN IF EXISTS "slug";
COMMIT;
```

Apply:

```bash
dart run gisila:migrate up --dir lib/models/migrations --config database.yaml
```

Roll back the most recent batch:

```bash
dart run gisila:migrate down --dir lib/models/migrations --steps 1
```

### Option B — diff two schema definitions programmatically

If you keep an **old** copy of your `SchemaDefinition` next to the new
one, `SchemaDiffer` can emit the incremental DDL automatically (handles
column renames, foreign-key add/drop, type and nullability changes):

```dart
final differ = SchemaDiffer();
final diff = differ.compareSchemas(oldSchema, newSchema);
await differ.generateMigrationFile(
  diff,
  'lib/models/migrations/',
  '0003_evolve_post',
);
```

This produces both `*.up.sql` and `*.down.sql` for you to review and
commit.

---

## 14. Write a unit test against MockDbContext

The fastest tests are the ones that never touch the database. gisila
ships `MockDbContext`, which captures every `(sql, params)` pair without
opening a connection.

`test/posts_query_test.dart`:

```dart
import 'package:gisila/gisila.dart';
import 'package:test/test.dart';

import '../lib/models/blog.gisila.g.dart';

void main() {
  test('listing published posts emits the expected SQL', () async {
    final mock = MockDbContext();

    await Query<Post>(PostTable.metadata)
        .where(PostTable.published.eq(true))
        .orderBy(PostTable.createdAt, desc: true)
        .limit(10)
        .all(mock);

    expect(mock.callCount, 1);
    expect(mock.sqls.single, contains('FROM "post"'));
    expect(mock.sqls.single, contains('WHERE'));
    expect(mock.sqls.single, contains('ORDER BY'));
    expect(mock.sqls.single, contains('LIMIT 10'));
    expect(mock.params.single, [true]);
  });
}
```

Run it:

```bash
dart test test/posts_query_test.dart
```

This pattern — *assert the exact SQL my code emits* — is invaluable for:

- Locking down query shape against accidental regressions.
- Asserting that preloading collapses N+1 into N+1 round-trips by
  checking `mock.callCount`.
- Keeping unit tests fast (no Docker, no network).

---

## 15. Write an integration test against real Postgres

For tests that exercise the actual SQL planner, gisila provides
`withTestDb`. It connects to a Postgres at `localhost:5454` (the port
used by the bundled `docker-compose.yml`), allocates a unique schema for
each test, and tears it down at the end. If no Postgres is reachable, it
returns `null` so your CI doesn't fail — the test should skip itself.

> The default port of `5454` matches gisila's own `docker-compose.yml`.
> If your Postgres is on `5432` (e.g. the one we set up in step 4),
> override with the `port:` argument or run a separate test container on
> 5454.

`test/posts_integration_test.dart`:

```dart
import 'package:gisila/gisila.dart';
import 'package:test/test.dart';

void main() {
  test('inserts persist across connections', () async {
    if (!await isTestDbAvailable()) {
      markTestSkipped('Postgres unreachable; skipping');
      return;
    }

    await withTestDb((db, schema) async {
      // Each test gets its own schema; the search_path is set
      // automatically on every pooled connection.
      await db.execute('''
        CREATE TABLE post (
          id BIGSERIAL PRIMARY KEY,
          title VARCHAR(255) NOT NULL
        )
      ''');

      await db.transaction((tx) async {
        await tx.execute(
          r'INSERT INTO post (title) VALUES ($1)',
          parameters: ['hello'],
        );
      });

      final res = await db.execute('SELECT COUNT(*)::int AS c FROM post');
      expect(res.first.toColumnMap()['c'], 1);
    });
  });
}
```

Run with the test container up:

```bash
docker compose up -d
dart test
```

For end-to-end testing of generated models, run your migration against
the test schema first:

```dart
await withTestDb((db, schema) async {
  final manager = MigrationManager(db);
  final migrations = await manager.discoverIn('lib/models');
  await manager.up(migrations);

  // …now use Query<Post>, Query<Author>, etc. against `db` …
});
```

---

## 16. Project layout recap

After completing this tutorial, your project looks like:

```
blog_demo/
├── bin/
│   └── blog_demo.dart                 # your app entry point
├── lib/
│   └── models/
│       ├── blog.gisila.yaml           # YOUR schema
│       ├── blog.gisila.g.dart         # generated models (commit)
│       ├── blog.gisila.up.sql         # generated initial DDL (commit)
│       ├── blog.gisila.down.sql       # generated tear-down DDL (commit)
│       └── migrations/
│           ├── 0002_add_post_slug.up.sql     # hand-written, incremental
│           └── 0002_add_post_slug.down.sql
├── test/
│   ├── posts_query_test.dart          # MockDbContext unit tests
│   └── posts_integration_test.dart    # withTestDb integration tests
├── database.yaml                      # connection config
├── docker-compose.yml                 # local Postgres
└── pubspec.yaml
```

Conventions worth keeping:

- **One YAML per bounded context (optional).** Multiple `*.gisila.yaml`
  files are merged into one project schema so `Post.author → User` can
  span files. Multi-file apps import `schema.gisila.g.dart`; single-file
  apps keep the stem (`blog.gisila.g.dart`).
- **Generated code is committed.** Treat `*.g.dart` and the two `*.sql`
  files as build artefacts that go into the repo, not throwaways. CI
  re-runs `dart run gisila_orm:generate` and fails if anything diverges.
  After switching to multi-file, delete old per-file `*.gisila.g.dart` /
  `.sql` next to the split YAML sources.
- **Hand-written migrations live in their own directory.** Keep them
  numbered (`0001_…`, `0002_…`) so the migration runner picks them up in
  a stable order.
- **`database.yaml` is committed for dev defaults; production uses
  `DATABASE_URL`.**

---

## 17. Where to go next

You now know enough to build a real application against gisila. To dig
deeper:

- [README — Schema YAML reference](README.md#schema-yaml-reference) for
  every column type, constraint, relation key, and index option.
- [README — Building queries](README.md#building-queries) for the full
  expression AST, joins, group-by/having, and the `RawSql<T>` escape
  hatch.
- [README — Eager loading](README.md#eager-loading-preload) for nested
  `.then(...)` chains and many-to-many specifics.
- [README — Migrations](README.md#migrations) for the
  `MigrationManager` programmatic API and tracking-table schema.
- [README — Error handling](README.md#error-handling) for the typed
  `PostgresException` hierarchy.
- [README — Architecture](README.md#architecture) for the one-page
  mental model of how YAML, codegen, query, and migrations connect.

Issues, questions, and PRs welcome.
