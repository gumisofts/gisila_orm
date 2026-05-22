/// Pure-unit tests for the [Preloader] using [MockDbContext].
///
/// The whole point of [Preloader] is N+1 prevention: each preload level
/// must collapse into a single batched `WHERE fk IN (...)` query. These
/// tests assert exactly that, by counting the SQL statements the mock
/// receives.
library gisila.test.preloader_test;

import 'package:gisila_orm/gisila.dart';
import 'package:postgres/postgres.dart';
import 'package:test/test.dart';

import 'support/test_db.dart';

// ---------------------------------------------------------------------------
// Hand-rolled fixture models. Keeping them in the test file (instead of
// using the codegen output) lets us focus on the runtime behaviour
// without coupling the test to a particular generated shape.
// ---------------------------------------------------------------------------

class TestUser with Preloadable {
  final int id;
  final String email;
  TestUser({required this.id, required this.email});

  factory TestUser.fromRow(Map<String, dynamic> row) =>
      TestUser(id: row['id'] as int, email: row['email'] as String);

  Map<String, dynamic> toRow() => {'id': id, 'email': email};

  static final Relation<TestUser, TestPost> posts =
      HasManyRelation<TestUser, TestPost>(
    parentTable: 'users',
    childTable: 'posts',
    name: 'posts',
    childForeignKey: 'user_id',
    childMeta: TestPostTable.metadata,
  );
}

class TestUserTable {
  static const TableMeta<TestUser> metadata = TableMeta<TestUser>(
    tableName: 'users',
    columnNames: ['id', 'email'],
    fromRow: TestUser.fromRow,
  );
}

class TestPost with Preloadable {
  final int id;
  final int userId;
  final String title;
  TestPost({required this.id, required this.userId, required this.title});

  factory TestPost.fromRow(Map<String, dynamic> row) => TestPost(
        id: row['id'] as int,
        userId: row['user_id'] as int,
        title: row['title'] as String,
      );

  Map<String, dynamic> toRow() => {
        'id': id,
        'user_id': userId,
        'title': title,
      };

  static final Relation<TestPost, TestComment> comments =
      HasManyRelation<TestPost, TestComment>(
    parentTable: 'posts',
    childTable: 'comments',
    name: 'comments',
    childForeignKey: 'post_id',
    childMeta: TestCommentTable.metadata,
  );
}

class TestPostTable {
  static const TableMeta<TestPost> metadata = TableMeta<TestPost>(
    tableName: 'posts',
    columnNames: ['id', 'user_id', 'title'],
    fromRow: TestPost.fromRow,
  );
}

class TestComment with Preloadable {
  final int id;
  final int postId;
  final String body;
  TestComment({required this.id, required this.postId, required this.body});

  factory TestComment.fromRow(Map<String, dynamic> row) => TestComment(
        id: row['id'] as int,
        postId: row['post_id'] as int,
        body: row['body'] as String,
      );

  Map<String, dynamic> toRow() => {
        'id': id,
        'post_id': postId,
        'body': body,
      };
}

class TestCommentTable {
  static const TableMeta<TestComment> metadata = TableMeta<TestComment>(
    tableName: 'comments',
    columnNames: ['id', 'post_id', 'body'],
    fromRow: TestComment.fromRow,
  );
}

// ---------------------------------------------------------------------------
// In-memory result builder so the mock can return real ResultRows.
// ---------------------------------------------------------------------------

Result _resultFor(List<String> columns, List<List<Object?>> rows) {
  // text typeOid; the value matters only if the runtime tries to
  // re-encode rows, which it doesn't for our preload tests.
  const textOid = 25;
  final schema = ResultSchema([
    for (final c in columns)
      ResultSchemaColumn(typeOid: textOid, type: Type.text, columnName: c),
  ]);
  return Result(
    rows: [for (final r in rows) ResultRow(schema: schema, values: r)],
    affectedRows: rows.length,
    schema: schema,
  );
}

void main() {
  group('Preloader (HasMany)', () {
    test('runs exactly one batched IN query per preload level', () async {
      final users = [
        TestUser(id: 1, email: 'a@x.com'),
        TestUser(id: 2, email: 'b@x.com'),
        TestUser(id: 3, email: 'c@x.com'),
      ];

      final mock = MockDbContext(onExecute: (sql, params) {
        if (sql.contains('FROM "posts"')) {
          return _resultFor([
            'id',
            'user_id',
            'title'
          ], [
            [10, 1, 'p1'],
            [11, 1, 'p2'],
            [12, 2, 'p3'],
          ]);
        }
        return _resultFor(const [], const []);
      });

      await const Preloader()
          .applyTo(users.cast<Object>(), [TestUser.posts], mock);

      expect(mock.callCount, 1, reason: 'one batched IN query, never N+1');
      expect(mock.sqls.single, contains('FROM "posts"'));
      expect(mock.sqls.single, contains('"user_id" IN (\$1, \$2, \$3)'));
      expect(mock.params.single.toSet(), {1, 2, 3});

      expect(users[0].preloaded<List<TestPost>>('posts')!.length, 2);
      expect(users[1].preloaded<List<TestPost>>('posts')!.length, 1);
      expect(users[2].preloaded<List<TestPost>>('posts')!, isEmpty);
    });

    test('nested preload .then() resolves in N+1 levels of queries', () async {
      final users = [
        TestUser(id: 1, email: 'a@x.com'),
        TestUser(id: 2, email: 'b@x.com'),
      ];

      final mock = MockDbContext(onExecute: (sql, params) {
        if (sql.contains('FROM "posts"')) {
          return _resultFor([
            'id',
            'user_id',
            'title'
          ], [
            [10, 1, 'p1'],
            [11, 2, 'p2'],
          ]);
        }
        if (sql.contains('FROM "comments"')) {
          return _resultFor([
            'id',
            'post_id',
            'body'
          ], [
            [100, 10, 'c1'],
            [101, 10, 'c2'],
            [102, 11, 'c3'],
          ]);
        }
        return _resultFor(const [], const []);
      });

      await const Preloader().applyTo(
        users.cast<Object>(),
        [TestUser.posts.then(TestPost.comments)],
        mock,
      );

      // Two queries total: one for posts, one for all comments.
      expect(mock.callCount, 2);
      expect(mock.sqls[0], contains('FROM "posts"'));
      expect(mock.sqls[1], contains('FROM "comments"'));
      expect(mock.sqls[1], contains('"post_id" IN (\$1, \$2)'));

      final user1Posts = users[0].preloaded<List<TestPost>>('posts')!;
      expect(user1Posts.single.preloaded<List<TestComment>>('comments')!.length,
          2);
    });

    test('empty parents short-circuits and never hits the DB', () async {
      final mock = MockDbContext();
      await const Preloader().applyTo(<Object>[], [TestUser.posts], mock);
      expect(mock.callCount, 0);
    });
  });
}
