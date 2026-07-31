library gisila.test.dart_emitter_test;

import 'package:gisila_orm/generators/codegen/dart_emitter.dart';
import 'package:gisila_orm/generators/schema_parser.dart';
import 'package:test/test.dart';

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
}
