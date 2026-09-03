import 'package:flutter/material.dart';

import '../../core/theme/tokens.dart';

/// The app's ONE search field — pill-shaped, surface fill, hairline
/// stroke border (matching the pill buttons), no icon: the hint label
/// carries the affordance. Width adapts to its parent, so every surface
/// that hosts it (bottom control bar, bottom sheets, detail screens)
/// renders the SAME field at its own size.
class AppSearchField extends StatelessWidget {
  const AppSearchField({
    super.key,
    this.controller,
    this.focusNode,
    this.hint = 'Search',
    this.onChanged,
    this.autofocus = false,
  });

  final TextEditingController? controller;
  final FocusNode? focusNode;
  final String hint;
  final ValueChanged<String>? onChanged;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      focusNode: focusNode,
      onChanged: onChanged,
      autofocus: autofocus,
      style: TextStyle(color: AppColors.ink, fontSize: 13.5),
      decoration: InputDecoration(
        isDense: true,
        hintText: hint,
        hintStyle: TextStyle(color: AppColors.inkFaint, fontSize: 13.5),
        filled: true,
        fillColor: AppColors.surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.pill),
          borderSide: BorderSide(color: AppColors.stroke),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.pill),
          borderSide: BorderSide(color: AppColors.stroke),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.pill),
          borderSide: BorderSide(color: AppColors.inkDim),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
    );
  }
}
