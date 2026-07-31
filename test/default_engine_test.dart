library gisila.test.default_engine_test;

import 'package:gisila_orm/database/types.dart';
import 'package:test/test.dart';

void main() {
  group('DefaultEngine DateTime aliases', () {
    const engine = DefaultEngine.instance;

    test('NOW() and CURRENT_* pass through uppercase', () {
      expect(engine.formatForSql('NOW()', 'DateTime'), 'NOW()');
      expect(
        engine.formatForSql('current_timestamp', 'DateTime'),
        'CURRENT_TIMESTAMP',
      );
      expect(engine.formatForSql('CURRENT_DATE', 'DateTime'), 'CURRENT_DATE');
    });

    test('bare now / NOW aliases become NOW()', () {
      expect(engine.formatForSql('now', 'DateTime'), 'NOW()');
      expect(engine.formatForSql('NOW', 'DateTime'), 'NOW()');
      expect(engine.formatForSql(' Now ', 'DateTime'), 'NOW()');
    });

    test('unrecognized timestamp strings stay quoted literals', () {
      final formatted = engine.formatForSql('yesterday', 'DateTime');
      expect(formatted, contains('yesterday'));
      expect(formatted, isNot('NOW()'));
    });
  });
}
