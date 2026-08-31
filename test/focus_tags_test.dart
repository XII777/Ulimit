import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';

import 'package:ulimit/data/db/app_database.dart';
import 'package:ulimit/data/focus_providers.dart';
import 'package:ulimit/data/focus_tags_provider.dart';

void main() {
  group('FocusTags', () {
    late AppDatabase db;
    late FocusTagsController controller;

    setUp(() {
      db = AppDatabase.connect(NativeDatabase.memory());
      controller = FocusTagsController(db);
    });

    tearDown(() => db.close());

    test('create / rename / recolor / delete round-trips', () async {
      final id = await controller.createTag(name: 'Deep Work', color: const Color(0xFFE5484D));
      var tag = await db.select(db.focusTags).getSingle();
      expect(tag.id, id);
      expect(tag.name, 'Deep Work');
      expect(tag.colorValue, 0xFFE5484D);

      await controller.renameTag(id, 'Deep Focus');
      tag = await db.select(db.focusTags).getSingle();
      expect(tag.name, 'Deep Focus');

      await controller.recolorTag(id, const Color(0xFF0091FF));
      tag = await db.select(db.focusTags).getSingle();
      expect(tag.colorValue, 0xFF0091FF);

      await controller.deleteTag(id);
      final rows = await db.select(db.focusTags).get();
      expect(rows, isEmpty);
    });

    test('coloredSessionTags setting defaults false', () async {
      final settings = await db.select(db.ulimitSettings).getSingle();
      expect(settings.coloredSessionTags, isFalse);
    });
  });

  group('Untimed sessions (until I turn it off)', () {
    late AppDatabase db;
    late FocusController controller;

    setUp(() {
      db = AppDatabase.connect(NativeDatabase.memory());
      controller = FocusController(db);
    });

    tearDown(() => db.close());

    test('startSession with null duration stores -1 and never auto-completes', () async {
      await controller.startSession(
        label: 'Deep Work',
        duration: null, // untimed
        blockedPackages: const [],
      );

      final session = await db.select(db.focusSessions).getSingle();
      expect(session.plannedSeconds, -1);
      expect(FocusClock.isUntimed(session), isTrue);
      expect(FocusClock.remainingSeconds(session, DateTime.now()), isNull);

      // finalizeIfDue must not complete an untimed session even long
      // after its "planned end".
      await controller.finalizeIfDue();
      final after = await db.select(db.focusSessions).getSingle();
      expect(after.endedAt, isNull);
      expect(after.completed, isFalse);
    });

    test('timed session still auto-completes via finalizeIfDue', () async {
      await controller.startSession(
        label: 'Study',
        duration: const Duration(seconds: 1),
        blockedPackages: const [],
      );

      await Future<void>.delayed(const Duration(milliseconds: 1500));
      await controller.finalizeIfDue();
      final session = await db.select(db.focusSessions).getSingle();
      expect(session.endedAt, isNotNull);
      expect(session.completed, isTrue);
    });
  });
}
