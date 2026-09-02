import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/icons/app_icons.dart';
import '../../core/theme/tokens.dart';

/// The app's one modal bottom-sheet system. Every popup in the app MUST
/// open through [showAppSheet] so the global behavior guarantees hold:
///
///  1. **Background locked** — the modal barrier sits on the root
///     navigator above the shell; swipes/drags/taps never reach the
///     page underneath, which stays exactly where it was.
///  2. **Above everything** — sheets ride on the root navigator, above
///     the nav shell, tabs and floating pill. The pill additionally
///     hides itself while any overlay is open (see `AppUiObserver`).
///  3. **Content-based height** — the popup sizes to its internal
///     content (a single-button popup is minimal; a list grows to fit
///     its items), capped at [initialSize] of the screen height. Tall
///     content scrolls inside the sheet instead of being cut off.
///  4. **Pull-down-to-dismiss** — the modal's own drag gesture handles
///     it; content scrolls independently via the sheet [ScrollController].
///  5. **Safe area + keyboard** — the chrome pads for the bottom system
///     inset and the sheet lifts above the keyboard when a field has
///     focus.
///  6. **iOS background zoom** — while a sheet is open the page behind
///     it zooms out (scales down with rounded corners, see [SheetZoom]),
///     in sync with the sheet's own entrance/exit animation.
///
/// Contract: `builder` must attach the provided `scrollController` to
/// the content's primary scrollable (ListView/SingleChildScrollView),
/// and scrollables should use `shrinkWrap: true` so the popup height
/// tracks the content instead of expanding to the cap.
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
    // The modal-owned drag dismisses the sheet; content scrolls with
    // its own controller, so there's no gesture hand-off to coordinate.
    enableDrag: true,
    backgroundColor: Colors.transparent,
    elevation: 0,
    isDismissible: isDismissible,
    barrierColor: Colors.black.withOpacity(0.55),
    builder: (sheetContext) {
      // Cap the popup at [initialSize] of the screen. The sheet is
      // otherwise sized by its content, so a popup with one button
      // hugs it and a popup with a list grows to fit its items.
      final maxHeight = MediaQuery.sizeOf(sheetContext).height * initialSize;
      return Padding(
        // Lift the whole sheet above the keyboard while a field is
        // focused; the sheet never hides behind it.
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(sheetContext).bottom),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight),
          child: _SheetChrome(
            title: title,
            subtitle: subtitle,
            trailing: trailing,
            showHandle: showHandle,
            showClose: showClose,
            builder: builder,
          ),
        ),
      );
    },
  ).whenComplete(() {
    // whenComplete fires the moment the sheet starts dismissing
    // (pop, barrier tap or drag) — so the background zooms back in
    // in sync with the slide-down, not after it.
    _openSheetCount = math.max(0, _openSheetCount - 1);
    _syncSheetZoom();
  });
}

/// Open-sheet depth. Depth-counted (not boolean) so a sheet opened
/// from inside another sheet keeps the background zoomed out until
/// the last one closes.
int _openSheetCount = 0;

/// Whether any app sheet is open right now. Drives the iOS-style
/// background zoom in [SheetZoom].
final ValueNotifier<bool> appSheetOpen = ValueNotifier<bool>(false);

void _syncSheetZoom() {
  appSheetOpen.value = _openSheetCount > 0;
}

/// iOS-style modal presentation backdrop: while any sheet opened via
/// [showAppSheet] is on screen, the wrapped page content zooms out —
/// scales down slightly and rounds its corners like the background
/// card receding behind an iOS presented sheet.
///
/// Wrap the root page content with it (NavShell body and the detail
/// routes do). The animation is depth-safe: it stays zoomed while any
/// number of sheets is stacked and restores on the last close, with
/// the same ease as the sheet's own slide so the two read as one
/// gesture.
class SheetZoom extends StatelessWidget {
  const SheetZoom({super.key, required this.child});
  final Widget child;

  static const _duration = Duration(milliseconds: 400);
  static const _curve = Curves.easeOutCubic;
  static const _zoomedScale = 0.94;
  static const _zoomedRadius = 32.0;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: appSheetOpen,
      builder: (context, child) {
        final zoomed = appSheetOpen.value;
        return AnimatedScale(
          scale: zoomed ? _zoomedScale : 1.0,
          duration: _duration,
          curve: _curve,
          child: AnimatedContainer(
            duration: _duration,
            curve: _curve,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(zoomed ? _zoomedRadius : 0),
            ),
            child: child,
          ),
        );
      },
      child: child,
    );
  }
}

/// App-wide confirmation popup — the bottom-sheet replacement for the
/// classic centered confirm dialog. A minimal sheet with the title in
/// the chrome, the message, one filled confirm action and a plain
/// cancel. Used for destructive/irreversible decisions app-wide.
Future<bool?> showAppConfirmSheet(
  BuildContext context, {
  required String title,
  String? message,
  String confirmLabel = 'Confirm',
  String cancelLabel = 'Cancel',
  bool isDismissible = true,
}) {
  return showAppSheet<bool>(
    context: context,
    title: title,
    isDismissible: isDismissible,
    builder: (sheetContext, _) => Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (message != null) ...[
            Text(
              message,
              style: TextStyle(fontSize: 12.5, color: AppColors.inkDim, height: 1.5),
            ),
            const SizedBox(height: 20),
          ],
          TextButton(
            onPressed: () => Navigator.of(sheetContext).pop(true),
            style: TextButton.styleFrom(
              backgroundColor: AppColors.ink,
              foregroundColor: AppColors.bg,
              padding: const EdgeInsets.all(14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.md)),
            ),
            child: Text(confirmLabel, style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: () => Navigator.of(sheetContext).pop(false),
            child: Text(cancelLabel, style: TextStyle(color: AppColors.inkDim)),
          ),
        ],
      ),
    ),
  );
}

/// Owns the sheet's [ScrollController] (created once, disposed with the
/// route's tree) and lays out the chrome + content. The content sits in
/// a [Flexible] child so its height drives the container's height up to
/// the max-height cap.
class _SheetChrome extends StatefulWidget {
  const _SheetChrome({
    required this.builder,
    this.title,
    this.subtitle,
    this.trailing,
    this.showHandle = true,
    this.showClose = true,
  });

  final Widget Function(BuildContext, ScrollController) builder;
  final String? title;
  final String? subtitle;
  final Widget? trailing;
  final bool showHandle;
  final bool showClose;

  @override
  State<_SheetChrome> createState() => _SheetChromeState();
}

class _SheetChromeState extends State<_SheetChrome> {
  final ScrollController _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: AppColors.bg,
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xl)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.showHandle)
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
          if (widget.title != null)
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
                          widget.title!,
                          style: TextStyle(
                              fontSize: 17, fontWeight: FontWeight.w600, color: AppColors.ink),
                        ),
                        if (widget.subtitle != null) ...[
                          const SizedBox(height: 2),
                          Text(
                            widget.subtitle!,
                            style: TextStyle(fontSize: 11.5, color: AppColors.inkDim),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (widget.trailing != null) widget.trailing!,
                  if (widget.showClose)
                    IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: AppIcon(AppIconName.close, size: 18, color: AppColors.inkDim),
                    ),
                ],
              ),
            ),
          // Flexible + loose fit: content-sized up to the cap, then
          // scrollable within the sheet when it would overflow.
          Flexible(
            child: widget.builder(context, _controller),
          ),
          SizedBox(height: MediaQuery.paddingOf(context).bottom),
        ],
      ),
    );
  }
}

/// App-wide snackbar: floats above the navigation pill (FR-1.3), styled
/// monochrome. Use this instead of ScaffoldMessenger.showSnackBar with
/// hand-rolled SnackBars.
void showAppSnack(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(message, style: TextStyle(color: AppColors.ink, fontSize: 12.5)),
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