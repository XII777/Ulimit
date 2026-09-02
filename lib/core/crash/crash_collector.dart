import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Local crash collector. Captures Flutter framework errors, uncaught
/// async errors and main-isolate errors into timestamped files under
/// `<documents>/crash_logs/`. The Android side appends native (Kotlin)
/// crashes into the same directory (see UlimitApplication.kt), so the
/// Settings screen reviews everything from one folder.
///
/// Privacy contract: crash files never leave the device unless the user
/// explicitly saves/copies them from Settings → Data → Crash logs.
class CrashCollector {
  CrashCollector._();

  static const _dirName = 'crash_logs';
  static const _maxFiles = 10;

  static Directory? _dir;

  static Future<Directory> _ensureDir() async {
    final cached = _dir;
    if (cached != null) return cached;
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/$_dirName');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    _dir = dir;
    return dir;
  }

  /// Installs the error hooks. Safe to call before runApp(); every hook
  /// is individually guarded so a collector failure can never worsen an
  /// actual crash.
  static Future<void> initialize() async {
    try {
      await _ensureDir();
    } catch (_) {
      return; // No storage — nothing we can collect into.
    }

    // 1. Flutter framework errors (red-screen causes).
    final previousFlutterError = FlutterError.onError;
    FlutterError.onError = (details) {
      _write('flutter', _formatFlutterError(details));
      previousFlutterError?.call(details);
    };

    // 2. Uncaught async/platform errors outside the framework.
    final dispatcher = PlatformDispatcher.instance;
    final previousPlatformError = dispatcher.onError;
    dispatcher.onError = (error, stack) {
      _write('async', 'Unhandled platform error: $error\n\n$stack');
      return previousPlatformError?.call(error, stack) ?? true;
    };

    // 3. Errors thrown in the main isolate outside zones above.
    Isolate.current.addErrorListener(
      RawReceivePort((pair) {
        final message = pair as List<dynamic>;
        _write('isolate', 'Uncaught isolate error: ${message.first}\n\n${message.last}');
      }).sendPort,
    );
  }

  static String _formatFlutterError(FlutterErrorDetails details) {
    return 'Flutter error: ${details.exceptionAsString()}\n\n'
        '${details.stack ?? ''}\n'
        'library: ${details.library ?? 'n/a'}\n'
        'context: ${details.context ?? 'n/a'}\n';
  }

  static Future<File> _write(String kind, String content) async {
    try {
      final dir = await _ensureDir();
      final stamp = DateTime.now().toIso8601String().replaceAll(':', '-');
      final file = File('${dir.path}/$kind-$stamp.log');
      final body = '${DateTime.now().toIso8601String()}\n'
          'app: ulimit 0.2.0\n'
          'mode: ${kReleaseMode ? 'release' : 'debug'}\n\n'
          '$content\n';
      await file.writeAsString(body, flush: true);
      await _prune(dir);
      return file;
    } catch (_) {
      return File('');
    }
  }

  static Future<void> _prune(Directory dir) async {
    final files = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.log'))
        .toList()
      ..sort((a, b) => b.path.compareTo(a.path)); // newest first (stamp in name)
    for (var i = _maxFiles; i < files.length; i++) {
      try {
        files[i].deleteSync();
      } catch (_) {}
    }
  }

  /// All crash logs — Dart-written files live directly in the folder;
  /// native crashes are written by UlimitApplication into the same
  /// directory, so a plain listing covers both.
  static Future<List<File>> list() async {
    try {
      final dir = await _ensureDir();
      final files = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.log'))
          .toList()
        ..sort((a, b) => b.path.compareTo(a.path));
      return files;
    } catch (_) {
      return const [];
    }
  }

  static Future<void> clear() async {
    try {
      final dir = await _ensureDir();
      for (final f in dir.listSync().whereType<File>()) {
        try {
          f.deleteSync();
        } catch (_) {}
      }
    } catch (_) {}
  }
}
