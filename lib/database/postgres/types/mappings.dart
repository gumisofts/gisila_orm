enum PostgresTypeMapping {
  boolean('bool'),
  smallInt('int'),
  int('int'),
  integer('int'),
  bigInt('int'),
  serial('int'),
  bigSerial('int'),
  decimal('double'),
  doublePrecision('double'),
  real('double'),
  char('String'),
  varchar('String'),
  text('String'),
  date('DateTime'),
  datetz('DateTime'),
  timestamp('DateTime'),
  timestamptz('DateTime'),
  time('Time'),
  timetz('Time'),

  interval('Duration'),
  uuid('String'),
  inet('String'),
  cidr('String'),
  macaddr('String'),
  json('Map<String,dynamic>'),
  jsonb('Map<String,dynamic>'),
  array('List<dynamic>'),
  bytea('Uint8List'),
  range('Range'),
  enumm('Enum'),

  point('Point'),
  line('Line'),
  box('Box'),
  circle('Circle'),
  lseg('Lseg'),

  /// pgvector `vector(n)` column type.
  vector('Vector');

  final String dartType;
  const PostgresTypeMapping(this.dartType);
}

enum ColumnsDataType {
  boolean('boolean'),
  smallInt('smallint'),
  int('int'),
  integer('integer'),
  bigInt('bigint'),
  serial('serial'),
  bigSerial('bigserial'),
  decimal('decimal'),
  doublePrecision('double precision'),
  real('numeric'),
  char('char'),
  varchar('varchar'),
  text('text'),
  date('date'),
  datetz('datetz'),
  timestamp('timestamp'),
  timestamptz('timestamptz'),
  time('time'),
  timetz('timetz'),

  interval('interval'),
  uuid('uuid'),
  inet('inet'),
  cidr('cidr'),
  macaddr('macaddr'),
  json('json'),
  jsonb('json'),
  array('array'),
  bytea('bytea'),
  range('range'),
  enumm('enum'),

  point('point'),
  line('line'),
  box('box'),
  circle('circle'),
  lseg('lseg'),

  vector('vector'),

  foreignKey('foreignKey');

  final String type;
  const ColumnsDataType(this.type);
}

String getDartType(String dbType) {
  final dbMappingType = {};
  PostgresTypeMapping.values
      .map((value) => value)
      .forEach((value) => dbMappingType[value.name] = value.dartType);

  return dbMappingType[dbType];
}
