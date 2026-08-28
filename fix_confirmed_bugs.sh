#!/usr/bin/env bash
# Fixes 6 confirmed bugs:
#  1. Missing /settings route (crash on tab tap) -> real SettingsScreen + route
#  2. Duplicate limitScoreProvider (dead ScoreLog stub vs real weighted calc)
#     -> removed the dead stub from providers.dart
#  3. usage_tracker.dart bound milliseconds where Drift stores seconds
#     -> real usage/pickup data now actually matches typed reads
#  4. Raw fontFamily:'SpaceGrotesk' string (never registered) in
#     focus_screen.dart + bedtime_screen.dart -> GoogleFonts.spaceGrotesk()
#  5. Missing root android/build.gradle + missing launcher icons
#     -> both added (icons generated to match the app's ring motif/dark theme)
#  6. Deleted the actually-unused shared/widgets/mini_charts.dart
#     (note: trend_chart.dart is NOT dead -- home_screen.dart imports it live)
set -e

if [ ! -f pubspec.yaml ]; then
  echo "Run this from inside your repo root (where pubspec.yaml lives)."
  exit 1
fi

mkdir -p "lib/data"
cat > "lib/data/usage_tracker.dart" << 'PATCH_EOF'
import 'dart:async';
import 'package:drift/drift.dart';
import '../core/native/usage_events_channel.dart';
import 'db/app_database.dart';

/// Bridges native foreground-app events into real Drift rows. Started
/// once at app launch (see main.dart) and lives for the app's process
/// lifetime.
///
/// Model: on every new foreground event, attribute the elapsed time
/// since the *previous* event to the *previous* package — i.e. "how
/// long was the last app actually in front of the user." The very
/// first event in a session has nothing to attribute yet, so it's
/// stored and only resolved once the next transition arrives.
///
/// Known simplification: if a session spans midnight, the elapsed time
/// is attributed entirely to the day of the earlier timestamp rather
/// than split across the boundary. Acceptable for a v1 — the error is
/// bounded by one app's single foreground duration, not compounding.
class UsageTracker {
  UsageTracker(this._db);

  final AppDatabase _db;
  StreamSubscription<ForegroundEvent>? _sub;

  String? _pendingPackage;
  int? _pendingTimestampMillis;

  void start() {
    _sub = UsageEventsChannel.stream.listen(_onEvent, onError: (_) {
      // Accessibility service not enabled yet, or channel not ready —
      // fail silently rather than crash the app; permission screens
      // surface the "not granted" state explicitly elsewhere.
    });
  }

  void dispose() => _sub?.cancel();

  Future<void> _onEvent(ForegroundEvent event) async {
    final now = event.timestampMillis;

    if (_pendingPackage != null && _pendingTimestampMillis != null) {
      final elapsedSeconds = ((now - _pendingTimestampMillis!) / 1000).round();
      if (elapsedSeconds > 0 && elapsedSeconds < 6 * 3600) {
        // Discard >6h gaps — almost certainly a phone-asleep period the
        // OS didn't cleanly signal, not real foreground time.
        await _addUsage(_pendingPackage!, _pendingTimestampMillis!, elapsedSeconds);
      }
      // A genuine app switch (not the same package re-firing) is what
      // "pickups" counts.
      if (_pendingPackage != event.packageName) {
        await _incrementPickup(now);
      }
    } else {
      await _incrementPickup(now);
    }

    _pendingPackage = event.packageName;
    _pendingTimestampMillis = now;
  }

  Future<void> _addUsage(String package, int atMillis, int seconds) async {
    final day = _truncateToDay(DateTime.fromMillisecondsSinceEpoch(atMillis));
    // Real upsert leaning on the (packageName, day) unique key from the
    // schema: insert a fresh row, or atomically add to the existing
    // one's foreground_seconds. One statement, no read-then-write race.
    await _db.customStatement(
      '''
      INSERT INTO app_usage (package_name, day, foreground_seconds)
      VALUES (?, ?, ?)
      ON CONFLICT(package_name, day)
      DO UPDATE SET foreground_seconds = foreground_seconds + excluded.foreground_seconds
      ''',
      // Drift stores DateTimeColumn as unix *seconds* by default —
      // this raw customStatement bypasses Drift's automatic conversion,
      // so it must match that convention by hand or every typed read
      // elsewhere in the app silently never matches what gets written here.
      [package, day.millisecondsSinceEpoch ~/ 1000, seconds],
    );
  }

  Future<void> _incrementPickup(int atMillis) async {
    final day = _truncateToDay(DateTime.fromMillisecondsSinceEpoch(atMillis));
    final existing = await (_db.select(_db.pickupsLog)..where((t) => t.day.equals(day)))
        .getSingleOrNull();
    if (existing == null) {
      await _db.into(_db.pickupsLog).insert(PickupsLogCompanion.insert(day: day, count: const Value(1)));
    } else {
      await (_db.update(_db.pickupsLog)..where((t) => t.day.equals(day)))
          .write(PickupsLogCompanion(count: Value(existing.count + 1)));
    }
  }

  DateTime _truncateToDay(DateTime dt) => DateTime(dt.year, dt.month, dt.day);
}
PATCH_EOF

mkdir -p "lib/features/focus"
cat > "lib/features/focus/focus_screen.dart" << 'PATCH_EOF'
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../core/theme/tokens.dart';
import '../../shared/widgets/limit_ring.dart';

class FocusScreen extends StatefulWidget {
  const FocusScreen({super.key});

  @override
  State<FocusScreen> createState() => _FocusScreenState();
}

class _FocusScreenState extends State<FocusScreen> {
  static const _total = Duration(minutes: 25);
  Duration _remaining = _total;
  Timer? _ticker;

  // Placeholder — swap for a real todaysSessionsProvider (Drift query on
  // FocusSessions where startedAt is today) once that lands. Matches the
  // 3-dot pattern in the design: completed sessions filled, the current
  // one shown as an accent-to-calm gradient chip, empty slots as tracks.
  static const _completedSessions = 2;

  @override
  void initState() {
    super.initState();
    // A 1-second periodic timer is cheap — the ring's own repaint is
    // gated by shouldRepaint, so this doesn't cost more than one
    // CustomPainter.paint() per second, not per frame.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_remaining.inSeconds <= 0) {
        _ticker?.cancel();
        return;
      }
      setState(() => _remaining -= const Duration(seconds: 1));
    });
  }

  @override
  void dispose() {
    _ticker?.cancel(); // leaking this timer is the #1 cause of
    // "why does my app get slower the longer it's open" bug reports
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final progress = 1 - (_remaining.inSeconds / _total.inSeconds);

    return Container(
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          center: Alignment(0, -0.6),
          radius: 1.0,
          colors: [Color(0xFF191533), AppColors.bg],
        ),
      ),
      child: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 24),
            const _InvincibleChip(),
            const Spacer(),
            LimitRing(
              progress: progress,
              size: 220,
              strokeWidth: 12,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_format(_remaining), style: GoogleFonts.spaceGrotesk(
                    fontSize: 38,
                    fontWeight: FontWeight.w600,
                    color: AppColors.ink,
                  )),
                  const SizedBox(height: 6),
                  Text('Deep Work · remaining', style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
            const SizedBox(height: 20),
            const _LockNote(),
            const Spacer(),
            const _TodaysSessions(completed: _completedSessions, total: 3),
            const SizedBox(height: 20),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 110),
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: () => _confirmEndEarly(context),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.all(14),
                    backgroundColor: AppColors.surface2,
                    side: const BorderSide(color: AppColors.stroke),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.md)),
                  ),
                  child: const Text('End session early', style: TextStyle(color: AppColors.inkDim)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _format(Duration d) {
    final m = d.inMinutes.toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  void _confirmEndEarly(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      builder: (_) => const SizedBox(height: 160, child: Center(child: Text('Confirm sheet — wire to session provider'))),
    );
  }
}

class _InvincibleChip extends StatelessWidget {
  const _InvincibleChip();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.accent.withOpacity(0.14),
        border: Border.all(color: AppColors.accent.withOpacity(0.4)),
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.lock_rounded, size: 12, color: AppColors.accentSoft),
          SizedBox(width: 6),
          Text('Invincible mode on', style: TextStyle(fontSize: 11.5, color: AppColors.accentSoft)),
        ],
      ),
    );
  }
}

/// "12 apps paused · DND on" — reinforces what invincible mode is
/// actually doing while the ring runs, so the state isn't only
/// communicated once at the top of the screen.
class _LockNote extends StatelessWidget {
  const _LockNote();

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(Icons.notifications_off_rounded, size: 13, color: AppColors.inkFaint),
        const SizedBox(width: 6),
        Text('12 apps paused · DND on', style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 11.5)),
      ],
    );
  }
}

class _TodaysSessions extends StatelessWidget {
  const _TodaysSessions({required this.completed, this.total = 3});
  final int completed;
  final int total;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          "TODAY'S SESSIONS",
          style: Theme.of(context).textTheme.labelSmall,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (var i = 0; i < total; i++) ...[
              if (i > 0) const SizedBox(width: 6),
              _SessionDot(state: i < completed
                  ? _SessionState.done
                  : i == completed
                      ? _SessionState.active
                      : _SessionState.empty),
            ],
          ],
        ),
      ],
    );
  }
}

enum _SessionState { done, active, empty }

class _SessionDot extends StatelessWidget {
  const _SessionDot({required this.state});
  final _SessionState state;

  @override
  Widget build(BuildContext context) {
    switch (state) {
      case _SessionState.active:
        return Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [AppColors.accent, AppColors.calm],
            ),
            border: Border.all(color: AppColors.accent, width: 3),
          ),
        );
      case _SessionState.done:
        return Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: AppColors.accent.withOpacity(0.25),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppColors.accent),
          ),
          child: const Icon(Icons.check_rounded, size: 16, color: AppColors.accentSoft),
        );
      case _SessionState.empty:
        return Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: AppColors.surface2,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppColors.stroke),
          ),
        );
    }
  }
}
PATCH_EOF

mkdir -p "lib/features/bedtime"
cat > "lib/features/bedtime/bedtime_screen.dart" << 'PATCH_EOF'
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/theme/tokens.dart';
import '../../data/db/app_database.dart';
import '../../data/providers.dart';

class BedtimeScreen extends ConsumerWidget {
  const BedtimeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final schedule = ref.watch(bedtimeScheduleProvider);
    final db = ref.read(databaseProvider);

    return SafeArea(
      child: schedule.when(
        data: (row) => _buildBody(context, db, row),
        loading: () => const Center(child: CircularProgressIndicator(strokeWidth: 2)),
        error: (e, __) => Center(
          child: Text('Could not load bedtime settings: $e', style: Theme.of(context).textTheme.bodySmall),
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context, AppDatabase db, BedtimeScheduleData? row) {
    // No row yet (fresh install) — show the same defaults the first
    // toggle-write will actually create, so the screen doesn't flash
    // from one set of numbers to another once a toggle is touched.
    final startTime = row?.startTime ?? '22:30';
    final endTime = row?.endTime ?? '06:30';
    final dnd = row?.dndEnabled ?? true;
    final pauseApps = row?.pauseApps ?? true;
    final grayscale = row?.grayscale ?? false;
    final protectedHours = _hoursBetween(startTime, endTime);

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 100),
      children: [
        Text('Bedtime', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 4),
        Text('Scheduled · repeats every night', style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 12),

        Center(child: _MoonArc(progress: _nightProgress(startTime, endTime))),

        const SizedBox(height: 4),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(_formatTime(startTime), style: GoogleFonts.spaceGrotesk(
              fontSize: 22,
              fontWeight: FontWeight.w600,
              color: AppColors.ink,
            )),
            const SizedBox(width: 10),
            const Icon(Icons.arrow_forward_rounded, size: 16, color: AppColors.inkFaint),
            const SizedBox(width: 10),
            Text(_formatTime(endTime), style: GoogleFonts.spaceGrotesk(
              fontSize: 22,
              fontWeight: FontWeight.w600,
              color: AppColors.ink,
            )),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          '$protectedHours hours protected',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 11.5),
        ),
        const SizedBox(height: 20),

        Container(
          decoration: BoxDecoration(
            color: AppColors.surface,
            border: Border.all(color: AppColors.stroke),
            borderRadius: BorderRadius.circular(AppRadius.lg),
          ),
          child: Column(
            children: [
              _ToggleRow(
                label: 'Do Not Disturb',
                subtitle: 'Silence calls & notifications',
                value: dnd,
                onChanged: (v) => db.setDndEnabled(v),
              ),
              const Divider(height: 1, color: AppColors.stroke),
              _ToggleRow(
                label: 'Pause distracting apps',
                subtitle: 'Uses the same list as invincible mode',
                value: pauseApps,
                onChanged: (v) => db.setPauseApps(v),
              ),
              const Divider(height: 1, color: AppColors.stroke),
              _ToggleRow(
                label: 'Grayscale display',
                subtitle: 'Dims the pull to check',
                value: grayscale,
                onChanged: (v) => db.setGrayscale(v),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// "22:30" -> "10:30 PM". Schedule times are stored as "HH:mm" 24h
  /// strings (see BedtimeSchedule) rather than DateTime, since they
  /// repeat nightly and aren't tied to a specific date.
  String _formatTime(String hhmm) {
    final parts = hhmm.split(':');
    var h = int.parse(parts[0]);
    final m = parts[1];
    final suffix = h >= 12 ? 'PM' : 'AM';
    h = h % 12;
    if (h == 0) h = 12;
    return '$h:$m $suffix';
  }

  int _hoursBetween(String start, String end) {
    final s = _minutesSinceMidnight(start);
    final e = _minutesSinceMidnight(end);
    final diff = e >= s ? e - s : (24 * 60 - s) + e; // handles overnight wrap
    return (diff / 60).round();
  }

  double _nightProgress(String start, String end) {
    final now = DateTime.now();
    final nowMinutes = now.hour * 60 + now.minute;
    final s = _minutesSinceMidnight(start);
    final e = _minutesSinceMidnight(end);
    final total = e >= s ? e - s : (24 * 60 - s) + e;
    if (total <= 0) return 0;

    final elapsed = nowMinutes >= s
        ? nowMinutes - s
        : nowMinutes <= e
            ? (24 * 60 - s) + nowMinutes
            : null;
    if (elapsed == null) return 0; // outside the window right now
    return (elapsed / total).clamp(0.0, 1.0);
  }

  int _minutesSinceMidnight(String hhmm) {
    final parts = hhmm.split(':');
    return int.parse(parts[0]) * 60 + int.parse(parts[1]);
  }
}

/// Open half-arc (not a full [LimitRing]) representing tonight's
/// schedule window — deliberately a separate small painter rather than
/// stretching LimitRing to support open arcs, since LimitRing's contract
/// (full 0–2π sweep) is used correctly everywhere else and shouldn't
/// grow a special case for this one screen.
class _MoonArc extends StatelessWidget {
  const _MoonArc({required this.progress});
  final double progress;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 260,
      height: 140,
      child: CustomPaint(painter: _MoonArcPainter(progress: progress)),
    );
  }
}

class _MoonArcPainter extends CustomPainter {
  _MoonArcPainter({required this.progress});
  final double progress;

  static const _start = 3.14159; // 180deg
  static const _sweepTotal = 3.14159; // 180deg total arc

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height - 10);
    final radius = size.width / 2 - 10;
    final rect = Rect.fromCircle(center: center, radius: radius);

    canvas.drawArc(
      rect,
      _start,
      _sweepTotal,
      false,
      Paint()
        ..color = AppColors.stroke
        ..strokeWidth = 10
        ..strokeCap = StrokeCap.round
        ..style = PaintingStyle.stroke,
    );

    canvas.drawArc(
      rect,
      _start,
      _sweepTotal * progress.clamp(0.0, 1.0),
      false,
      Paint()
        ..color = AppColors.accent
        ..strokeWidth = 10
        ..strokeCap = StrokeCap.round
        ..style = PaintingStyle.stroke,
    );

    final dotPaint = Paint()..color = AppColors.ink;
    canvas.drawCircle(Offset(center.dx - radius, center.dy), 5, dotPaint);
    canvas.drawCircle(Offset(center.dx + radius, center.dy), 5, dotPaint);
  }

  @override
  bool shouldRepaint(_MoonArcPainter old) => old.progress != progress;
}

class _ToggleRow extends StatelessWidget {
  const _ToggleRow({
    required this.label,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => onChanged(!value),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontSize: 13.5)),
                  const SizedBox(height: 2),
                  Text(subtitle, style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 11)),
                ],
              ),
            ),
            Switch(
              value: value,
              onChanged: onChanged,
              activeColor: AppColors.bg,
              activeTrackColor: AppColors.accent,
              inactiveThumbColor: AppColors.inkFaint,
              inactiveTrackColor: AppColors.surface2,
              trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
            ),
          ],
        ),
      ),
    );
  }
}
PATCH_EOF

mkdir -p "lib/data"
cat > "lib/data/providers.dart" << 'PATCH_EOF'
import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'db/app_database.dart';
import 'db/tables.dart';

/// Single DB instance for the app's lifetime. `keepAlive` so switching
/// tabs doesn't tear down and reopen the SQLite connection — that
/// reopen cost is exactly the kind of jank a "don't make it lag"
/// requirement is about.
final databaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(db.close);
  return db;
});

DateTime _startOfDay(DateTime d) => DateTime(d.year, d.month, d.day);

/// Today's total foreground time across all tracked apps, as a live
/// stream — Drift's .watch() pushes updates only when the underlying
/// rows change, so the ring on Home updates in real time without
/// polling.
final todayScreenTimeProvider = StreamProvider<Duration>((ref) {
  final db = ref.watch(databaseProvider);
  final startOfDay = _startOfDay(DateTime.now());

  final query = db.select(db.appUsage)..where((t) => t.day.equals(startOfDay));

  return query.watch().map(
        (rows) => Duration(seconds: rows.fold(0, (sum, r) => sum + r.foregroundSeconds)),
      );
});

/// Last 7 days of total foreground time, oldest first — feeds Home's
/// weekly trend chart. One GROUP-BY-shaped query instead of 7 separate
/// day lookups.
final weeklyScreenTimeProvider = StreamProvider<List<Duration>>((ref) {
  final db = ref.watch(databaseProvider);
  final today = _startOfDay(DateTime.now());
  final start = today.subtract(const Duration(days: 6));

  final query = db.select(db.appUsage)..where((t) => t.day.isBiggerOrEqualValue(start));

  return query.watch().map((rows) => _bucketByDay(rows.map((r) => (r.day, r.foregroundSeconds)), start));
});

/// The 7 days before [weeklyScreenTimeProvider]'s window — used only to
/// compute the "vs last week" delta shown next to the weekly chart, so
/// that delta is a real comparison rather than a made-up percentage.
final previousWeekScreenTimeAvgProvider = StreamProvider<Duration>((ref) {
  final db = ref.watch(databaseProvider);
  final today = _startOfDay(DateTime.now());
  final start = today.subtract(const Duration(days: 13));
  final end = today.subtract(const Duration(days: 6));

  final query = db.select(db.appUsage)
    ..where((t) => t.day.isBiggerOrEqualValue(start) & t.day.isSmallerThanValue(end));

  return query.watch().map((rows) {
    final total = rows.fold(0, (sum, r) => sum + r.foregroundSeconds);
    return Duration(seconds: total ~/ 7);
  });
});

/// Last 7 days of completed-focus-session time, oldest first. Falls
/// back to `plannedSeconds` for a session with no `endedAt` yet (in
/// progress) so an active session doesn't read as zero minutes.
final weeklyFocusTimeProvider = StreamProvider<List<Duration>>((ref) {
  final db = ref.watch(databaseProvider);
  final today = _startOfDay(DateTime.now());
  final start = today.subtract(const Duration(days: 6));

  final query = db.select(db.focusSessions)
    ..where((t) => t.completed.equals(true) & t.startedAt.isBiggerOrEqualValue(start));

  return query.watch().map((rows) {
    final entries = rows.map((r) {
      final seconds = r.endedAt != null ? r.endedAt!.difference(r.startedAt).inSeconds : r.plannedSeconds;
      return (r.startedAt, seconds);
    });
    return _bucketByDay(entries, start);
  });
});

/// Previous-week counterpart to [weeklyFocusTimeProvider], for its delta.
final previousWeekFocusTimeAvgProvider = StreamProvider<Duration>((ref) {
  final db = ref.watch(databaseProvider);
  final today = _startOfDay(DateTime.now());
  final start = today.subtract(const Duration(days: 13));
  final end = today.subtract(const Duration(days: 6));

  final query = db.select(db.focusSessions)
    ..where((t) =>
        t.completed.equals(true) & t.startedAt.isBiggerOrEqualValue(start) & t.startedAt.isSmallerThanValue(end));

  return query.watch().map((rows) {
    final total = rows.fold<int>(0, (sum, r) {
      final seconds = r.endedAt != null ? r.endedAt!.difference(r.startedAt).inSeconds : r.plannedSeconds;
      return sum + seconds;
    });
    return Duration(seconds: total ~/ 7);
  });
});

/// Count of focus sessions completed so far today — feeds both Home's
/// "N sessions" pill and Focus's "today's sessions" dot row.
final todaysCompletedSessionsProvider = StreamProvider<int>((ref) {
  final db = ref.watch(databaseProvider);
  final start = _startOfDay(DateTime.now());
  final end = start.add(const Duration(days: 1));

  final query = db.select(db.focusSessions)
    ..where((t) =>
        t.completed.equals(true) & t.startedAt.isBiggerOrEqualValue(start) & t.startedAt.isSmallerThanValue(end));

  return query.watch().map((rows) => rows.length);
});

/// Turns a stream of (day, seconds) rows into a fixed 7-slot list
/// starting at [start], zero-filling any day with no rows. Shared by
/// both weekly providers above so "bucket into a 7-day window" is
/// implemented once.
List<Duration> _bucketByDay(Iterable<(DateTime, int)> entries, DateTime start) {
  final byDay = <DateTime, int>{for (var i = 0; i <= 6; i++) start.add(Duration(days: i)): 0};
  for (final (day, seconds) in entries) {
    final d = _startOfDay(day);
    byDay[d] = (byDay[d] ?? 0) + seconds;
  }
  final orderedDays = byDay.keys.toList()..sort();
  return [for (final d in orderedDays) Duration(seconds: byDay[d]!)];
}

/// One restriction group with today's live usage joined in. Replaces
/// the Limits screen's hardcoded group list — `packageNames` drives the
/// icon row, `usedSeconds`/`limitSeconds` drive the bar and its color.
class RestrictionGroupView {
  const RestrictionGroupView({
    required this.name,
    required this.usedSeconds,
    required this.limitSeconds,
    required this.invincible,
    required this.packageNames,
  });

  final String name;
  final int usedSeconds;
  final int limitSeconds;
  final bool invincible;
  final List<String> packageNames;
}

final restrictionGroupsProvider = StreamProvider<List<RestrictionGroupView>>((ref) {
  final db = ref.watch(databaseProvider);
  final today = _startOfDay(DateTime.now());

  // One joined query rather than combining separate group/usage streams
  // — keeps this a single reactive source instead of hand-rolled stream
  // combination.
  final query = db.customSelect(
    '''
    SELECT rg.id AS group_id, rg.name AS name, rg.daily_limit_seconds AS daily_limit_seconds,
           rg.invincible AS invincible, rga.package_name AS package_name,
           COALESCE(usage.foreground_seconds, 0) AS pkg_seconds
    FROM restriction_groups rg
    LEFT JOIN restriction_group_apps rga ON rga.group_id = rg.id
    LEFT JOIN app_usage usage ON usage.package_name = rga.package_name AND usage.day = ?
    ORDER BY rg.id
    ''',
    variables: [Variable.withDateTime(today)],
    readsFrom: {db.restrictionGroups, db.restrictionGroupApps, db.appUsage},
  );

  return query.watch().map((rows) {
    final byGroup = <int, _MutableGroup>{};
    final order = <int>[];

    for (final row in rows) {
      final id = row.read<int>('group_id');
      final group = byGroup.putIfAbsent(id, () {
        order.add(id);
        return _MutableGroup(
          name: row.read<String>('name'),
          limitSeconds: row.read<int>('daily_limit_seconds'),
          invincible: row.read<bool>('invincible'),
        );
      });

      final pkg = row.readNullable<String>('package_name');
      if (pkg != null) {
        group.packageNames.add(pkg);
        group.usedSeconds += row.read<int>('pkg_seconds');
      }
    }

    return [for (final id in order) byGroup[id]!.toView()];
  });
});

class _MutableGroup {
  _MutableGroup({required this.name, required this.limitSeconds, required this.invincible});
  final String name;
  final int limitSeconds;
  final bool invincible;
  int usedSeconds = 0;
  final List<String> packageNames = [];

  RestrictionGroupView toView() => RestrictionGroupView(
        name: name,
        usedSeconds: usedSeconds,
        limitSeconds: limitSeconds,
        invincible: invincible,
        packageNames: packageNames,
      );
}

/// Count of enabled entries in [BlockedApps] — feeds the "App Blocking"
/// control tile's subtitle on Home.
final blockedAppsCountProvider = StreamProvider<int>((ref) {
  final db = ref.watch(databaseProvider);
  final query = db.select(db.blockedApps)..where((t) => t.enabled.equals(true));
  return query.watch().map((rows) => rows.length);
});

/// The single [BedtimeSchedule] row (singleton, like [Profile]) — null
/// until the first toggle write creates it.
final bedtimeScheduleProvider = StreamProvider<BedtimeScheduleData?>((ref) {
  final db = ref.watch(databaseProvider);
  final query = db.select(db.bedtimeSchedule)..limit(1);
  return query.watch().map((rows) => rows.isEmpty ? null : rows.first);
});

extension BedtimeScheduleActions on AppDatabase {
  Future<void> _ensureBedtimeRow() async {
    final existing = await (select(bedtimeSchedule)..limit(1)).getSingleOrNull();
    if (existing == null) {
      await into(bedtimeSchedule).insert(
        BedtimeScheduleCompanion.insert(startTime: '22:30', endTime: '06:30'),
      );
    }
  }

  Future<void> setDndEnabled(bool value) async {
    await _ensureBedtimeRow();
    await update(bedtimeSchedule).write(BedtimeScheduleCompanion(dndEnabled: Value(value)));
  }

  Future<void> setPauseApps(bool value) async {
    await _ensureBedtimeRow();
    await update(bedtimeSchedule).write(BedtimeScheduleCompanion(pauseApps: Value(value)));
  }

  Future<void> setGrayscale(bool value) async {
    await _ensureBedtimeRow();
    await update(bedtimeSchedule).write(BedtimeScheduleCompanion(grayscale: Value(value)));
  }
}
PATCH_EOF

mkdir -p "lib/features/settings"
cat > "lib/features/settings/settings_screen.dart" << 'PATCH_EOF'
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/theme/tokens.dart';
import '../../data/permissions_providers.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final permissions = ref.watch(allPermissionsProvider);

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 100),
        children: [
          Text('Settings', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 4),
          Text('Local profile · not synced', style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 20),

          _SectionLabel('PERMISSIONS'),
          const SizedBox(height: 8),
          _Card(
            children: [
              for (final p in permissions)
                _PermissionRow(
                  label: _labelFor(p.kind),
                  granted: p.granted,
                  loading: p.loading,
                ),
            ],
          ),
          const SizedBox(height: 20),

          _SectionLabel('DATA'),
          const SizedBox(height: 8),
          const _Card(
            children: [
              _NavRow(icon: Icons.save_alt_rounded, label: 'Backup to file'),
              _RowDivider(),
              _NavRow(icon: Icons.file_upload_rounded, label: 'Restore from file'),
            ],
          ),
          const SizedBox(height: 20),

          _SectionLabel('ABOUT'),
          const SizedBox(height: 8),
          const _Card(
            children: [
              _NavRow(icon: Icons.star_rounded, label: 'Rate Ulimit'),
              _RowDivider(),
              _NavRow(icon: Icons.privacy_tip_rounded, label: 'Privacy policy'),
              _RowDivider(),
              _StaticRow(label: 'Version', value: '0.1.0'),
            ],
          ),
          const SizedBox(height: 20),

          Center(
            child: TextButton(
              onPressed: () {}, // wire to a confirm dialog + AppDatabase wipe
              child: const Text('Reset all data', style: TextStyle(color: AppColors.danger, fontSize: 12.5)),
            ),
          ),
        ],
      ),
    );
  }

  String _labelFor(PermissionKind kind) => switch (kind) {
        PermissionKind.accessibility => 'Accessibility',
        PermissionKind.vpn => 'VPN & network',
        PermissionKind.deviceAdmin => 'Device admin',
        PermissionKind.notificationListener => 'Notification access',
        PermissionKind.biometric => 'Biometrics',
      };
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Text(text, style: Theme.of(context).textTheme.labelSmall);
}

class _Card extends StatelessWidget {
  const _Card({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.stroke),
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: Column(children: children),
    );
  }
}

class _RowDivider extends StatelessWidget {
  const _RowDivider();
  @override
  Widget build(BuildContext context) => const Divider(height: 1, color: AppColors.stroke);
}

class _PermissionRow extends StatelessWidget {
  const _PermissionRow({required this.label, required this.granted, required this.loading});
  final String label;
  final bool granted;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          Expanded(child: Text(label, style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontSize: 13))),
          if (loading)
            const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2))
          else
            Text(
              granted ? 'Granted' : 'Pending',
              style: TextStyle(fontSize: 10.5, color: granted ? AppColors.accent : AppColors.alert),
            ),
        ],
      ),
    );
  }
}

class _NavRow extends StatelessWidget {
  const _NavRow({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () {},
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        child: Row(
          children: [
            Icon(icon, size: 16, color: AppColors.inkDim),
            const SizedBox(width: 12),
            Expanded(child: Text(label, style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontSize: 13))),
            const Icon(Icons.chevron_right_rounded, size: 16, color: AppColors.inkFaint),
          ],
        ),
      ),
    );
  }
}

class _StaticRow extends StatelessWidget {
  const _StaticRow({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      child: Row(
        children: [
          Expanded(child: Text(label, style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontSize: 13))),
          Text(value, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}
PATCH_EOF

mkdir -p "lib/core/router"
cat > "lib/core/router/app_router.dart" << 'PATCH_EOF'
import 'package:go_router/go_router.dart';
import '../../shared/widgets/nav_shell.dart';
import '../../features/home/home_screen.dart';
import '../../features/focus/focus_screen.dart';
import '../../features/limits/limits_screen.dart';
import '../../features/bedtime/bedtime_screen.dart';
import '../../features/settings/settings_screen.dart';
import 'morph_transition.dart';

/// Route paths as constants — avoids magic strings scattered across
/// 15+ screens and makes renames a one-line change.
abstract final class Routes {
  static const home = '/';
  static const focus = '/focus';
  static const limits = '/limits';
  static const bedtime = '/bedtime';
  static const settings = '/settings';
}

final appRouter = GoRouter(
  initialLocation: Routes.home,
  routes: [
    // ShellRoute keeps the floating nav bar mounted across tab switches
    // instead of rebuilding it (and its icons/animations) on every nav —
    // this is the single biggest jank source in bottom-nav apps that get
    // it wrong.
    ShellRoute(
      builder: (context, state, child) => NavShell(child: child),
      routes: [
        GoRoute(
          path: Routes.home,
          pageBuilder: (context, state) => CustomTransitionPage(
            key: state.pageKey,
            child: const HomeScreen(),
            transitionsBuilder: (_, animation, __, child) =>
                tabMorph(child, animation),
          ),
        ),
        GoRoute(
          path: Routes.focus,
          pageBuilder: (context, state) => CustomTransitionPage(
            key: state.pageKey,
            child: const FocusScreen(),
            transitionsBuilder: (_, animation, __, child) =>
                tabMorph(child, animation),
          ),
        ),
        GoRoute(
          path: Routes.limits,
          pageBuilder: (context, state) => CustomTransitionPage(
            key: state.pageKey,
            child: const LimitsScreen(),
            transitionsBuilder: (_, animation, __, child) =>
                tabMorph(child, animation),
          ),
        ),
        GoRoute(
          path: Routes.bedtime,
          pageBuilder: (context, state) => CustomTransitionPage(
            key: state.pageKey,
            child: const BedtimeScreen(),
            transitionsBuilder: (_, animation, __, child) =>
                tabMorph(child, animation),
          ),
        ),
        GoRoute(
          path: Routes.settings,
          pageBuilder: (context, state) => CustomTransitionPage(
            key: state.pageKey,
            child: const SettingsScreen(),
            transitionsBuilder: (_, animation, __, child) =>
                tabMorph(child, animation),
          ),
        ),
      ],
    ),
    // Detail screens (App Limits detail, Internet & Sites, blocking
    // overlay, etc.) push OUTSIDE the shell using MorphPage so the nav
    // bar correctly disappears rather than fighting a full-screen modal.
  ],
);
PATCH_EOF

mkdir -p "android"
cat > "android/build.gradle" << 'PATCH_EOF'
buildscript {
    repositories {
        google()
        mavenCentral()
    }
}

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.buildDir = "../build"
subprojects {
    project.buildDir = "${rootProject.buildDir}/${project.name}"
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register("clean", Delete) {
    delete rootProject.buildDir
}
PATCH_EOF

mkdir -p "android/app/src/main/res/mipmap-anydpi-v26"
cat > "android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml" << 'PATCH_EOF'
<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@mipmap/ic_launcher_background" />
    <foreground android:drawable="@mipmap/ic_launcher_foreground" />
</adaptive-icon>
PATCH_EOF

mkdir -p "android/app/src/main/res/mipmap-mdpi"
base64 -d > "android/app/src/main/res/mipmap-mdpi/ic_launcher.png" << 'B64_EOF'
iVBORw0KGgoAAAANSUhEUgAAADAAAAAwCAYAAABXAvmHAAABh0lEQVR4nO2ZsQ0CMQxFD0SPaOgQ
DTWrILEAGzABJROwAQsgsQo1DWIQqE46RRfH/v4hOXS/PWL8EjuJncl8sfw0A9a0tANejQClNQKU
1uABZrkMn46P6LfzZUv7n0mOc0ByPpQXhh5Cq/XG9PvT8WECDkUDWK03Zue7QiHcIRRz+rC7Qfas
IeUCsMy4BcgCAQNIzr9fT3GMBkYLAQH0OR9zWrIhgWgBzEnMcL4dc73vo9+1SW0CYDnfHStBaOTa
Rj3Od23EIDSroAYIZ5/hPMNWNZc5NJRUAJ4T1qtUGEErwAwfr81qQqhpsDCqCgBRsqAJY9C7b7Ml
rkBfAqG3zFyqKoSQyYEAcmyrqM2qVgCRCBC70ubIg5jN1LUaXgFPIR7KE5JJAGkGGLmQKmxScuXA
YXdzQTCqMhWAZAiFYJWUlNZi60h7SjOKeq1MRb0lccMrRzVtFebu06efNLZyQKBNXldnjgXi6VBT
2usoCOOdgPo+oAWp/oHjl/rv2+gQNAKU1ghQWl/OZJHvtEu8xAAAAABJRU5ErkJggg==
B64_EOF

mkdir -p "android/app/src/main/res/mipmap-mdpi"
base64 -d > "android/app/src/main/res/mipmap-mdpi/ic_launcher_foreground.png" << 'B64_EOF'
iVBORw0KGgoAAAANSUhEUgAAAGwAAABsCAYAAACPZlfNAAACtklEQVR4nO3cwVHcQBCF4baLIByE
Dz6TBFUkQBScKZ+JggSoIgnOHAiCLOA0tixL2pnRqPv17v+dl9Uwb7t3pJHWDAAAAAAAAAAAAAAA
AAAAABfpW/QARnt8+Pised397x8p//fv0QMYqTas1tcqSfkpWzIigAxVdxYVNqpaMlTdWQQ20uPD
x6dycAS2QjU0+Z695uev6z8TenfzfOixlL7bZAZSYxrS1NGBmemElqYlroVlZvb0cnv48VVapMSn
ZstWUHOXUGnSFdYSlplPpUWTrbDWsGqMqsDIKpMM7Iiw5vaGFxWaXGAeYU3tCS4itCvvA27ZE9b7
2+vm5K2999PLrctiZRSZCusJ61RIrcfqCc67yqRXiVt6w9r7t9EkBt5SXaMne35s9SoLr7DIsJbe
s+dczvMqSHhgtY5sY5laZJrAPClfMQkNrLYdelTAiNboQb7CPNvVnmN5fY/JB4Z/hQXmfQnqXEhX
WMTqbXpMxe8x6cDwPwJLxv1q/dJqSrH1qHKtsLWlb6btjWhugZ06TyG0Oi6B1Z5UEtppLDqSkQ4s
4uRa/YReOrBoii1aLjDFSarhtevsEljrPzMNzbNFqbdDM8EKW+IxkSPu7fCQIjD85RbYnrZodmyV
7a2ui7prqsURoWVphYX7flPrVvraheG9e2VL4feGRYVNrE3inmrLGpZZ0J2/PTesnNqC6X0YwizX
EyxhN1D23mU0cu8s4zNi8i1xbsSi4O7mOWVYZsEPQ4y6l6+m6kav/i4yMDOdn1NoEfmMc3hLjP4Z
hVbR4w0PzCx+EmopjDN8AFOq7VEhqEKiwgqliSnUxiQVmJnWBCmNpZAbUBHZHhWDKuQqrIiaNOWw
zIQrbO7oilMPqkgxyKkjgssSllnCwKZ6w8sUEAAAAAAAAAAAAAAAAAAAAGBmZl9VfwbwVasibgAA
AABJRU5ErkJggg==
B64_EOF

mkdir -p "android/app/src/main/res/mipmap-mdpi"
base64 -d > "android/app/src/main/res/mipmap-mdpi/ic_launcher_background.png" << 'B64_EOF'
iVBORw0KGgoAAAANSUhEUgAAAGwAAABsCAYAAACPZlfNAAABF0lEQVR4nO3RwQnAIADAwNoFxI/7
b2pn6EsCdxMEMuba5yHjvR3AP4bFGBZjWIxhMYbFGBZjWIxhMYbFGBZjWIxhMYbFGBZjWIxhMYbF
GBZjWIxhMYbFGBZjWIxhMYbFGBZjWIxhMYbFGBZjWIxhMYbFGBZjWIxhMYbFGBZjWIxhMYbFGBZj
WIxhMYbFGBZjWIxhMYbFGBZjWIxhMYbFGBZjWIxhMYbFGBZjWIxhMYbFGBZjWIxhMYbFGBZjWIxh
MYbFGBZjWIxhMYbFGBZjWIxhMYbFGBZjWIxhMYbFGBZjWIxhMYbFGBZjWIxhMYbFGBZjWIxhMYbF
GBZjWIxhMYbFGBZjWIxhMYbFGBZjWIxhMYbFGBbzAVHfAg1TcDw8AAAAAElFTkSuQmCC
B64_EOF

mkdir -p "android/app/src/main/res/mipmap-hdpi"
base64 -d > "android/app/src/main/res/mipmap-hdpi/ic_launcher.png" << 'B64_EOF'
iVBORw0KGgoAAAANSUhEUgAAAEgAAABICAYAAABV7bNHAAACSElEQVR4nO2bsU0EMRBFfYgckZCd
LrmYVpBogA6o4EIqoAMaQKIVYhJEIRAtWlbLfo/9/9jyzZfIWI/v7R/ba493V9c33yn0ry5ad6B3
BSCgAAQUgIACEFAAAgpAQAEIKAABBSCgy9YdmHR6fIf/8/R869CTv9r18C2WA2cpL1jNU6wETs1z
VjVNsf3hWPX8HJLKUe4O2h+Ov39MqRzlNgZtAXm4e6XFYTtJDijXKb1CkgKqTaMaaCxIMkDsMaYE
FgOSBJAFztfnh7ktC6xaSHRAOXAQlNy2c0HVQKICQnBKwWzFUUOirYO84Czbenm7p7W7JgogTzhr
beZAKl1IylfSCjgebU+qBrTlHo8fMMVQpZrMQR5wlrEQpJI0qwLEXgz2KImDPN2jjtl8w4wtdpoV
AzqH9EpJ4KAW6aWMPVyKpcSd8ocExFQAAio61VjOBOoPxpYyO2htmmTuJ/cmE6CtNcSokIYcg5gv
iw6o5QJSEXtIBzE1HCD2WGgChDa+p861SLPcmNbNe7qDRpvNZCnm6aIpluLlmAHlWNQz1SwxSs7G
5IO0EpLlANH14NDiopQ0kEpOV0tUdfScs305/5BlHz17nM3LU2zppBo3zZ/3gJMSoXjBugm+3Bo5
i/KXWki5so41XRVQlRYHbMEargTPq7gbiVnESR2kW9ylUPdBVsTZwk2KFySb5r3dpIonLyRXO0n9
ItyuIjBBebqzyX2xGljeqdvFhbqeNdyeNFsBCCgAAQUgoAAEFICAAhBQAAIKQEABCOgHzw3UQwan
8jAAAAAASUVORK5CYII=
B64_EOF

mkdir -p "android/app/src/main/res/mipmap-hdpi"
base64 -d > "android/app/src/main/res/mipmap-hdpi/ic_launcher_foreground.png" << 'B64_EOF'
iVBORw0KGgoAAAANSUhEUgAAAKIAAACiCAYAAADC8hYbAAAEO0lEQVR4nO3dzW3bQBCG4UmQIlKE
Dz67iQBuIFXkbOTsKtyAATeRcw4pwl0oB2EDmpHEJbm7nG/mfe6Jl9LLIakfygwAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAPj06egFqHp+ej9t+Xc/fn7lMb+AB2WlrQHOEeRHPBgr
tIpwjigJsVqvCKcyB5l2w9caEeJUtig/H70ABaMjPOpvHokQHXt+ej9lCZIQBWSIMdV5yFp39w8n
M7Pv316PXso/Uc8dQ27UHiW+KU8hmsWMMdwGbXUpwCli7Cv9OeLd/cNpKUKPop03htqr1tgSn7ep
aBZnMqaciFsn4MvbY+ul7BZlMn45egEjtTgElxg9TkdlIcZ6jVHngUcGqnyYTjERR16MXDp8Mz2X
ye5BtTxdEY8IUnUqSi66lqcI53pGqRhj2KtmzxGanQ/hHq/CjyK359TwHuElrSek2lSUWmyN3hH+
+f2r6jHz8IK5Uowprpr3qo3v2r+pjfLl7THtFbbMHlOj9TTcEuAttetrGaPKVAwzEVtG2DrA+f+r
eA7bm8TeUqPVk9srwrma9baajApTMcREbBHhqADnf4/peBb2dcQ1RkdY+7czvc4oH+LeiXJkhDVr
aBGjwkfF5ENEDNIhRpiGRe+1eJ+K0iHu4SnC4tqaMpwrpg1RTfQYZUPcc1j2OA2LnmvzfHiWDRGx
pAvR8zQsFNbYWroQlUU+T5QMkbfF4pEMcSulQ162l3JShQi/CBEuECJckPo84rUXZKOeN2UiEeLS
OwLlk8wEqcv9oXnN21JZvwEXgesQt7w3SoyaXIeI/0Xd0dyGuOeTIlGfrMjchtiD0luDSmttIVWI
8IsQ4UK6EBUOedfWGPnc122Ie2+TEflJ28rzrUfchtiT56noeW09pQxRUfQJ7zrEnodnj5PH45pG
cR1iCyox3lpL9GloliBEnHm+UDETCLHFA+h9KmafhmYCIbbiNcYREXqfhmYiIY54IEf/gLjqD5b3
IhFiKzUTZkQcI++frcL9yC5a3kCo9isF/LzFOBKLLI6I0Wx/kGumbMYIzUS+PNXDmi9cTUNS+gk0
JTJ7TNH6Hn9evvmX+Xf4zARDNOtzw8kjguw1AdUiNEt21XzL6MNi5sPwJXJ7TtH7Nry9JmTvABWn
oZlwiGZj7gm9N8iRk081QrPEV821roV0K1AOu+vJ7kGF5zvlj6Q8Dc0CXKyoPwEtRHgM5EM0i/FE
bBVl20OEaBbnCVkj0jaHCdEs1hOzJNq2htqYqagXMdECLEJNxOiiRmgWeCIWUSZj5AjNEkzECE9g
hG1YEn4Dp9SmY4YAizQbOuU9yEwBFuk2eMpbkBkDLNJueHF0jJnjm+JBmBgZJQF+xIOxoGWcxAcA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAPT8BQCvjMTYkHVyAAAAAElFTkSuQmCC
B64_EOF

mkdir -p "android/app/src/main/res/mipmap-hdpi"
base64 -d > "android/app/src/main/res/mipmap-hdpi/ic_launcher_background.png" << 'B64_EOF'
iVBORw0KGgoAAAANSUhEUgAAAKIAAACiCAYAAADC8hYbAAABzElEQVR4nO3SMRHAMBDAsG8J5LKU
P9MGRjxICDz4Wfv7By57bwfAjBGJMCIJRiTBiCQYkQQjkmBEEoxIghFJMCIJRiTBiCQYkQQjkmBE
EoxIghFJMCIJRiTBiCQYkQQjkmBEEoxIghFJMCIJRiTBiCQYkQQjkmBEEoxIghFJMCIJRiTBiCQY
kQQjkmBEEoxIghFJMCIJRiTBiCQYkQQjkmBEEoxIghFJMCIJRiTBiCQYkQQjkmBEEoxIghFJMCIJ
RiTBiCQYkQQjkmBEEoxIghFJMCIJRiTBiCQYkQQjkmBEEoxIghFJMCIJRiTBiCQYkQQjkmBEEoxI
ghFJMCIJRiTBiCQYkQQjkmBEEoxIghFJMCIJRiTBiCQYkQQjkmBEEoxIghFJMCIJRiTBiCQYkQQj
kmBEEoxIghFJMCIJRiTBiCQYkQQjkmBEEoxIghFJMCIJRiTBiCQYkQQjkmBEEoxIghFJMCIJRiTB
iCQYkQQjkmBEEoxIghFJMCIJRiTBiCQYkQQjkmBEEoxIghFJMCIJRiTBiCQYkQQjkmBEEoxIghFJ
MCIJRiTBiCQYkQQjkmBEEoxIghFJMCIJRiTBiCQYkQQjkmBEEoxIwgFgHAJ5v19pzQAAAABJRU5E
rkJggg==
B64_EOF

mkdir -p "android/app/src/main/res/mipmap-xhdpi"
base64 -d > "android/app/src/main/res/mipmap-xhdpi/ic_launcher.png" << 'B64_EOF'
iVBORw0KGgoAAAANSUhEUgAAAGAAAABgCAYAAADimHc4AAADEklEQVR4nO2dMW7cMBBF6cC9kSZd
4Ca1rxIgF8gN9gRb5gS5QS4QIFfZOo3hgyRFQEQQtLskZ+b/T2le6YbceRyORGnkh6f3H/6UhMY7
9gSOTgogkwLIpAAyKYBMCiCTAsikADIpgEwKIJMCyKQAMimAzCN7AqOcT5fNv3/7/gKeiY2HGY+j
rwV/C3Uh0wnoCf4WakKmEmAN/hIVEYctwufTxVXoKIcVUGGLkL4K+vj8CTbW+XShbEtyNeBe0L9+
/hk6PlqCjICe1R4toRScCIka0LvV/Pj1JWgm/0HVBWoGRO3xnhkSnQk0AcgCaxUSKYGyBSGDX8q/
LQuxbY0AzwBL8N9ef7uMMZIRUVkAFTAS/Nagj4zZKyJCAkxAb/CtgW8dny0BIqAn+N6BX7M1F6aE
8CKsFPxrYzALtMSNWCmY4N8aq0eC501aqIDW1Y8MPnPMLcIEKAf/2tiMLKBuQQqrkD2HEAEtq5/9
w5cs54LOApkifFQoApRWf2U0C6y4C0AftM0OPAMUV39lJAusdSBrAJkUQMZVwL39X3n7qaDnmBlw
A0QdSAFkUgCZFEAmBZBxezl3XYhUXwNRwyUDtq4CEO9v7gGzgFuXYCnhPiYBLde/R5BgeUsCWoRn
OCldzhGxePIqiEwKIAMRsExl5W2IMTeTAJVe2wha939rDA7RH9ACa05mAXvMAtTqLwWYAesfpZQF
zLm4CGhdCYoS1nNA3zjCa4CSBIUF4CagZz9UkGBt1PCqfTI3YkgJHl0yXrgKsGRBKRgJai1K7j1i
I28IbD28ySY9A14SSolrU1XpFZYRUMr9x5gejdqje/10jdqWl5Uinierfi8itE/Yq4/KIsTj6iby
uCW8UduzpbNFhPfl5G4+V6PwhcJeEAeN0I91zCIBecILvROe4egaPUf4UYSyhMN9tlJpS2ItDInP
VjJFsDNSQkAFKYId+IqUgEqkCJXAVyQFVPb4ufo10gKusZd/X1LKpAL2hMwjyaOSAsikADIpgEwK
IJMCyKQAMimATAogkwLIpAAyKYBMCiDzF0RVJH69pni3AAAAAElFTkSuQmCC
B64_EOF

mkdir -p "android/app/src/main/res/mipmap-xhdpi"
base64 -d > "android/app/src/main/res/mipmap-xhdpi/ic_launcher_foreground.png" << 'B64_EOF'
iVBORw0KGgoAAAANSUhEUgAAANgAAADYCAYAAACJIC3tAAAFi0lEQVR4nO3du60cNxSAYcpwES5C
gWM1IcANqArHgmNV4QYEuAnFClSEupADa6D11d678+Dj8PD7YsMacudfcngXu6UAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADxvRp9ATz24f3Xb3v+uz//+s3rGYwXJLC9
Ye0hvjFMelA143pKbP2Y6IBaxnVLaO2Z4GB6xXVLaO2Y2EBGxPWU2Or6ZfQFEMuH91+/RQg9C4EF
Ee2mjnY9sxIYz7KaXScwHhLZeQJjF6vZOQIb7PXvb769/v3NNDeuyI5xJDvAvaDevf044lIucaT/
mAnq5NEqNWNgpYjsEZPT2JHt36yRlSK053gGa2S2Z6urPJvd512nsqtRzbyKlWIle8pkVFJztRJZ
HraIFdTeCv79zx81/3fd2S7+ILCLWj1niSwHS/lJPQ8wZt4yrr5dXHrwZ0U9HYwa4sqRLTvws6LG
dU+k4FaNbMlBnzVTXE9FiG3FyH4dfQGzmDmuUn4+NIkQ3AqcIu4we1z3jDilXPFkcbkl+6iMcT3V
ezVbaatoBXvBCnGVMv/f3CIT2DNWiWvTM7KVtorLLNVHRQjsy+dPu16fWT8HucJWMf0AzxgV196g
HpnlE/0CW1DvuGpF9Zyz4xFZHakHd1TPuFqH9dSZsfWILHtgDjk6+/L506vecZ39d50uXiew73qs
XiPCunoNIrtGYJ1EiGsTKbLsR/ZhXvSRWq5ekcK6Z+/YWz+PZX0Ws4I1FD2uUvZfo63iOcsH1mr1
miGuTYTIsm4Vlw8MWlo6MKvXDxFWsYyWDqyFGePajI4s4zZRYBXNHNcmwxgiWTawCJ+WJ79lA6st
0zv/nrF4FttHYISS7TlsycBqbw8zrV6bjGMaYcnAoBeBcZrnsMcEdlHmrVTmsfUiMGhoucD8/asu
28SXLRcY8WU6qhfYBSs8o6wwxpYEBg0JDBoSGDS0zA/wvfTg7CSMVtIHtudEavvGJKFRW+ot4tHj
Xj+rSm1pAzv7txSRUVPKwK7+oVJk1JIusFqfAhAZNaQLrKcVPte4whhbShVY7c+wWcW4KlVg5JDp
hyAExiVW+ZcJ7KLMzyiZx9aLwKAhgXFai+1hpuevUpIFNurFybiVyjimEVIF1oKHeK4Q2A57Isv0
jj9qLNm2h6UIjJOs7PukC6zVu+Aqq9ieMYhrv3SBjTZzZDNfe1QCa2DGG3XvNbdavTI+f5WSNLCR
20S4lTKwlvZGNtMqNtO1zkZgDc1w4x65RtvD49IOrJS233F+9Buoon0F9dH4W26PMwdmBTvp6A0X
aTWLFFd2qQOL9s4YITJx9RXqBmyh9U/hnP2y0t5bxjNx94gr2ptgbakHt4kaWSntQzu7avZauQSW
QI8fdKvxtdu1Yru6FRVXPekHuJklslt7g6v5bCeuupYY5KbXT5PO+iMSPQ80Vgks9SniKDOevImr
jWUGuun9A9vRV7PebwYrxVXKgitY7xc46mr27u3HsNeWSfof4Isg0g/8jYxqtdWrlAW3iJveW8Vb
vUOLsFKtGFcpCwdWytjINq1iixDVLYEtKkJkmyuxRQvq1qpxlSKwUkqsyLJZOa5SFjxFpJ/V4ypF
YKUUN0IL5vQ/AvvODVGPufxBYDfcGNeZw/8T2BNukPPM3c9MyAucLu4nrvusYC9w0+xjnp5nYnaw
kt0nrMesYDu4kX5mTvYxSQdYyYR1lMk6YdXQxHWcCTtppciEdZ6Juyh7aOK6xuRVlCk2YdVhEiub
OTJR1WdCG5ktNHG1YVI7iRqcsNoyuQOMjE1QfZnswXrEJqpxTHwwZ4MTEQAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAwFn/AiQzJPz8fQqFAAAAAElFTkSuQmCC
B64_EOF

mkdir -p "android/app/src/main/res/mipmap-xhdpi"
base64 -d > "android/app/src/main/res/mipmap-xhdpi/ic_launcher_background.png" << 'B64_EOF'
iVBORw0KGgoAAAANSUhEUgAAANgAAADYCAYAAACJIC3tAAACdUlEQVR4nO3TwQnAIADAQHWB4sf9
N22nCEK5myCfzGefdwCJdTsA/sxgEDIYhAwGIYNByGAQMhiEDAYhg0HIYBAyGIQMBiGDQchgEDIY
hAwGIYNByGAQMhiEDAYhg0HIYBAyGIQMBiGDQchgEDIYhAwGIYNByGAQMhiEDAYhg0HIYBAyGIQM
BiGDQchgEDIYhAwGIYNByGAQMhiEDAYhg0HIYBAyGIQMBiGDQchgEDIYhAwGIYNByGAQMhiEDAYh
g0HIYBAyGIQMBiGDQchgEDIYhAwGIYNByGAQMhiEDAYhg0HIYBAyGIQMBiGDQchgEDIYhAwGIYNB
yGAQMhiEDAYhg0HIYBAyGIQMBiGDQchgEDIYhAwGIYNByGAQMhiEDAYhg0HIYBAyGIQMBiGDQchg
EDIYhAwGIYNByGAQMhiEDAYhg0HIYBAyGIQMBiGDQchgEDIYhAwGIYNByGAQMhiEDAYhg0HIYBAy
GIQMBiGDQchgEDIYhAwGIYNByGAQMhiEDAYhg0HIYBAyGIQMBiGDQchgEDIYhAwGIYNByGAQMhiE
DAYhg0HIYBAyGIQMBiGDQchgEDIYhAwGIYNByGAQMhiEDAYhg0HIYBAyGIQMBiGDQchgEDIYhAwG
IYNByGAQMhiEDAYhg0HIYBAyGIQMBiGDQchgEDIYhAwGIYNByGAQMhiEDAYhg0HIYBAyGIQMBiGD
QchgEDIYhAwGIYNByGAQMhiEDAYhg0HIYBAyGIQMBiGDQchgEDIYhAwGIYNByGAQMhiEDAYhg0HI
YBAyGIQMBiGDQchgEDIYhAwGIYNByGAQMhiEDAYhg0HIYBAyGIQ+7TYC5R2OtjQAAAAASUVORK5C
YII=
B64_EOF

mkdir -p "android/app/src/main/res/mipmap-xxhdpi"
base64 -d > "android/app/src/main/res/mipmap-xxhdpi/ic_launcher.png" << 'B64_EOF'
iVBORw0KGgoAAAANSUhEUgAAAJAAAACQCAYAAADnRuK4AAAE2klEQVR4nO3dva3cRhSG4SPBuaFE
meHEsVsxoAbUgSpQ6ArcgRsw4FYUKxFUiB1II1DU/pA88/N9M+8bXwic1bNzuLx7yRc/v3r9XxBd
7OXoAyDvAESpAESpAESpAESpAESpAESpAESpAESpAESpAESpAESpAESpAESpAESpAESpAESpAESp
AESpAESpAESpfhp9AKq9f/fh8M/++dfvDY9Euxf8Wc/3nYFzq9UwAWhTFs++FTAB6Gu18eybFRPn
QJ3aAp0JEztQtN997jUDJD7GD2wU3JotOcJ++fW30YfwLffRtgQgJTCPev/ugx2iqc+BzsB5+8c/
DY/kXE6IptyBXHace5Wx5gBpqh0oC0dpFyqpI5oCUM0dB0TnsgfUalypQVJFZAtI5TynJzRFRJaA
VPDs64FJDZEdIFU8+1piUkJkBcgFz74WmFQQWQDqAefzp4+nfv7sMc2KSB5QKzxnwTzr6HHWhjQa
0ZRXoh9VG87+330G6e9/30SE3mWCq0nvQLV2n1ZonvXs+GshGrkLyQJyx1M6so4akEYhkvxCWQ08
nz99HI7n6HGUseaYHKBaeNRqfUyjvt0oN8IygBTh3OreGh1HmdQOtAKeiPvH6jjKZACtgqfUClHv
USYD6GqOeEoz7EQSgK7uPs54Su5rkABEP5bZhXqOseGAVt59Ss6jbDigK82Ep+S6pqGAXL/f41Cv
MWa3A7m+U490a23qY2wYoCu7z8x4Sm5rtNuB6Hg9xhiADFIeYzaA3Lb2TE5rHQKIT1/9aj3GLHYg
p3dkrfZrVh1jFoBINwAtUMsx1h0Q5z/XUxxj8jvQiuc/JYe1ywMi7QBEqQBEqQBEqQBEqQBEqbrf
3mX/15eK1zboeN0A3bsaWkABybMuI+zIpfRZbri0Ws0Bnfk9DIj84iSaUjUFdOW3wPtdaOVfvjqs
nR2IUgHIKMVzRAAtUMu7llkAcjgXqJ3Lmi0Akeb4ihAFdOvFcnlH1qjmWlvfdLMpoNHPcaD2Se5A
9H2q4ytCGNCqY8xpfEV0AJRZxGqIHNcmuwPRl5THV4QBoFV2oVtryuDp9QGmC6DsYmZH5LwW+R1o
1dRHV6kbIHah29UeXRF9r7913YFaLMwZkfOxl6xG2L13puN/RKtnhk3/vLAWoyzCC9EseCIG7UAt
ESlDenR8LifN+6xG2LZHL7giokfH5Pioy5ItoIjniBQgPTsOZzwRAwHVWvSz/4CRiJ7BcR1b24Y+
tbn2zR+P/Hl069vGHQFbE87o71wNf+z3CEQR9SEd3elmwhMhACiizW1oz96s4SyoK6Ox9sgC0KZW
9zIefdePVuc5CngihABFzIWo5QmyCp4IMUAR7R8O0gPTKngiBAFF9HveZxZT74/hangiRAFF9H32
uUOKeCKEr0SrvmAjUn4tZHeg0so7kTKckjyg0mqQHPBECI+wfS4vaI2c1moDKMLrhb2a2xptRti2
GceZG5ySJaDSLJBc8USYA9rmiMkZTmkaQBEeiGZAs20qQCVVSLPhiZgU0DYFTDPCKU0PaFtPTDOj
2bYUoG01MK2C5FHLAqI6WV2JJr0ARKkARKkARKkARKkARKkARKkARKkARKkARKkARKkARKkARKkA
RKkARKkARKkARKkARKkARKkARKkARKn+B6k0pkTjIhcgAAAAAElFTkSuQmCC
B64_EOF

mkdir -p "android/app/src/main/res/mipmap-xxhdpi"
base64 -d > "android/app/src/main/res/mipmap-xxhdpi/ic_launcher_foreground.png" << 'B64_EOF'
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
B64_EOF

mkdir -p "android/app/src/main/res/mipmap-xxhdpi"
base64 -d > "android/app/src/main/res/mipmap-xxhdpi/ic_launcher_background.png" << 'B64_EOF'
iVBORw0KGgoAAAANSUhEUgAAAUQAAAFECAYAAABf6kfGAAADx0lEQVR4nO3UMRHAIADAQIoBrkv9
O4UlHujwryBTnvV+ewAw5u0AgL8wRIAYIkAMESCGCBBDBIghAsQQAWKIADFEgBgiQAwRIIYIEEME
iCECxBABYogAMUSAGCJADBEghggQQwSIIQLEEAFiiAAxRIAYIkAMESCGCBBDBIghAsQQAWKIADFE
gBgiQAwRIIYIEEMEiCECxBABYogAMUSAGCJADBEghggQQwSIIQLEEAFiiAAxRIAYIkAMESCGCBBD
BIghAsQQAWKIADFEgBgiQAwRIIYIEEMEiCECxBABYogAMUSAGCJADBEghggQQwSIIQLEEAFiiAAx
RIAYIkAMESCGCBBDBIghAsQQAWKIADFEgBgiQAwRIIYIEEMEiCECxBABYogAMUSAGCJADBEghggQ
QwSIIQLEEAFiiAAxRIAYIkAMESCGCBBDBIghAsQQAWKIADFEgBgiQAwRIIYIEEMEiCECxBABYogA
MUSAGCJADBEghggQQwSIIQLEEAFiiAAxRIAYIkAMESCGCBBDBIghAsQQAWKIADFEgBgiQAwRIIYI
EEMEiCECxBABYogAMUSAGCJADBEghggQQwSIIQLEEAFiiAAxRIAYIkAMESCGCBBDBIghAsQQAWKI
ADFEgBgiQAwRIIYIEEMEiCECxBABYogAMUSAGCJADBEghggQQwSIIQLEEAFiiAAxRIAYIkAMESCG
CBBDBIghAsQQAWKIADFEgBgiQAwRIIYIEEMEiCECxBABYogAMUSAGCJADBEghggQQwSIIQLEEAFi
iAAxRIAYIkAMESCGCBBDBIghAsQQAWKIADFEgBgiQAwRIIYIEEMEiCECxBABYogAMUSAGCJADBEg
hggQQwSIIQLEEAFiiAAxRIAYIkAMESCGCBBDBIghAsQQAWKIADFEgBgiQAwRIIYIEEMEiCECxBAB
YogAMUSAGCJADBEghggQQwSIIQLEEAFiiAAxRIAYIkAMESCGCBBDBIghAsQQAWKIADFEgBgiQAwR
IIYIEEMEiCECxBABYogAMUSAGCJADBEghggQQwSIIQLEEAFiiAAxRIAYIkAMESCGCBBDBIghAsQQ
AWKIADFEgBgiQAwRIIYIEEMEiCECxBABYogAMUSAGCJADBEghggQQwSIIQLEEAFiiAAxRIAYIkAM
ESCGCBBDBIghAsQQAWKIADFEgBgiQAwRIIYIEEMEiCECxBABYogAMUSAGCJADBEghggQQwSIIQLE
EAFiiAAxRIAYIkAMESCGCBBDBIghAsQQAWKIADFEgBgiQA46twO9kRDmkQAAAABJRU5ErkJggg==
B64_EOF

mkdir -p "android/app/src/main/res/mipmap-xxxhdpi"
base64 -d > "android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png" << 'B64_EOF'
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
B64_EOF

mkdir -p "android/app/src/main/res/mipmap-xxxhdpi"
base64 -d > "android/app/src/main/res/mipmap-xxxhdpi/ic_launcher_foreground.png" << 'B64_EOF'
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
B64_EOF

mkdir -p "android/app/src/main/res/mipmap-xxxhdpi"
base64 -d > "android/app/src/main/res/mipmap-xxxhdpi/ic_launcher_background.png" << 'B64_EOF'
iVBORw0KGgoAAAANSUhEUgAAAbAAAAGwCAYAAADITjAqAAAGd0lEQVR4nO3VsQ3AIADAsNIHEAv/
f0p/6IIi2Rdky5hrnwcAYt7bAQDwh4EBkGRgACQZGABJBgZAkoEBkGRgACQZGABJBgZAkoEBkGRg
ACQZGABJBgZAkoEBkGRgACQZGABJBgZAkoEBkGRgACQZGABJBgZAkoEBkGRgACQZGABJBgZAkoEB
kGRgACQZGABJBgZAkoEBkGRgACQZGABJBgZAkoEBkGRgACQZGABJBgZAkoEBkGRgACQZGABJBgZA
koEBkGRgACQZGABJBgZAkoEBkGRgACQZGABJBgZAkoEBkGRgACQZGABJBgZAkoEBkGRgACQZGABJ
BgZAkoEBkGRgACQZGABJBgZAkoEBkGRgACQZGABJBgZAkoEBkGRgACQZGABJBgZAkoEBkGRgACQZ
GABJBgZAkoEBkGRgACQZGABJBgZAkoEBkGRgACQZGABJBgZAkoEBkGRgACQZGABJBgZAkoEBkGRg
ACQZGABJBgZAkoEBkGRgACQZGABJBgZAkoEBkGRgACQZGABJBgZAkoEBkGRgACQZGABJBgZAkoEB
kGRgACQZGABJBgZAkoEBkGRgACQZGABJBgZAkoEBkGRgACQZGABJBgZAkoEBkGRgACQZGABJBgZA
koEBkGRgACQZGABJBgZAkoEBkGRgACQZGABJBgZAkoEBkGRgACQZGABJBgZAkoEBkGRgACQZGABJ
BgZAkoEBkGRgACQZGABJBgZAkoEBkGRgACQZGABJBgZAkoEBkGRgACQZGABJBgZAkoEBkGRgACQZ
GABJBgZAkoEBkGRgACQZGABJBgZAkoEBkGRgACQZGABJBgZAkoEBkGRgACQZGABJBgZAkoEBkGRg
ACQZGABJBgZAkoEBkGRgACQZGABJBgZAkoEBkGRgACQZGABJBgZAkoEBkGRgACQZGABJBgZAkoEB
kGRgACQZGABJBgZAkoEBkGRgACQZGABJBgZAkoEBkGRgACQZGABJBgZAkoEBkGRgACQZGABJBgZA
koEBkGRgACQZGABJBgZAkoEBkGRgACQZGABJBgZAkoEBkGRgACQZGABJBgZAkoEBkGRgACQZGABJ
BgZAkoEBkGRgACQZGABJBgZAkoEBkGRgACQZGABJBgZAkoEBkGRgACQZGABJBgZAkoEBkGRgACQZ
GABJBgZAkoEBkGRgACQZGABJBgZAkoEBkGRgACQZGABJBgZAkoEBkGRgACQZGABJBgZAkoEBkGRg
ACQZGABJBgZAkoEBkGRgACQZGABJBgZAkoEBkGRgACQZGABJBgZAkoEBkGRgACQZGABJBgZAkoEB
kGRgACQZGABJBgZAkoEBkGRgACQZGABJBgZAkoEBkGRgACQZGABJBgZAkoEBkGRgACQZGABJBgZA
koEBkGRgACQZGABJBgZAkoEBkGRgACQZGABJBgZAkoEBkGRgACQZGABJBgZAkoEBkGRgACQZGABJ
BgZAkoEBkGRgACQZGABJBgZAkoEBkGRgACQZGABJBgZAkoEBkGRgACQZGABJBgZAkoEBkGRgACQZ
GABJBgZAkoEBkGRgACQZGABJBgZAkoEBkGRgACQZGABJBgZAkoEBkGRgACQZGABJBgZAkoEBkGRg
ACQZGABJBgZAkoEBkGRgACQZGABJBgZAkoEBkGRgACQZGABJBgZAkoEBkGRgACQZGABJBgZAkoEB
kGRgACQZGABJBgZAkoEBkGRgACQZGABJBgZAkoEBkGRgACQZGABJBgZAkoEBkGRgACQZGABJBgZA
koEBkGRgACQZGABJBgZAkoEBkGRgACQZGABJBgZAkoEBkGRgACQZGABJBgZAkoEBkGRgACQZGABJ
BgZAkoEBkGRgACQZGABJBgZAkoEBkGRgACQZGABJBgZAkoEBkGRgACQZGABJBgZAkoEBkGRgACQZ
GABJBgZAkoEBkGRgACQZGABJBgZAkoEBkGRgACQZGABJBgZAkoEBkGRgACQZGABJBgZAkoEBkGRg
ACQZGABJBgZAkoEBkGRgACQZGABJBgZAkoEBkGRgACQZGABJBgZAkoEBkGRgACQZGABJBgZAkoEB
kGRgACQZGABJBgZAkoEBkGRgACQZGABJBgZAkoEBkGRgACQZGABJBgZAkoEBkGRgACQZGABJBgZA
koEBkGRgACQZGABJBgZAkoEBkGRgACQZGABJBgZAkoEBkGRgACR9p0cElWyS03EAAAAASUVORK5C
YII=
B64_EOF

rm -f "lib/shared/widgets/mini_charts.dart"

find lib -maxdepth 1 -name "*{*" -exec rm -rf {} + 2>/dev/null || true

git add -A
git -c user.email="dev@ulimit.app" -c user.name="Ulimit Dev" commit -m "Fix settings route crash, duplicate provider, usage-tracker timestamp unit mismatch, unregistered font family, missing gradle/icons, and dead mini_charts.dart"
git push

echo "Pushed. Removing this script."
rm -- "$0"
