import 'dart:convert';

import 'package:drift/drift.dart';

/// JSON-encoded list-of-strings column. Used for package-name lists that
/// belong to a single row (focus-session policy, bedtime app selection).
class StringListConverter extends TypeConverter<List<String>, String> {
  const StringListConverter();

  @override
  List<String> fromSql(String fromDb) {
    if (fromDb.isEmpty) return const [];
    final decoded = jsonDecode(fromDb);
    return [for (final e in decoded as List<dynamic>) e as String];
  }

  @override
  String toSql(List<String> value) => jsonEncode(value);
}
