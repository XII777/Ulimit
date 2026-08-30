import 'dart:async';

import 'package:drift/drift.dart' hide Column;
import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/tokens.dart';


import '../../data/db/app_database.dart';
import '../../data/providers.dart';
import '../../data/restriction_providers.dart';
import '../../data/website_providers.dart';
import '../../shared/widgets/app_sheet.dart';

/// Live matches for the Add Website field: as the user types, existing
/// entries from every category (custom + downloaded lists) are searched
/// immediately. Found domains show a Disable/Enable toggle; unknown
/// domains show an explicit Add action. Typing alone never adds a site.
class _AddSuggestions extends ConsumerStatefulWidget {
  const _AddSuggestions({required this.query});

  final String query;

  @override
  ConsumerState<_AddSuggestions> createState() => _AddSuggestionsState();
}

class _AddSuggestionsState extends ConsumerState<_AddSuggestions> {
  Timer? _debounce;
  String? _lastQuery;
  List<WebsiteRule> _matches = const [];
  bool _loaded = false;
  bool _searched = false;

  @override
  void didUpdateWidget(_AddSuggestions old) {
    super.didUpdateWidget(old);
    if (old.query != widget.query) _schedule();
  }

  void _schedule() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), _run);
  }

  Future<void> _run() async {
    final raw = widget.query.trim();
    if (raw.length < 3) {
      setState(() {
        _matches = const [];
        _loaded = false;
        _searched = false;
      });
      return;
    }
    final normalized = normalizeDomain(raw);
    if (normalized.isEmpty) {
      setState(() {
        _matches = const [];
        _loaded = false;
        _searched = false;
      });
      return;
    }

    final db = ref.read(databaseProvider);
    final rows = await (db.select(db.websiteRules)
          ..where((t) => t.domain.like('$normalized%'))
          ..limit(5))
        .get();
    if (!mounted) return;
    setState(() {
      _matches = rows;
      _loaded = true;
      _searched = true;
      _lastQuery = raw;
    });
  }

  Future<void> _toggle(WebsiteRule rule) async {
    final db = ref.read(databaseProvider);
    await db.setRuleEnabled(rule.id, !rule.enabled);
    ref.read(enforcementSyncProvider).push();
    await _run();
  }

  Future<void> _add() async {
    final db = ref.read(databaseProvider);
    await db.addCustomDomain(widget.query);
    ref.read(enforcementSyncProvider).push();
    await _run();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded || !_searched) return const SizedBox.shrink();

    if (_matches.isEmpty) {
      final domain = normalizeDomain(widget.query);
      if (domain.isEmpty) return const SizedBox.shrink();
      return _SuggestionRow(
        domain: domain,
        status: 'Not in blocklist',
        actionLabel: 'Add',
        onAction: _add,
      );
    }

    return Column(
      children: [
        for (final rule in _matches)
          _SuggestionRow(
            domain: rule.domain,
            status: rule.enabled ? 'Blocked' : 'Not blocked',
            actionLabel: rule.enabled ? 'Disable' : 'Enable',
            onAction: () => _toggle(rule),
          ),
      ],
    );
  }
}

class _SuggestionRow extends StatelessWidget {
  const _SuggestionRow({
    required this.domain,
    required this.status,
    required this.actionLabel,
    required this.onAction,
  });

  final String domain;
  final String status;
  final String actionLabel;
  final Future<void> Function() onAction;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: AppColors.stroke),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(domain,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, color: AppColors.ink)),
                Text(status,
                    style: TextStyle(fontSize: 10.5, color: AppColors.inkFaint)),
              ],
            ),
          ),
          GestureDetector(
            onTap: () => onAction(),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
              decoration: BoxDecoration(
                color: AppColors.ink,
                borderRadius: BorderRadius.circular(AppRadius.pill),
              ),
              child: Text(actionLabel,
                  style: TextStyle(
                      fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.bg)),
            ),
          ),
        ],
      ),
    );
  }
}
