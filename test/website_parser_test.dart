import 'package:flutter_test/flutter_test.dart';
import 'package:ulimit/data/website_providers.dart';

void main() {
  group('parseDomainList (StevenBlack hosts format)', () {
    test('parses 0.0.0.0 host lines — IP is skipped, domain captured', () {
      const body = '''
# Title: StevenBlack/hosts
#
# A comment line
0.0.0.0 ad.example.com
0.0.0.0 track.example.net
127.0.0.1 localhost
::1 ip6-localhost
255.255.255.255 broadcasthost

0.0.0.0
''';
      final domains = BlockListRepository.parseDomainList(body);
      expect(domains, containsAll(['ad.example.com', 'track.example.net']));
      // localhost / IP-only entries are NOT valid domains — skipped.
      expect(domains, isNot(contains('localhost')));
      expect(domains, isNot(contains('0.0.0.0')));
      expect(domains, isNot(contains('127.0.0.1')));
    });

    test('normalizes mixed adblock-style wrappers alongside host lines', () {
      const body = '''
||ads.example.org^
*.track.example.org
0.0.0.0 sub.example.com extra.example.com
''';
      final domains = BlockListRepository.parseDomainList(body);
      expect(domains, containsAll([
        'ads.example.org',
        'track.example.org',
        'sub.example.com',
      ]));
      // second token on a multi-domain host line: only first domain is a
      // valid single entry — extra.example.com is dropped (expected
      // simplification; upstream lines are single-domain).
      expect(domains, isNot(contains('extra.example.com')));
    });

    test('skips blank lines and comment-only lines', () {
      const body = '''
        
# just a comment
! adblock-style comment

0.0.0.0 only.com
''';
      final domains = BlockListRepository.parseDomainList(body);
      expect(domains, ['only.com']);
    });

    test('parses HaGeZi bare-domain lists (one domain per line)', () {
      const body = '''
# Title: HaGeZi ... mini version
# Syntax: Domains (without subdomains)
allegrolokalnie.0-230-23.rest
allegro.0000vv.study
kleinanzeigen.0002010.com

# trailing comment
''';
      final domains = BlockListRepository.parseDomainList(body);
      expect(domains, containsAll([
        'allegrolokalnie.0-230-23.rest',
        'allegro.0000vv.study',
        'kleinanzeigen.0002010.com',
      ]));
      expect(domains.length, 3);
    });
  });
}
