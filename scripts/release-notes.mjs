// Generates categorized release notes from the commits included in this
// release. Output goes to stdout; CI pipes it into body_path.
//
// Classification: conventional-commit prefixes first (feat/fix/perf/
// docs/chore/...), keyword fallback for plain messages ("Add ...",
// "Fix ...", ...). Every entry cites its short SHA, which GitHub
// renders as a commit link.
//
// Env: GITHUB_TOKEN, GITHUB_REPOSITORY ("owner/repo"), GITHUB_SHA.
// The previous release tag is discovered via the Releases API; if none
// exists (first release), all commits up to GITHUB_SHA are included.

const [owner, repo] = process.env.GITHUB_REPOSITORY.split('/');
const sha = process.env.GITHUB_SHA;
const token = process.env.GITHUB_TOKEN;

if (!owner || !sha || !token) {
  console.error('release-notes: missing GITHUB_REPOSITORY / GITHUB_SHA / GITHUB_TOKEN');
  process.exit(0); // never fail a release over notes
}

const headers = {
  Authorization: `Bearer ${token}`,
  Accept: 'application/vnd.github+json',
};

async function api(path) {
  const res = await fetch(`https://api.github.com${path}`, { headers });
  if (!res.ok) throw new Error(`GitHub API ${res.status}: ${await res.text()}`);
  return res.json();
}

const sections = [
  ['breaking', '⚠️ Breaking Changes'],
  ['feature', '🚀 Features'],
  ['fix', '🐛 Bug Fixes'],
  ['improvement', '🔧 Improvements'],
  ['performance', '⚡ Performance'],
  ['documentation', '📚 Documentation'],
  ['security', '🔒 Security'],
  ['maintenance', '🧹 Maintenance'],
];

function classify(message) {
  const firstLine = message.split('\n', 1)[0].trim();
  const breakingFooter = /breaking change/i.test(message) || /^BREAKING CHANGE/m.test(message);

  let subject = firstLine;
  let kind = null;
  const conventional = subject.match(/^(\w+)(\([^)]*\))?(!)?:\s+(.*)$/);
  if (conventional) {
    subject = conventional[4];
    if (conventional[3]) kind = 'breaking';
    else {
      switch (conventional[1].toLowerCase()) {
        case 'feat': kind = 'feature'; break;
        case 'fix': kind = 'fix'; break;
        case 'perf': kind = 'performance'; break;
        case 'docs': kind = 'documentation'; break;
        case 'security': kind = 'security'; break;
        case 'revert': kind = 'fix'; break;
        default: kind = 'maintenance'; // chore, build, ci, refactor, test, style
      }
    }
  }

  const lower = subject.toLowerCase();
  const has = (...words) => words.some((w) => lower.includes(w));
  if (!kind || breakingFooter) {
    if (breakingFooter || has('breaking')) kind = 'breaking';
  }
  if (!kind) {
    if (/^add\b/.test(lower)) kind = 'feature';
    else if (/^fix\b/.test(lower) || has('crash')) kind = 'fix';
    else if (/^(bump|upgrade|downgrade|update dependenc)/.test(lower)) kind = 'maintenance';
    else if (/^(optimi[sz]e|speed|cache|reduce|lazy)/.test(lower)) kind = 'performance';
    else if (/^(document|spec)/.test(lower)) kind = 'documentation';
    else if (/^(remove unused|clean)/.test(lower)) kind = 'maintenance';
    else kind = 'improvement';
  }

  // User-facing one-liner: strip prefix noise, cap length, tidy ending.
  let line = subject.replace(/\s+/g, ' ').trim();
  if (line.length > 120) line = `${line.slice(0, 117)}…`;
  line = line.replace(/[.]+$/, '');
  line = line.charAt(0).toUpperCase() + line.slice(1);
  return { kind: breakingFooter ? 'breaking' : kind, line };
}

try {
  // Previous release tag → the commit range this release covers.
  // RELEASE_PREV_TAG overrides discovery (useful for testing/backfill).
  let prevTag = process.env.RELEASE_PREV_TAG ?? null;
  if (!prevTag) {
    try {
      const releases = await api(`/repos/${owner}/${repo}/releases?per_page=1`);
      if (Array.isArray(releases) && releases.length > 0) prevTag = releases[0].tag_name;
    } catch (_) { /* fall through to full history */ }
  }

  let commits;
  if (prevTag) {
    const cmp = await api(`/repos/${owner}/${repo}/compare/${prevTag}...${sha}`);
    commits = cmp.commits ?? [];
  } else {
    commits = await api(`/repos/${owner}/${repo}/commits?sha=${sha}&per_page=100`);
  }

  const buckets = new Map(sections.map(([id]) => [id, []]));
  const seen = new Set();

  for (const c of commits) {
    const message = c.commit?.message ?? '';
    const { kind, line } = classify(message);
    const short = String(c.sha).slice(0, 7);
    const dedupeKey = line.toLowerCase();
    if (seen.has(dedupeKey)) continue;
    seen.add(dedupeKey);
    if (!buckets.has(kind)) buckets.set(kind, []);
    buckets.get(kind).push(`- ${line} (${short})`);
  }

  const out = [];
  for (const [id, label] of sections) {
    const entries = buckets.get(id) ?? [];
    if (entries.length === 0) continue;
    out.push(`## ${label}`);
    out.push('');
    out.push(...entries);
    out.push('');
  }

  if (out.length === 0) {
    out.push('## 🧹 Maintenance', '', '- Internal stability release with no user-facing changes.', '');
  }

  if (prevTag) {
    out.push(`---`, '', `**Full changelog:** https://github.com/${owner}/${repo}/compare/${prevTag}...${sha}`, '');
  }

  process.stdout.write(out.join('\n'));
} catch (error) {
  // Notes are best-effort: a fallback body keeps the release working.
  console.log('## 🧹 Maintenance\n\n- Stability release. See the commit history for details.\n');
  console.error(`release-notes: ${error.message || error}`);
}
