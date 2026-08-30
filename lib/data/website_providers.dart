import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import 'db/app_database.dart';
import 'providers.dart';

// ---------------------------------------------------------------------------
// Custom website rules
// ---------------------------------------------------------------------------

final customWebsiteRulesProvider = StreamProvider<List<WebsiteRule>>((ref) {
  final db = ref.watch(databaseProvider);
  final query = db.select(db.websiteRules)
    ..where((t) => t.category.equals('custom'))
    ..orderBy([(t) => OrderingTerm.asc(t.domain)]);
  return query.watch();
});

/// Normalizes arbitrary user input ("https://www.reddit.com/r/…" →
/// "reddit.com") so rule matching and the filter set never depend on
/// how a domain was typed or imported.
String normalizeDomain(String input) {
  var d = input.trim().toLowerCase();
  d = d.replaceAll(RegExp(r'^https?://'), '');
  d = d.split('/')[0];
  if (d.startsWith('www.')) d = d.substring(4);
  // Keep only plausible domain characters.
  if (!RegExp(r'^[a-z0-9.-]+$').hasMatch(d)) return '';
  if (!d.contains('.')) return '';
  return d;
}

extension WebsiteRulesActions on AppDatabase {
  Future<bool> addCustomDomain(String rawDomain) async {
    final domain = normalizeDomain(rawDomain);
    if (domain.isEmpty) return false;
    await into(websiteRules).insert(
      WebsiteRulesCompanion.insert(domain: domain, category: const Value('custom')),
      mode: InsertMode.insertOrIgnore,
    );
    return true;
  }

  Future<void> removeCustomDomain(int id) async {
    await (delete(websiteRules)..where((t) => t.id.equals(id))).go();
  }

  Future<void> setRuleEnabled(int id, bool enabled) async {
    await (update(websiteRules)..where((t) => t.id.equals(id)))
        .write(WebsiteRulesCompanion(enabled: Value(enabled)));
  }
}

// ---------------------------------------------------------------------------
// Block-list catalog (HaGeZi dns-blocklists)
// ---------------------------------------------------------------------------

/// A downloadable, categorized domain list. Sources are the HaGeZi
/// dns-blocklists `wildcard …-onlydomains` files: plain one-domain-per-
/// line lists, ideal for import into our WebsiteRules table. The
/// `mini`/`medium` variants are chosen for on-device scale; entries
/// counts are from the upstream README.
class BlockListTemplate {
  const BlockListTemplate({
    required this.id,
    required this.title,
    required this.description,
    required this.remotePath,
    required this.approxEntries,
    this.locksAfterEnable = false,
    this.recommended = false,
  });

  final String id;
  final String title;
  final String description;
  final String remotePath;
  final int approxEntries;

  /// One-way categories (Adult content): once enabled, the filter
  /// cannot be disabled — enforced by the `locked` flag in the DB and
  /// confirmed by a dialog before enabling.
  final bool locksAfterEnable;
  final bool recommended;

  String get url => 'https://raw.githubusercontent.com/hagezi/dns-blocklists/main/$remotePath';
}

const blockListCatalog = <BlockListTemplate>[
  BlockListTemplate(
    id: 'ads',
    title: 'Ads & Trackers',
    description:
        'Blocks ads, affiliate links, trackers, metrics and telemetry. Balanced, size-optimized list for phones.',
    remotePath: 'wildcard/pro.mini-onlydomains.txt',
    approxEntries: 56926,
    recommended: true,
  ),
  BlockListTemplate(
    id: 'security',
    title: 'Malware & Phishing',
    description:
        'Threat-intelligence feeds: malware, scams, phishing, cryptojacking and command-and-control domains.',
    remotePath: 'wildcard/tif.mini-onlydomains.txt',
    approxEntries: 176834,
    recommended: true,
  ),
  BlockListTemplate(
    id: 'scams',
    title: 'Scams & Fake Sites',
    description: 'Fake stores, fake streaming sites, rip-offs, subscription traps and similar scams.',
    remotePath: 'wildcard/fake-onlydomains.txt',
    approxEntries: 17284,
  ),
  BlockListTemplate(
    id: 'popupads',
    title: 'Pop-Up Ads',
    description: 'Annoying and malicious pop-up advertising domains.',
    remotePath: 'wildcard/popupads-onlydomains.txt',
    approxEntries: 54178,
  ),
  BlockListTemplate(
    id: 'piracy',
    title: 'Piracy',
    description: 'Sites and services mainly used for illegally distributing copyrighted content.',
    remotePath: 'wildcard/anti.piracy-onlydomains.txt',
    approxEntries: 45775,
  ),
  BlockListTemplate(
    id: 'gambling',
    title: 'Gambling',
    description: 'Gambling-related sites. Size-optimized variant for mobile devices.',
    remotePath: 'wildcard/gambling.mini-onlydomains.txt',
    approxEntries: 99165,
  ),
  BlockListTemplate(
    id: 'adult',
    title: 'Adult Content',
    description: 'Blocks adult content. This filter cannot be disabled after it is turned on.',
    remotePath: 'wildcard/nsfw-onlydomains.txt',
    approxEntries: 114339,
    locksAfterEnable: true,
  ),
  BlockListTemplate(
    id: 'social',
    title: 'Social Networks',
    description: 'Blocks social networks like Facebook, Instagram, TikTok, X and Snapchat.',
    remotePath: 'wildcard/social-onlydomains.txt',
    approxEntries: 902,
  ),
  BlockListTemplate(
    id: 'urlshortener',
    title: 'URL Shorteners',
    description: 'Blocks link shorteners that hide where a link actually leads.',
    remotePath: 'wildcard/urlshortener-onlydomains.txt',
    approxEntries: 9922,
  ),
  BlockListTemplate(
    id: 'hosting',
    title: 'Badware Hosting',
    description: 'Hosting providers that repeatedly serve malicious user-uploaded content.',
    remotePath: 'wildcard/hoster-onlydomains.txt',
    approxEntries: 1238,
  ),
  BlockListTemplate(
    id: 'dyndns',
    title: 'Dynamic DNS',
    description: 'Dynamic DNS services commonly abused for phishing campaigns.',
    remotePath: 'wildcard/dyndns-onlydomains.txt',
    approxEntries: 1540,
  ),
];

BlockListTemplate? templateFor(String id) {
  for (final t in blockListCatalog) {
    if (t.id == id) return t;
  }
  return null;
}

/// Downloaded/installed state per category, joined with the catalog.
class BlockListCategoryView {
  const BlockListCategoryView({
    required this.template,
    required this.downloaded,
    required this.enabled,
    required this.locked,
    required this.siteCount,
    required this.downloadedAt,
  });

  final BlockListTemplate template;
  final bool downloaded;
  final bool enabled;
  final bool locked;
  final int siteCount;
  final DateTime? downloadedAt;
}

final blockListCategoriesProvider = StreamProvider<List<BlockListCategoryView>>((ref) {
  final db = ref.watch(databaseProvider);
  return db.select(db.blockListCategories).watch().map((rows) {
    final byId = {for (final r in rows) r.id: r};
    return [
      for (final t in blockListCatalog)
        BlockListCategoryView(
          template: t,
          downloaded: byId[t.id]?.downloaded ?? false,
          enabled: byId[t.id]?.enabled ?? false,
          locked: byId[t.id]?.locked ?? false,
          siteCount: byId[t.id]?.siteCount ?? t.approxEntries,
          downloadedAt: byId[t.id]?.downloadedAt,
        ),
    ];
  });
});

enum BlockListDownloadState { idle, downloading, done, failed }

final blockListDownloadStateProvider =
    StateProvider.family<BlockListDownloadState, String>((ref, id) => BlockListDownloadState.idle);

class BlockListRepository {
  BlockListRepository(this._db);

  final AppDatabase _db;

  /// Downloads the category's list, replaces its rows while preserving
  /// per-site toggles, then marks the meta row. Returns imported count.
  Future<int> download(String categoryId) async {
    final template = templateFor(categoryId);
    if (template == null) return 0;

    final response = await http.get(Uri.parse(template.url)).timeout(const Duration(minutes: 2));
    if (response.statusCode != 200) {
      throw Exception('Failed to download list (${response.statusCode})');
    }

    final domains = parseDomainList(response.body);
    if (domains.isEmpty) throw Exception('List was empty');

    // Preserve the user's per-site toggles across updates.
    final existing = await (_db.select(_db.websiteRules)
          ..where((t) => t.category.equals(categoryId)))
        .get();
    final disabled = {for (final r in existing) if (!r.enabled) r.domain};

    await _db.transaction(() async {
      await (_db.delete(_db.websiteRules)..where((t) => t.category.equals(categoryId))).go();
      // Batched inserts keep per-statement overhead low on 100k+ row
      // lists.
      final rows = [
        for (final d in domains)
          WebsiteRulesCompanion.insert(
            domain: d,
            category: Value(categoryId),
            enabled: Value(!disabled.contains(d)),
          ),
      ];
      await _db.batch((b) {
        b.insertAll(_db.websiteRules, rows, mode: InsertMode.insertOrIgnore);
      });
    });

    final count = domains.length;
    await _db.into(_db.blockListCategories).insertOnConflictUpdate(
          BlockListCategoriesCompanion.insert(
            id: categoryId,
            downloaded: const Value(true),
            downloadedAt: Value(DateTime.now()),
            siteCount: Value(count),
          ),
        );
    return count;
  }

  Future<void> setCategoryEnabled(String categoryId, bool enabled) async {
    final row = await (_db.select(_db.blockListCategories)..where((t) => t.id.equals(categoryId)))
        .getSingleOrNull();
    final template = templateFor(categoryId);
    // One-way categories: once enabled, `locked` is set and the toggle
    // refuses further writes. The confirm dialog lives in the UI; the
    // repository enforces the invariant regardless of who calls it.
    if (row != null && row.locked && !enabled) return;

    await _db.into(_db.blockListCategories).insertOnConflictUpdate(
          BlockListCategoriesCompanion.insert(
            id: categoryId,
            downloaded: Value(row?.downloaded ?? false),
            enabled: Value(enabled),
            locked: Value((row?.locked ?? false) ||
                ((template?.locksAfterEnable ?? false) && enabled)),
            downloadedAt: Value(row?.downloadedAt),
            siteCount: Value(row?.siteCount ?? 0),
          ),
        );
  }

  Future<void> removeCategory(String categoryId) async {
    final row = await (_db.select(_db.blockListCategories)..where((t) => t.id.equals(categoryId)))
        .getSingleOrNull();
    if (row != null && row.locked) return;
    await _db.transaction(() async {
      await (_db.delete(_db.websiteRules)..where((t) => t.category.equals(categoryId))).go();
      await (_db.delete(_db.blockListCategories)..where((t) => t.id.equals(categoryId))).go();
    });
  }

  /// Parses a HaGeZi `-onlydomains` file: skips `#` comments and blank
  /// lines, lowercases, validates shape, dedupes.
  static List<String> parseDomainList(String body) {
    final result = <String>{};
    for (var line in body.split('\n')) {
      line = line.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      // Tolerate variants: "||domain^", "*.domain", "0.0.0.0 domain".
      line = line.replaceFirst(RegExp(r'^\|\|'), '').replaceFirst(RegExp(r'\^$'), '');
      line = line.replaceFirst(RegExp(r'^\*\.'), '');
      line = line.split(RegExp(r'\s')).first;
      final normalized = normalizeDomain(line);
      if (normalized.isNotEmpty) result.add(normalized);
    }
    return result.toList(growable: false);
  }
}

final blockListRepositoryProvider = Provider<BlockListRepository>(
  (ref) => BlockListRepository(ref.watch(databaseProvider)),
);

// ---------------------------------------------------------------------------
// Site browsing + search
// ---------------------------------------------------------------------------

Future<List<WebsiteRule>> querySites(
  AppDatabase db,
  String category,
  String query,
  int limit,
) {
  final like = '%${query.trim().toLowerCase()}%';
  final select = db.select(db.websiteRules)
    ..where((t) => t.category.equals(category) & t.domain.like(like))
    ..orderBy([(t) => OrderingTerm.asc(t.domain)])
    ..limit(limit);
  return select.get();
}

/// Browses/searches the sites of one category. Browsing a downloaded
/// list of 100k+ domains is paginated at the SQL layer — the UI only
/// ever materializes [limit] rows. The (category, query) record is the
/// family key, so editing the search field simply re-resolves.
final siteSearchProvider = FutureProvider.autoDispose
    .family<List<WebsiteRule>, (String, String)>((ref, args) {
  final (category, query) = args;
  final db = ref.watch(databaseProvider);
  return querySites(db, category, query, 300);
});
