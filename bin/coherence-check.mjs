#!/usr/bin/env node

/**
 * LID Coherence Check — optional reference implementation.
 *
 * This script is one way to perform the deterministic checks the arrow-maintenance
 * skill specifies. It is language-neutral in concept: equivalent implementations
 * in Python, bash, Ruby, Go, or any other language are fully acceptable. The
 * arrow-maintenance skill invokes whatever `bin/coherence-check.*` is present and
 * treats its output as authoritative; if nothing is present, the skill performs
 * the checks in-prompt (slower, more expensive).
 *
 * Install: copy this file to your project as `bin/coherence-check.mjs`, mark it
 * executable, and run `./bin/coherence-check.mjs` (or `node bin/coherence-check.mjs`).
 * Adjust the file globs and spec-ID regex to match your project's conventions.
 *
 * Paid adaptations (vs. the upstream reference impl): the grep include list adds
 * `*.rb` (this is a Rails app) and the exclude list adds `vendor`, `tmp`,
 * `.bundle`, `storage` (gem sources / transient Rails dirs that would yield
 * false-positive @spec matches); `--color=never` guards the line parser against
 * a `GREP_OPTIONS=--color=always` env silently injecting ANSI escapes. Re-apply
 * these after re-syncing from upstream.
 *
 * Checks performed (aligned with audit-checklist.md):
 *   1. @spec annotation integrity (orphaned refs, reverse orphans)
 *   2. Arrow reference integrity (broken file references in arrow detail docs)
 *   3. Arrow staleness (audited >30 days ago; UNMAPPED/MAPPED status)
 *   4. Coverage summary (per-arrow and repo-wide)
 *   5. Spec ID allocation collisions (newly declared IDs on the working tree
 *      vs the target branch since the integration base; duplicate
 *      declarations in the simulated integration tree)
 *
 * Not a blocker. Not a CI gate. Just a fast report. Exit code is always 0.
 *
 * Paid-only extension: check 5 reads git history. It resolves the target
 * branch from LID_TARGET_BRANCH (set by Lid::CoherenceCheck from the
 * project's default branch) or auto-detects origin/HEAD, and the
 * integration base from LID_BASE_SHA or `git merge-base`. Outside a git
 * repository, or when neither resolves, the section is skipped with an
 * advisory note. Re-apply this after re-syncing from upstream.
 */

import { readFileSync, readdirSync, existsSync, mkdtempSync, rmSync } from 'fs';
import { join, resolve } from 'path';
import { tmpdir } from 'os';
import { execSync, spawnSync } from 'child_process';

const ROOT = resolve(process.cwd());
const INTENT_DIR = join(ROOT, 'docs', 'intent');
const ARROWS_DIR = join(ROOT, 'docs', 'arrows');
const ARROWS_INDEX = join(ARROWS_DIR, 'index.yaml');

// ───────── Helpers ─────────

function fileExists(relPath) {
  return existsSync(join(ROOT, relPath));
}

function readFile(absPath) {
  try {
    return readFileSync(absPath, 'utf-8');
  } catch {
    return null;
  }
}

function daysSince(dateStr) {
  if (!dateStr) return Infinity;
  const d = new Date(dateStr);
  if (isNaN(d.getTime())) return Infinity;
  return Math.floor((Date.now() - d.getTime()) / (1000 * 60 * 60 * 24));
}

// ───────── 1. @spec annotation integrity ─────────

function collectSpecIdsFromCode() {
  let output;
  try {
    output = execSync(
      `grep -rn --color=never "@spec" --include="*.rb" --include="*.ts" --include="*.tsx" --include="*.js" --include="*.jsx" --include="*.py" --include="*.go" --include="*.rs" --exclude-dir=node_modules --exclude-dir=.git --exclude-dir=dist --exclude-dir=build --exclude-dir=target --exclude-dir=cdk.out --exclude-dir=coverage --exclude-dir=.next --exclude-dir=__pycache__ --exclude-dir=vendor --exclude-dir=tmp --exclude-dir=.bundle --exclude-dir=storage .`,
      { cwd: ROOT, encoding: 'utf-8', maxBuffer: 50 * 1024 * 1024 }
    );
  } catch (e) {
    output = e.stdout || '';
  }

  const codeRefs = new Map(); // specId -> [{file, line}]
  // Negative lookahead (?![a-z]) prevents mid-CamelCase matches like "GSI-B" from "GSI-ByReminderDue"
  // Post-filter (below): require at least one digit — excludes "A-Z" and "YYYYMMDD-HHMM" false positives
  const idPattern = /[A-Z][A-Z0-9]*(?:-[A-Z0-9]+)+(?![a-z])/g;

  for (const line of output.split('\n').filter(Boolean)) {
    const match = line.match(/^\.\/(.+?):(\d+):(.*)/);
    if (!match) continue;
    const [, file, lineNum, rest] = match;

    if (!/\bspec\b/i.test(rest)) continue; // filter to @spec context

    let m;
    while ((m = idPattern.exec(rest)) !== null) {
      const id = m[0];
      if (!/\d/.test(id)) continue; // skip ID-shaped tokens with no digits
      if (!codeRefs.has(id)) codeRefs.set(id, []);
      codeRefs.get(id).push({ file, line: parseInt(lineNum) });
    }
  }

  return codeRefs;
}

// Node-as-folder: spec files live beside their design doc as `*-specs.md`
// anywhere in the docs/intent/ tree. Walk it recursively.
function walkSpecFiles(dir) {
  const out = [];
  for (const ent of readdirSync(dir, { withFileTypes: true })) {
    const p = join(dir, ent.name);
    if (ent.isDirectory()) out.push(...walkSpecFiles(p));
    else if (ent.name.endsWith('-specs.md')) out.push(p);
  }
  return out;
}

function collectSpecIdsFromSpecs() {
  const specDefs = new Map();

  if (!existsSync(INTENT_DIR)) return specDefs;

  const files = walkSpecFiles(INTENT_DIR);

  for (const file of files) {
    const content = readFile(file);
    if (!content) continue;

    for (const line of content.split('\n')) {
      // Checklist style: - [x] **SPEC-ID**: description
      const checklist = line.match(/^-\s+\[([ xD])\]\s+\*\*([A-Z][\w-]+)\*\*/);
      if (checklist) {
        const [, marker, id] = checklist;
        const status = marker === 'x' ? 'implemented' : marker === 'D' ? 'deferred' : 'gap';
        specDefs.set(id, { file, status });
        continue;
      }
      // Heading style: ### SPEC-ID
      const heading = line.match(/^###\s+([A-Z][\w-]+)\b/);
      if (heading) {
        specDefs.set(heading[1], { file, status: 'defined' });
        continue;
      }
      // Bold style: **SPEC-ID**: description, with optional leading "- " dash-bullet (no checkbox)
      const bold = line.match(/^(?:-\s+)?\*\*([A-Z][\w-]+)\*\*:/);
      if (bold) {
        specDefs.set(bold[1], { file, status: 'defined' });
        continue;
      }
      // Table-cell style: | **SPEC-ID** | description | ... | (markdown table row)
      const tableCell = line.match(/^\|\s*\*\*([A-Z][\w-]+)\*\*\s*\|/);
      if (tableCell) {
        specDefs.set(tableCell[1], { file, status: 'defined' });
      }
    }
  }

  return specDefs;
}

function checkSpecIntegrity() {
  const codeRefs = collectSpecIdsFromCode();
  const specDefs = collectSpecIdsFromSpecs();

  const reverseOrphans = [];
  const uncovered = [];

  for (const [id, locations] of codeRefs) {
    if (!specDefs.has(id)) reverseOrphans.push({ id, locations });
  }

  for (const [id, info] of specDefs) {
    if (info.status === 'gap' && !codeRefs.has(id)) {
      uncovered.push({ id, file: info.file });
    }
  }

  return { codeRefs, specDefs, reverseOrphans, uncovered };
}

// ───────── 2. Arrow reference integrity ─────────

function parseArrowsIndex() {
  const content = readFile(ARROWS_INDEX);
  if (!content) return { arrows: {} };

  const arrows = {};
  let currentArrow = null;
  let inArrowsSection = false;

  for (const line of content.split('\n')) {
    if (/^arrows:\s*$/.test(line)) { inArrowsSection = true; continue; }
    if (/^[a-z][\w-]*:/.test(line) && !line.startsWith('  ')) {
      inArrowsSection = false;
      currentArrow = null;
      continue;
    }
    if (/^#/.test(line)) continue;
    if (!inArrowsSection) continue;

    const arrowMatch = line.match(/^  ([a-z][\w-]+):\s*$/);
    if (arrowMatch) {
      currentArrow = arrowMatch[1];
      arrows[currentArrow] = {};
      continue;
    }
    if (!currentArrow) continue;

    const kv = line.match(/^\s{4}(\w+):\s*(.+)/);
    if (kv) {
      let [, key, value] = kv;
      value = value.replace(/^["']|["']$/g, '').trim();
      if (value === 'null') value = null;
      if (value === '[]') value = [];
      arrows[currentArrow][key] = value;
    }
  }

  return { arrows };
}

function checkArrowReferences() {
  const { arrows } = parseArrowsIndex();
  const issues = [];

  for (const [name, meta] of Object.entries(arrows)) {
    if (!meta.detail) continue;
    const detailPath = join(ARROWS_DIR, meta.detail);
    if (!existsSync(detailPath)) {
      issues.push({ arrow: name, type: 'missing_detail', path: meta.detail });
      continue;
    }

    const content = readFile(detailPath);
    if (!content) continue;

    const refPattern = /(?:^[-*]\s+|→\s+|:\s+)`?([a-zA-Z][\w./~-]+\.[a-zA-Z]+)`?/gm;
    let m;
    while ((m = refPattern.exec(content)) !== null) {
      const ref = m[1];
      if (ref.includes('://') || ref.includes('*') || ref.includes('...')) continue;
      if (ref.match(/^\d+\.\d+/) || ref.match(/^[a-z]+\.[a-z]+$/)) continue;
      if (ref.includes('/') && !fileExists(ref)) {
        issues.push({ arrow: name, type: 'broken_ref', path: ref, detail: meta.detail });
      }
    }
  }

  return { arrows, issues };
}

// ───────── 3. Staleness ─────────

function checkStaleness() {
  const { arrows } = parseArrowsIndex();
  const stale = [];
  const needsWork = [];

  for (const [name, meta] of Object.entries(arrows)) {
    const status = meta.status;
    if (status === 'UNMAPPED' || status === 'MAPPED') {
      needsWork.push({ arrow: name, status, reason: `status is ${status}` });
      continue;
    }
    if (status === 'OBSOLETE' || status === 'OK') continue;

    const last = meta.audited || meta.sampled;
    const days = daysSince(last);
    if (days > 30) {
      stale.push({ arrow: name, status, lastAudited: last || 'never', daysSince: days === Infinity ? 'never' : days });
    }
  }

  return { stale, needsWork };
}

// ───────── 4. Coverage summary ─────────

function coverageSummary(specDefs, codeRefs) {
  let total = 0, implemented = 0, deferred = 0, gaps = 0;
  for (const [, info] of specDefs) {
    total++;
    if (info.status === 'implemented') implemented++;
    else if (info.status === 'deferred') deferred++;
    else if (info.status === 'gap') gaps++;
  }
  const defined = [...specDefs.values()].filter(v => v.status === 'defined').length;
  return { total, implemented, deferred, gaps, defined, codeRefsTotal: codeRefs.size };
}

// ───────── 5. Drift signals ─────────

function walkFiles(dir, predicate, out = []) {
  if (!existsSync(dir)) return out;

  for (const ent of readdirSync(dir, { withFileTypes: true })) {
    const path = join(dir, ent.name);
    if (ent.isDirectory()) walkFiles(path, predicate, out);
    else if (predicate(path)) out.push(path);
  }

  return out;
}

function relative(path) {
  return path.replace(`${ROOT}/`, '');
}

function tagged(path) {
  return readFile(path)?.includes('@spec') || false;
}

function behavioralRuby(path) {
  const content = readFile(path);
  return content ? /^\s*(class|module|def)\b/m.test(content) : false;
}

function rspecFile(path) {
  const content = readFile(path);
  return content ? /\bRSpec\.describe\b|\bdescribe\b|\bit\b/m.test(content) : false;
}

function checkDriftSignals() {
  const codeFiles = [
    ...walkFiles(join(ROOT, 'app'), path => path.endsWith('.rb')),
    ...walkFiles(join(ROOT, 'lib'), path => path.endsWith('.rb'))
  ];
  const testFiles = walkFiles(join(ROOT, 'spec'), path => path.endsWith('_spec.rb'));

  const untaggedCode = codeFiles
    .filter(path => behavioralRuby(path) && !tagged(path))
    .map(relative)
    .sort();
  const untaggedTests = testFiles
    .filter(path => rspecFile(path) && !tagged(path))
    .map(relative)
    .sort();

  return { untaggedCode, untaggedTests };
}

// ───────── 5. Spec ID allocation collisions ─────────

const GIT_TIMEOUT_MS = 20_000;

// Declaration forms, first match per line, mirroring collectSpecIdsFromSpecs.
const DECLARATION_PATTERNS = [
  /^-\s+\[([ xD])\]\s+\*\*([A-Z][\w-]+)\*\*/,
  /^###\s+([A-Z][\w-]+)\b/,
  /^(?:-\s+)?\*\*([A-Z][\w-]+)\*\*:/,
  /^\|\s*\*\*([A-Z][\w-]+)\*\*\s*\|/
];

function git(args, extraEnv = {}) {
  return spawnSync('git', args, {
    cwd: ROOT,
    encoding: 'utf-8',
    timeout: GIT_TIMEOUT_MS,
    env: { ...process.env, ...extraEnv }
  });
}

function gitOk(args, extraEnv = {}) {
  const result = git(args, extraEnv);
  return result.status === 0 ? result.stdout : null;
}

function parseDeclarationSites(content) {
  const sites = [];
  const lines = content.split('\n');
  for (let i = 0; i < lines.length; i++) {
    for (const pattern of DECLARATION_PATTERNS) {
      const match = lines[i].match(pattern);
      if (match) {
        sites.push({ id: match[match.length - 1], line: i + 1, text: lines[i].trim() });
        break;
      }
    }
  }
  return sites;
}

function addSites(map, sites, file) {
  for (const site of sites) {
    if (!map.has(site.id)) map.set(site.id, []);
    map.get(site.id).push({ file, line: site.line, text: site.text });
  }
}

function collectWorktreeSites() {
  const map = new Map();
  if (!existsSync(INTENT_DIR)) return map;

  for (const file of walkSpecFiles(INTENT_DIR)) {
    const content = readFile(file);
    if (content) addSites(map, parseDeclarationSites(content), relative(file));
  }
  return map;
}

function collectRefSites(ref) {
  const map = new Map();
  const listing = gitOk(['ls-tree', '-r', '--name-only', ref, '--', 'docs/intent']);
  if (listing === null) return null;

  for (const path of listing.split('\n').filter(Boolean)) {
    if (!path.endsWith('-specs.md')) continue;
    const content = gitOk(['show', `${ref}:${path}`]);
    if (content !== null) addSites(map, parseDeclarationSites(content), path);
  }
  return map;
}

// Best-effort refresh of the target tip so concurrently merged sibling PRs
// are visible even when the checkout predates their merge.
function refreshTargetTip(candidate) {
  const remote = candidate.ref.match(/^origin\/(.+)$/);
  if (!remote) return;

  const remotes = gitOk(['remote']);
  if (remotes === null || !remotes.split('\n').map(r => r.trim()).includes('origin')) return;

  const shallow = gitOk(['rev-parse', '--is-shallow-repository']);
  const depthArgs = shallow !== null && shallow.trim() === 'false' ? [] : ['--depth', '1'];
  git(['fetch', ...depthArgs, 'origin', `+refs/heads/${remote[1]}:refs/remotes/origin/${remote[1]}`], {
    GIT_TERMINAL_PROMPT: '0'
  });
}

function resolveTargetRef() {
  const requested = (process.env.LID_TARGET_BRANCH || '').trim();
  const candidates = [];
  const seen = new Set();
  const addCandidate = (ref, label) => {
    if (ref && !seen.has(ref)) {
      seen.add(ref);
      candidates.push({ ref, label });
    }
  };

  if (requested) {
    addCandidate(`origin/${requested}`, requested);
    addCandidate(requested, requested);
  } else {
    const originHead = gitOk(['symbolic-ref', '--short', 'refs/remotes/origin/HEAD']);
    if (originHead) addCandidate(originHead.trim(), originHead.trim());
    for (const fallback of ['origin/main', 'origin/master', 'main', 'master']) {
      addCandidate(fallback, fallback);
    }
  }

  if (candidates.length === 0) return { skipped: 'no target branch ref resolved' };

  refreshTargetTip(candidates[0]);

  for (const candidate of candidates) {
    const sha = gitOk(['rev-parse', '--verify', candidate.ref]);
    if (sha) return { ...candidate, sha: sha.trim() };
  }
  return { skipped: 'no target branch ref resolved' };
}

function resolveBaseRef(target) {
  const recorded = (process.env.LID_BASE_SHA || '').trim();
  if (recorded && gitOk(['cat-file', '-e', `${recorded}^{commit}`]) !== null) {
    return { ref: recorded, sha: recorded };
  }

  const mergeBase = gitOk(['merge-base', target.ref, 'HEAD']);
  if (mergeBase) return { ref: mergeBase.trim(), sha: mergeBase.trim() };

  return null;
}

// True when the target tip is already an ancestor of HEAD (the branch merged
// the target), false when it is not, null when ancestry cannot be decided.
function targetAlreadyMerged(target) {
  const result = git(['merge-base', '--is-ancestor', target.sha, 'HEAD']);
  if (result.status === 0) return true;
  if (result.status === 1) return false;
  return null;
}

// Simulates the textual integration of the working tree (uncommitted agent
// work included) with the target tip. The working tree is snapshotted into a
// commit through a temporary index, so the real index and working tree are
// never modified.
function integrationTree(target) {
  const scratch = mkdtempSync(join(tmpdir(), 'lid-coherence-'));
  try {
    const indexEnv = { GIT_INDEX_FILE: join(scratch, 'index') };
    if (git(['read-tree', 'HEAD'], indexEnv).status !== 0) return null;
    if (git(['add', '-A', '--', '.'], indexEnv).status !== 0) return null;

    const tree = gitOk(['write-tree'], indexEnv);
    if (tree === null) return null;

    const snapshot = gitOk(['commit-tree', tree.trim(), '-p', 'HEAD', '-m', 'lid-coherence-check snapshot']);
    if (snapshot === null) return null;

    const merged = git(['merge-tree', '--write-tree', snapshot.trim(), target.ref]);
    if (merged.status !== 0 && merged.status !== 1) return null;

    const mergedTree = (merged.stdout || '').split('\n')[0]?.trim();
    if (!mergedTree || !/^[0-9a-f]{40,}$/.test(mergedTree)) return null;

    return { tree: mergedTree, conflicts: merged.status === 1 };
  } catch {
    return null;
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
}

function siteKey(site) {
  return `${site.file}\u0000${site.text}`;
}

function duplicateDeclarations(sites, baseSites) {
  const baseKeys = new Set();
  for (const list of baseSites.values()) {
    for (const site of list) baseKeys.add(siteKey(site));
  }

  const duplicates = [];
  for (const [id, list] of sites) {
    if (list.length < 2) continue;
    if (list.some(site => !baseKeys.has(siteKey(site)))) duplicates.push({ id, sites: list });
  }
  return duplicates;
}

// @spec LID-RUNS-008, LID-RUNS-009, LID-RUNS-010
function checkSpecIdCollisions(codeRefs) {
  if (!existsSync(join(ROOT, '.git'))) return { skipped: 'not a git repository' };
  if (!existsSync(INTENT_DIR)) return { skipped: 'no docs/intent directory' };

  const target = resolveTargetRef();
  if (target.skipped) return { skipped: target.skipped };

  const base = resolveBaseRef(target);
  if (!base) return { skipped: 'integration base unresolvable (no common ancestor)' };

  const head = gitOk(['rev-parse', 'HEAD']);
  if (head === null) return { skipped: 'HEAD unresolvable' };

  const headSites = collectWorktreeSites();
  const targetSites = collectRefSites(target.ref);
  if (targetSites === null) return { skipped: 'target tree unreadable' };

  const baseSites = collectRefSites(base.ref) || new Map();
  if (headSites.size === 0 && targetSites.size === 0) {
    return { skipped: 'no docs/intent spec declarations found' };
  }

  const notes = [];
  const merged = targetAlreadyMerged(target);

  let collisions = [];
  if (merged === true) {
    notes.push('target tip already merged into HEAD; independent-allocation detection skipped');
  } else {
    const baseIds = new Set(baseSites.keys());
    const targetNew = new Set([...targetSites.keys()].filter(id => !baseIds.has(id)));
    for (const [id, headList] of headSites) {
      if (baseIds.has(id) || !targetNew.has(id)) continue;
      // A head declaration byte-identical to the target's declaration is an
      // adopted claim, not an independent allocation.
      const headTexts = new Set(headList.map(site => site.text));
      if (targetSites.get(id).some(site => headTexts.has(site.text))) continue;
      collisions.push({ id, headSites: headList, targetSites: targetSites.get(id), codeRefs: codeRefs.get(id) });
    }
  }

  let duplicates = [];
  let integration = integrationTree(target);
  if (integration) {
    const mergedSites = collectRefSites(integration.tree);
    if (mergedSites) {
      duplicates = duplicateDeclarations(mergedSites, baseSites);
    } else {
      notes.push('integration tree unreadable; scanned the working tree only');
      duplicates = duplicateDeclarations(headSites, baseSites);
      integration = null;
    }
  } else {
    notes.push('merge simulation unavailable; scanned the working tree only');
    duplicates = duplicateDeclarations(headSites, baseSites);
  }

  return { target, base, headSha: head.trim(), collisions, duplicates, integration, notes };
}

function truncate(text, limit) {
  return text.length > limit ? `${text.slice(0, limit - 1)}…` : text;
}

function formatSites(sites) {
  const first = sites[0];
  const more = sites.length > 1 ? ` (+${sites.length - 1} more)` : '';
  return `${first.file}:${first.line} "${truncate(first.text, 72)}"${more}`;
}

function renderCollisionSection(result) {
  if (result.skipped) {
    console.log(`  Collision check skipped: ${result.skipped}.`);
    return;
  }

  console.log(`  Target: ${result.target.label} (${result.target.sha}) | Base: ${result.base.sha} | Head: ${result.headSha}`);

  if (result.collisions.length) {
    console.log(`  Collisions (${result.collisions.length}) — IDs newly declared on both head and target since base:`);
    for (const collision of result.collisions) {
      console.log(`    ${collision.id}`);
      console.log(`      head: ${formatSites(collision.headSites)}`);
      console.log(`      target: ${formatSites(collision.targetSites)}`);
      const refs = (collision.codeRefs || [])
        .slice()
        .sort((a, b) => a.file.localeCompare(b.file) || a.line - b.line)
        .map(ref => `${ref.file}:${ref.line}`);
      console.log(`      @spec in head: ${refs.length ? refs.join(', ') : '(none)'}`);
    }
  } else {
    console.log('  No collisions detected.');
  }

  if (result.duplicates.length) {
    console.log(`  Duplicate declarations (${result.duplicates.length}) — IDs declared more than once in the integration tree:`);
    for (const duplicate of result.duplicates) {
      const where = duplicate.sites.map(site => `${site.file}:${site.line}`).join(', ');
      const origin = result.integration
        ? ` (integration tree ${result.integration.tree}${result.integration.conflicts ? ', merge conflicts' : ', textual auto-merge'})`
        : ' (working tree)';
      console.log(`    ${duplicate.id}: ${where}${origin}`);
    }
  } else {
    console.log('  No duplicate declarations in the integration tree.');
  }

  for (const note of result.notes) console.log(`  Note: ${note}.`);
}

// ───────── Report ─────────

function section(title) {
  console.log('');
  console.log('═'.repeat(60));
  console.log(`  ${title}`);
  console.log('═'.repeat(60));
}

function run() {
  console.log('LID Coherence Report');
  console.log(`Generated: ${new Date().toISOString().slice(0, 10)}`);
  console.log(`Root: ${ROOT}`);

  section('@spec Integrity');
  const { codeRefs, specDefs, reverseOrphans, uncovered } = checkSpecIntegrity();
  console.log(`  @spec annotations in code: ${codeRefs.size} unique IDs`);
  console.log(`  Spec definitions: ${specDefs.size} across docs/intent/`);

  if (reverseOrphans.length) {
    console.log(`\n  Reverse orphans (${reverseOrphans.length}) — @spec cites a spec that doesn't exist:`);
    for (const { id, locations } of reverseOrphans.slice(0, 25)) {
      const loc = locations[0];
      console.log(`    ${id}  (${loc.file}:${loc.line}${locations.length > 1 ? ` +${locations.length - 1}` : ''})`);
    }
    if (reverseOrphans.length > 25) console.log(`    ... and ${reverseOrphans.length - 25} more`);
  } else {
    console.log('  No reverse orphans.');
  }

  if (uncovered.length) {
    console.log(`\n  Uncovered [ ] specs (${uncovered.length}) — gap markers with no @spec ref:`);
    for (const { id, file } of uncovered.slice(0, 25)) console.log(`    ${id}  (${file})`);
    if (uncovered.length > 25) console.log(`    ... and ${uncovered.length - 25} more`);
  }

  section('Arrow Reference Integrity');
  const { arrows, issues } = checkArrowReferences();
  console.log(`  Arrows in index: ${Object.keys(arrows).length}`);
  if (issues.length) {
    for (const issue of issues) {
      if (issue.type === 'missing_detail') console.log(`    [MISSING] ${issue.arrow}: ${issue.path}`);
      else console.log(`    [BROKEN]  ${issue.arrow}: ${issue.path} (in ${issue.detail})`);
    }
  } else {
    console.log('  All arrow references valid.');
  }

  section('Staleness');
  const { stale, needsWork } = checkStaleness();
  if (needsWork.length) {
    console.log('  Needs work:');
    for (const w of needsWork) console.log(`    ${w.arrow}: ${w.reason}`);
  }
  if (stale.length) {
    console.log('  Stale (>30 days since audit):');
    for (const s of stale) console.log(`    ${s.arrow}: ${s.status}, ${s.lastAudited} (${s.daysSince} days)`);
  }
  if (!needsWork.length && !stale.length) console.log('  All arrows current.');

  const statusCounts = {};
  for (const [, meta] of Object.entries(arrows)) {
    const s = meta.status || 'UNKNOWN';
    statusCounts[s] = (statusCounts[s] || 0) + 1;
  }
  if (Object.keys(statusCounts).length) {
    console.log('\n  Status summary:');
    for (const [s, c] of Object.entries(statusCounts).sort()) console.log(`    ${s}: ${c}`);
  }

  section('Coverage');
  const cov = coverageSummary(specDefs, codeRefs);
  console.log(`  Total specs: ${cov.total + cov.defined}`);
  console.log(`    [x] implemented: ${cov.implemented}`);
  console.log(`    [ ] active gap:  ${cov.gaps}`);
  console.log(`    [D] deferred:    ${cov.deferred}`);
  console.log(`    (defined, no marker): ${cov.defined}`);
  console.log(`  Unique @spec IDs in code: ${cov.codeRefsTotal}`);

  section('Drift Signals');
  const drift = checkDriftSignals();
  console.log(`  Untagged code files (${drift.untaggedCode.length}) — behavior entry points with no @spec marker:`);
  for (const file of drift.untaggedCode.slice(0, 25)) console.log(`    ${file}`);
  if (drift.untaggedCode.length > 25) console.log(`    ... and ${drift.untaggedCode.length - 25} more`);

  console.log(`\n  Untagged test files (${drift.untaggedTests.length}) — tests with no @spec marker:`);
  for (const file of drift.untaggedTests.slice(0, 25)) console.log(`    ${file}`);
  if (drift.untaggedTests.length > 25) console.log(`    ... and ${drift.untaggedTests.length - 25} more`);

  section('Spec ID Allocation Collisions');
  renderCollisionSection(checkSpecIdCollisions(codeRefs));
  console.log('');
}

run();
