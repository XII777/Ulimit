import 'package:drift/drift.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'db/app_database.dart';
import 'providers.dart';

/// All user-created focus tags, oldest first — shown in the Focus
/// screen's SESSION chip row after the built-in labels.
final focusTagsProvider = StreamProvider<List<FocusTag>>((ref) {
  final db = ref.watch(databaseProvider);
  final query = db.select(db.focusTags)
    ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]);
  return query.watch();
});

/// The user's yes/no for colored session tags (Settings → Appearance).
final coloredSessionTagsProvider = StreamProvider<bool>((ref) {
  final db = ref.watch(databaseProvider);
  return db.select(db.ulimitSettings).watchSingle().map((s) => s.coloredSessionTags);
});

class FocusTagsController {
  FocusTagsController(this._db);

  final AppDatabase _db;

  Future<int> createTag({required String name, required Color color}) async {
    return await _db.into(_db.focusTags).insert(FocusTagsCompanion.insert(
          name: name,
          colorValue: color.toARGB32(),
        ));
  }

  Future<void> renameTag(int id, String name) async {
    await (_db.update(_db.focusTags)..where((t) => t.id.equals(id)))
        .write(FocusTagsCompanion(name: Value(name)));
  }

  Future<void> recolorTag(int id, Color color) async {
    await (_db.update(_db.focusTags)..where((t) => t.id.equals(id)))
        .write(FocusTagsCompanion(colorValue: Value(color.toARGB32())));
  }

  Future<void> deleteTag(int id) async {
    await (_db.delete(_db.focusTags)..where((t) => t.id.equals(id))).go();
  }
}

final focusTagsControllerProvider = Provider<FocusTagsController>((ref) {
  return FocusTagsController(ref.watch(databaseProvider));
});
