import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme/tokens.dart';
import 'spring_scroll.dart';

/// The app's one modal bottom-sheet system. Every popup in the app MUST
/// open through [showAppSheet] (or [showDialog], for short centered
/// confirmations) so the global behavior guarantees hold:
///
///  1. **Background locked** — the modal barrier sits on the root
///     navigator above the shell; swipes/drags/taps never reach the
///     page underneath, which stays exactly where it was.
///  2. **Above everything** — sheets ride on the root navigator, above
///     the nav shell, tabs and floating pill. The pill additionally
///     hides itself while any overlay is open (see `AppUiObserver`).
///  3. **Independent content scrolling** — content receives the sheet's
///     own [ScrollController]; scrolling affects only the sheet.
///  4. **Pull-down-to-dismiss** — the sheet is driven by a
///     `DraggableScrollableSheet`: dragging the header/chrome always
///     moves the sheet; dragging inside the scrollable scrolls it, and
///     a downward drag at the top of the list hands off to the sheet.
///     Dragging to the minimum extent closes it smoothly.
///  5. **Safe area + keyboard** — the chrome pads for the bottom system
///     inset and the sheet lifts above the keyboard when a field has
///     focus.
///
/// Contract: `builder` must attach the provided `scrollController` to
/// the content's primary scrollable (ListView/SingleChildScrollView) —
/// that wiring is what makes the gesture handoff work.

Future<T?> showAppSheet<T>({
  required BuildContext context,
  required Widget Function(BuildContext context, ScrollController scrollController) builder,
  String? title,
  String? subtitle,
  Widget? trailing,
  bool showHandle = true,
  bool showClose = true,
  double initialSize = 0.92,
  double minSize = 0.35,
  bool isDismissible = true,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    // The DraggableScrollableSheet owns drag-to-dismiss; the route-level
    // drag would fight it (double sheet movement).
    enableDrag: false,
    backgroundColor: Colors.transparent,
    elevation: 0,
    isDismissible: isDismissible,
    barrierColor: Colors.black.withOpacity(0.55),
    builder: (sheetContext) {
      var dismissed = false;
      return Padding(
        // Lift the whole sheet above the keyboard while a field is
        // focused; the sheet never hides behind it.
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(sheetContext).bottom),
        child: DraggableScrollableSheet(
          expand: false,
          initialChildSize: initialSize,
          maxChildSize: initialSize,
          minChildSize: minSize,
          builder: (context, scrollController) {
            return NotificationListener<DraggableScrollableNotification>(
              onNotification: (n) {
                // Dragged down to (or past) the minimum extent → dismiss
                // smoothly, exactly once.
                if (!dismissed && n.extent <= n.minExtent + 0.001) {
                  dismissed = true;
                  Navigator.of(context).pop();
                }
                return false;
              },
              child: Container(
                decoration: const BoxDecoration(
                  color: AppColors.bg,
                  borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xl)),
                ),
                child: Column(
                  children: [
                    if (showHandle)
                      Center(
                        child: Container(
                          margin: const EdgeInsets.only(top: 10, bottom: 4),
                          width: 40,
                          height: 4,
                          decoration: BoxDecoration(
                            color: AppColors.inkFaint,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                    if (title != null)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 6, 8, 8),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    title,
                                    style: const TextStyle(
                                        fontSize: 17, fontWeight: FontWeight.w600, color: AppColors.ink),
                                  ),
                                  if (subtitle != null) ...[
                                    const SizedBox(height: 2),
                                    Text(
                                      subtitle,
                                      style: const TextStyle(fontSize: 11.5, color: AppColors.inkDim),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            if (trailing != null) trailing,
                            if (showClose)
                              IconButton(
                                onPressed: () => Navigator.of(context).pop(),
                                icon: const Icon(Icons.close_rounded, size: 20, color: AppColors.inkDim),
                              ),
                          ],
                        ),
                      ),
                    Expanded(child: builder(context, scrollController)),
                    SizedBox(height: MediaQuery.paddingOf(sheetContext).bottom),
                  ],
                ),
              ),
            );
          },
        ),
      );
    },
  );
}

/// App-wide snackbar: floats above the navigation pill (FR-1.3), styled
/// monochrome. Use this instead of ScaffoldMessenger.showSnackBar with
/// hand-rolled SnackBars.
void showAppSnack(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(message, style: const TextStyle(color: AppColors.ink, fontSize: 12.5)),
      backgroundColor: AppColors.surface2,
      behavior: SnackBarBehavior.floating,
      // Clear the floating pill + gesture inset so the snackbar never
      // collides with the nav bar.
      margin: EdgeInsets.fromLTRB(16, 0, 16, 96 + MediaQuery.paddingOf(context).bottom),
      duration: const Duration(seconds: 3),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.md)),
    ),
  );
}

/// Marks any route pushed above the shell so the nav pill can hide
/// itself while an overlay (sheet, dialog, detail screen) is open.
/// Depth is tracked manually: NavigatorState exposes no route list.
class AppUiObserver extends NavigatorObserver {
  static final ValueNotifier<bool> overlayOpen = ValueNotifier<bool>(false);

  int _depth = 0;

  void _sync() {
    overlayOpen.value = _depth > 1;
  }

  @override
  void didPush(Route route, Route? previousRoute) {
    _depth++;
    _sync();
  }

  @override
  void didPop(Route route, Route? previousRoute) {
    _depth = math.max(0, _depth - 1);
    _sync();
  }

  @override
  void didRemove(Route route, Route? previousRoute) {
    _depth = math.max(0, _depth - 1);
    _sync();
  }
}
