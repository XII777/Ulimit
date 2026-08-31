import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/tokens.dart';
import '../../data/focus_tags_provider.dart';
import '../../shared/widgets/app_sheet.dart';

/// The palette shown in the tag color picker — one row per page of the
/// design system's hue map. Kept deliberately small: a session tag is a
/// label, not a brand color.
const List<Color> kTagPalette = [
  Color(0xFFE5484D), // red
  Color(0xFFF76B15), // orange
  Color(0xFFFFB224), // amber
  Color(0xFF46A758), // green
  Color(0xFF12A594), // teal
  Color(0xFF0091FF), // blue
  Color(0xFF6E56CF), // violet
  Color(0xFFE93D82), // pink
];

/// Edit/create sheet for a focus tag: name, color, and (for existing
/// tags) delete. Used from both the Focus screen's hold-to-edit on a
/// chip and Settings → Session Tags.
Future<void> showTagEditor(
  BuildContext context, {
  int? tagId,
  String? initialName,
  Color? initialColor,
  required Future<void> Function(String name, Color color) onSave,
  Future<void> Function()? onDelete,
}) async {
  await showAppSheet<void>(
    context: context,
    title: tagId == null ? 'New Session Tag' : 'Edit Session Tag',
    subtitle: tagId == null
        ? 'Create a tag for your focus sessions'
        : 'Rename, recolor, or delete this tag',
    initialSize: 0.6,
    builder: (sheetContext, scrollController) => _TagEditorBody(
      tagId: tagId,
      initialName: initialName,
      initialColor: initialColor,
      onSave: onSave,
      onDelete: onDelete,
    ),
  );
}

class _TagEditorBody extends StatefulWidget {
  const _TagEditorBody({
    required this.onSave,
    this.tagId,
    this.initialName,
    this.initialColor,
    this.onDelete,
  });

  final int? tagId;
  final String? initialName;
  final Color? initialColor;
  final Future<void> Function(String name, Color color) onSave;
  final Future<void> Function()? onDelete;

  @override
  State<_TagEditorBody> createState() => _TagEditorBodyState();
}

class _TagEditorBodyState extends State<_TagEditorBody> {
  late final TextEditingController _nameController =
      TextEditingController(text: widget.initialName ?? '');
  late Color _color = widget.initialColor ?? kTagPalette.first;
  bool _busy = false;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _nameController,
            autofocus: widget.tagId == null,
            maxLength: 24,
            style: TextStyle(color: AppColors.ink, fontSize: 14),
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: 'Tag name',
              labelStyle: TextStyle(color: AppColors.inkFaint, fontSize: 12),
              hintText: 'e.g. Deep Work, Study, Reading',
              hintStyle: TextStyle(color: AppColors.inkFaint, fontSize: 13.5),
              filled: true,
              fillColor: AppColors.surface,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppRadius.md),
                borderSide: BorderSide.none,
              ),
              contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'COLOR',
            style: TextStyle(
              fontSize: AppText.overline,
              color: AppColors.inkFaint,
              letterSpacing: 0.6,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final color in kTagPalette)
                GestureDetector(
                  onTap: () => setState(() => _color = color),
                  child: Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: _color == color ? AppColors.ink : Colors.transparent,
                        width: 2.5,
                      ),
                    ),
                    child: _color == color
                        ? const Icon(Icons.check, size: 16, color: Colors.white)
                        : null,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 24),
          Row(
            children: [
              if (widget.onDelete != null) ...[
                Expanded(
                  child: OutlinedButton(
                    onPressed: _busy ? null : _delete,
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(color: AppColors.stroke),
                      padding: const EdgeInsets.all(13),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(AppRadius.md)),
                    ),
                    child: Text('Delete', style: TextStyle(color: AppColors.danger)),
                  ),
                ),
                const SizedBox(width: 10),
              ],
              Expanded(
                flex: widget.onDelete != null ? 1 : 2,
                child: ElevatedButton(
                  onPressed: (_busy || _nameController.text.trim().isEmpty) ? null : _save,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.ink,
                    foregroundColor: AppColors.bg,
                    padding: const EdgeInsets.all(13),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppRadius.md)),
                  ),
                  child: const Text('Save', style: TextStyle(fontWeight: FontWeight.w600)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      await widget.onSave(_nameController.text.trim(), _color);
      if (mounted) Navigator.of(context).pop();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    setState(() => _busy = true);
    try {
      await widget.onDelete!();
      if (mounted) Navigator.of(context).pop();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

/// Hold-to-edit chip used in the Focus screen SESSION row. A short press
/// selects the tag; a 3-second long press opens the editor (the
/// requested "edit by holding" interaction), with a tiny progress
/// indicator while the hold is in flight.
class HoldToEditChip extends StatefulWidget {
  const HoldToEditChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTapped,
    this.color,
    this.onHold,
    this.holdDuration = const Duration(seconds: 3),
  });

  final String label;
  final bool selected;
  final VoidCallback onTapped;

  /// When set AND non-null, the chip renders with this color and a
  /// long-press opens the editor.
  final Color? color;
  final VoidCallback? onHold;
  final Duration holdDuration;

  @override
  State<HoldToEditChip> createState() => _HoldToEditChipState();
}

class _HoldToEditChipState extends State<HoldToEditChip> {
  static const double _dotSize = 3.5;

  bool _pressed = false;
  bool _anchored = false;
  double _progress = 0;
  Timer? _holdTimer;

  void _startHold() {
    if (widget.onHold == null) return;
    setState(() {
      _pressed = true;
      _anchored = false;
      _progress = 0;
    });
    // Progress advances by the timer's step over the hold duration.
    // The anchor flips after 350ms so a quick tap can never open the
    // editor; only a genuine continuous hold does.
    final tick = const Duration(milliseconds: 50);
    final stepPerTick = tick.inMilliseconds / widget.holdDuration.inMilliseconds;
    Future.delayed(const Duration(milliseconds: 350), () {
      if (mounted && _pressed && _holdTimer != null) {
        setState(() => _anchored = true);
      }
    });
    _holdTimer = Timer.periodic(tick, (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() => _progress = (_progress + stepPerTick).clamp(0.0, 1.0));
      if (_progress >= 1) {
        timer.cancel();
        _holdTimer = null;
        if (mounted && _anchored) _finishHold();
      }
    });
  }

  void _cancelHold() {
    _holdTimer?.cancel();
    _holdTimer = null;
    if (!mounted) return;
    setState(() {
      _pressed = false;
      _anchored = false;
      _progress = 0;
    });
  }

  void _finishHold() {
    _holdTimer?.cancel();
    _holdTimer = null;
    setState(() {
      _pressed = false;
      _anchored = false;
      _progress = 0;
    });
    widget.onHold?.call();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color;
    final colored = color != null;

    // Selected + colored: the tag's own color fills the chip.
    // Selected + monochrome: the usual ink fill.
    final bg = widget.selected
        ? (colored ? color! : AppColors.ink)
        : AppColors.surface;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _startHold(),
      onTapUp: (_) {
        final wasAnchored = _anchored;
        _cancelHold();
        // Quick tap (< 350ms): select. Anything after the anchor was a
        // deliberate hold — a release there never selects, and the
        // editor fires only when the hold actually completed.
        if (!wasAnchored) widget.onTapped();
      },
      onTapCancel: _cancelHold,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(AppRadius.pill),
              border: widget.selected ? null : Border.all(color: AppColors.stroke),
            ),
            child: Text(
              widget.label,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: widget.selected ? AppColors.bg : AppColors.inkDim,
              ),
            ),
          ),
          if (widget.onHold != null)
            Positioned.fill(
              child: AnimatedOpacity(
                opacity: _pressed && !_anchored ? 1 : 0,
                duration: const Duration(milliseconds: 120),
                child: Center(
                  child: Container(
                    width: 24,
                    height: 24,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: AppColors.bg.withValues(alpha: 0.8),
                      shape: BoxShape.circle,
                    ),
                    child: _progress >= 1
                        ? Icon(Icons.edit, size: 13, color: AppColors.ink)
                        : SizedBox(
                            width: _dotSize,
                            height: _dotSize,
                            child: CircularProgressIndicator(
                              strokeWidth: _dotSize,
                              value: _progress,
                              color: AppColors.ink,
                            ),
                          ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
