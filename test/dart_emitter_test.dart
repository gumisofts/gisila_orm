library gisila.test.dart_emitter_test;

import 'dart:convert';
import 'dart:io';

import 'package:gisila_orm/generators/codegen/dart_emitter.dart';
import 'package:gisila_orm/generators/codegen/sql_emitter.dart';
import 'package:gisila_orm/generators/schema_parser.dart';
import 'package:test/test.dart';

import 'support/test_db.dart';

void main() {
  group('Dart emitter foreign-key typing', () {
    test(
        "a belongs-to column's Dart type/coercion follow the referenced "
        "model's actual primary key type, not a hardcoded int", () {
      const yaml = '''
Payment:
  columns:
    id:
      type: uuid
      is_primary: true
      is_null: false
      default: gen_random_uuid()

Callback:
  columns:
    payment:
      type: Payment
      references: Payment
      is_null: false
''';

      final schema = SchemaDefinition.fromYaml(yaml);
      final dart = emitDart(schema);

      // Field declaration and constructor use String, not int.
      expect(dart, contains('final String paymentId;'));
      expect(dart, contains('required this.paymentId,'));

      // fromRow coerces the raw value as a String.
      expect(dart, contains("paymentId: row['payment_id'] as String,"));

      // ColumnRef is typed accordingly too.
      expect(
        dart,
        contains(
          'static const ColumnRef<String> paymentId = ColumnRef<String>(',
        ),
      );
    });

    test('a nullable belongs-to column stays nullable in the derived type', () {
      const yaml = '''
Payment:
  columns:
    id:
      type: uuid
      is_primary: true
      is_null: false
      default: gen_random_uuid()

Callback:
  columns:
    payment:
      type: Payment
      references: Payment
''';

      final schema = SchemaDefinition.fromYaml(yaml);
      final dart = emitDart(schema);

      expect(dart, contains('final String? paymentId;'));
      expect(dart, contains("paymentId: row['payment_id'] as String?,"));
    });

    test('a belongs-to column referencing a plain integer id stays int', () {
      const yaml = '''
Author:
  columns:
    name:
      type: varchar

Post:
  columns:
    author:
      type: Author
      references: Author
      is_null: false
''';

      final schema = SchemaDefinition.fromYaml(yaml);
      final dart = emitDart(schema);

      expect(dart, contains('final int authorId;'));
      expect(dart, contains("authorId: row['author_id'] as int,"));
    });

    test('FK YAML name ending in _id does not produce userIdId fields', () {
      const yaml = '''
User:
  columns:
    email:
      type: varchar

Employee:
  columns:
    user_id:
      type: foreign_key
      references: User
      is_null: false
''';

      final schema = SchemaDefinition.fromYaml(yaml);
      final dart = emitDart(schema);

      expect(dart, contains('final int userId;'));
      expect(dart, contains("userId: row['user_id'] as int,"));
      expect(dart, isNot(contains('userIdId')));
      expect(dart, isNot(contains('user_id_id')));
      // Relation accessor strips trailing _id from the logical name.
      expect(dart, contains('static final Relation<Employee, User> user ='));
    });

    test('unique belongs-to inverse is emitted as HasOneRelation', () {
      const yaml = '''
User:
  columns:
    email:
      type: varchar

Profile:
  columns:
    user:
      type: User
      references: User
      is_null: false
      is_unique: true
      reverse_name: profile
''';

      final schema = SchemaDefinition.fromYaml(yaml);
      final dart = emitDart(schema);

      expect(dart, contains('HasOneRelation<User, Profile>('));
      expect(dart, contains("childForeignKey: 'user_id',"));
      expect(dart, contains('Profile? get profileLoaded =>'));
      expect(dart, isNot(contains('HasManyRelation<User, Profile>')));
    });

    test('allow_blank: false emits validate() checks for string fields', () {
      const yaml = '''
User:
  columns:
    email:
      type: varchar
      is_null: false
      allow_blank: false
    nickname:
      type: varchar
      allow_blank: true
''';

      final schema = SchemaDefinition.fromYaml(yaml);
      final dart = emitDart(schema);

      expect(dart, contains('List<String> validate()'));
      expect(dart, contains("errors.add('User.email must not be blank')"));
      expect(dart, isNot(contains('User.nickname must not be blank')));
    });
  });

  test('toJson() output goes through jsonEncode and back (ORM-10)', () async {
    const yaml = '''
Event:
  columns:
    title:
      type: varchar
      is_null: false
    starts_at:
      type: timestamp
      is_null: false
    ends_on:
      type: date
''';
    final dart = emitDart(SchemaDefinition.fromYaml(yaml));
    // Run the generated model for real: a file under test/ resolves this
    // package's imports.
    final file = File('test/_tojson_probe_${pid}_test_tmp.dart');
    addTearDown(() {
      if (file.existsSync()) file.deleteSync();
    });
    file.writeAsStringSync('''
import 'dart:convert';
$dart
void main() {
  final e = Event(id: 1, title: 't',
      startsAt: DateTime.utc(2026, 10, 28, 9, 30), endsOn: null);
  final text = jsonEncode(e.toJson());
  final back = Event.fromJson(jsonDecode(text) as Map<String, dynamic>);
  print(text);
  print(back.startsAt.isAtSameMomentAs(e.startsAt));
  print(e.toRow()['starts_at'] is DateTime);
}
''');
    final r =
        await Process.run(Platform.resolvedExecutable, ['run', file.path]);
    expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
    final lines = (r.stdout as String).trim().split('\n');
    expect(lines[0], contains('"starts_at":"2026-10-28T09:30:00.000Z"'));
    expect(lines[1], 'true');
    expect(lines[2], 'true', reason: 'toRow keeps DateTime for the driver');
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('decimal stays exact and json takes any JSON value, through Postgres',
      () async {
    if (!await isTestDbAvailable()) {
      markTestSkipped('No Postgres reachable on localhost:5454');
      return;
    }
    const yaml = '''
Ledger:
  columns:
    amount:
      type: decimal
      is_null: false
    meta:
      type: json
    tags:
      type: json
      is_null: false
''';
    final schema = SchemaDefinition.fromYaml(yaml);
    final dart = emitDart(schema);
    expect(dart, contains('final String amount;'));
    expect(dart, contains('final Object? meta;'));

    final file = File('test/_ledger_probe_${pid}_test_tmp.dart');
    addTearDown(() {
      if (file.existsSync() && Platform.environment['KEEP_PROBE'] == null) {
        file.deleteSync();
      }
    });
    file.writeAsStringSync('''
import 'dart:convert';
import 'package:gisila_orm/migrations/migration_manager.dart';
import 'support/test_db.dart';
$dart
Future<void> main() async {
  await withTestDb((db, _) async {
    for (final sql in splitSqlStatements(${jsonEncode(emitUpSql(schema))})) {
      await db.execute(sql);
    }
    final rows = [
      Ledger(id: null, amount: '12345678901234.5678', meta: [1, {'a': 2}],
          tags: 'just a string'),
      Ledger(id: null, amount: '0.0001', meta: null, tags: {'k': [true]}),
    ];
    for (final r in rows) {
      final row = r.toRow()..remove('id');
      await Query<Ledger>(LedgerTable.metadata).insert(row).run(db.context());
    }
    final back = await Query<Ledger>(LedgerTable.metadata)
        .orderBy(LedgerTable.id)
        .all(db.context());
    for (final l in back) {
      print(jsonEncode(l.toJson(exclude: ['id'])));
    }
  });
}
''');
    if (Platform.environment['KEEP_PROBE'] != null) return;
    final r =
        await Process.run(Platform.resolvedExecutable, ['run', file.path]);
    expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
    final lines = (r.stdout as String).trim().split('\n');
    expect(jsonDecode(lines[0]), {
      'amount': '12345678901234.5678',
      'meta': [
        1,
        {'a': 2}
      ],
      'tags': 'just a string',
    });
    expect(jsonDecode(lines[1]), {
      'amount': '0.0001',
      'meta': null,
      'tags': {
        'k': [true]
      },
    });
  }, timeout: const Timeout(Duration(minutes: 2)));
}
