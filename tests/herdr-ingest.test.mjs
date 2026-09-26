// Test suite for herdr-ingest.
//
// The product is bash; node:test is only a harness. Every case runs against a
// throwaway fixture: a temp $HOME, a temp farm with its own git checkout, a
// temp $HERDR_INGEST_CACHE and a scrubbed $PATH. Nothing here reads or writes a
// real farm or a real cache, nothing requires herdr, zellij, fzf or omp to be
// installed, and nothing ever reaches Sentry, Linear or GitHub: payloads arrive
// through --items-json.

import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const LIB = path.join(REPO, 'lib', 'herdr-ingest.sh');
const CLI = path.join(REPO, 'bin', 'herdr-ingest');
const LAZY = path.join(REPO, 'lazy-brief');
const SKILL = path.join(REPO, 'skills', 'herdr-ingest', 'SKILL.md');
const PKG = JSON.parse(fs.readFileSync(path.join(REPO, 'package.json'), 'utf8'));

// A $PATH with no herdr, no zellij, no fzf and no omp on it.
const MIN_PATH = '/usr/bin:/bin:/usr/sbin:/sbin';
const BIN_DIRS = ['/usr/bin', '/bin', '/usr/local/bin', '/opt/homebrew/bin'];
const found = (name) => BIN_DIRS.map((d) => path.join(d, name)).find((p) => fs.existsSync(p));
const HAS_JQ = Boolean(found('jq'));
const HAS_GIT = Boolean(found('git'));
// The engine shells out to jq and git by name, so their real directories have to
// stay reachable even on the scrubbed PATH.
const TOOL_PATH = [...new Set([found('jq'), found('git')].filter(Boolean).map(path.dirname))]
  .concat(MIN_PATH.split(':'))
  .join(':');

// --- fixtures ----------------------------------------------------------------

// Resolved so that macOS /var -> /private/var does not break path equality.
const TMPROOT = fs.realpathSync(os.tmpdir());
const MADE = [];

function tmp(prefix = 'ingest-test-') {
  const dir = fs.mkdtempSync(path.join(TMPROOT, prefix));
  MADE.push(dir);
  return dir;
}

after(() => {
  for (const dir of MADE) {
    try {
      fs.rmSync(dir, { recursive: true, force: true });
    } catch {
      // a leftover temp dir is not a test failure
    }
  }
});

const mkdirp = (p) => (fs.mkdirSync(p, { recursive: true }), p);

function writeFile(p, body = '') {
  mkdirp(path.dirname(p));
  fs.writeFileSync(p, body);
  return p;
}

function writeExec(p, body) {
  writeFile(p, body);
  fs.chmodSync(p, 0o755);
  return p;
}

const q = (s) => `'${String(s).replace(/'/g, `'\\''`)}'`;

// Executable stubs that log their own invocation, so "was never called" is a
// real assertion instead of a hope.
function stubs(names) {
  const dir = tmp('ingest-stub-');
  const log = path.join(dir, 'invocations.log');
  for (const name of names) {
    writeExec(
      path.join(dir, name),
      `#!/bin/sh\nprintf '%s %s\\n' ${q(name)} "$*" >> ${q(log)}\nexit 0\n`,
    );
  }
  return {
    dir,
    path: `${dir}:${TOOL_PATH}`,
    calls: () =>
      fs.existsSync(log)
        ? fs.readFileSync(log, 'utf8').split('\n').filter((l) => l.length > 0)
        : [],
  };
}

// A herdr stub that answers the four calls a spawn makes. `panes` seeds
// `pane list`, so a test can present a space that already sits in a worktree.
function herdrStub({ panes = [] } = {}) {
  const dir = tmp('ingest-herdr-');
  const log = path.join(dir, 'invocations.log');
  const paneList = JSON.stringify({ result: { panes } });
  const created = JSON.stringify({
    result: { workspace: { workspace_id: 'wT' }, root_pane: { pane_id: 'wT:p1' } },
  });
  writeExec(
    path.join(dir, 'herdr'),
    `#!/bin/sh
printf 'herdr %s\\n' "$*" >> ${q(log)}
case "$1 $2" in
  'pane list') printf '%s\\n' ${q(paneList)} ;;
  'worktree create' | 'worktree open') printf '%s\\n' ${q(created)} ;;
esac
exit 0
`,
  );
  writeExec(path.join(dir, 'zellij'), `#!/bin/sh\nprintf 'zellij %s\\n' "$*" >> ${q(log)}\nexit 0\n`);
  return {
    dir,
    path: `${dir}:${TOOL_PATH}`,
    calls: () =>
      fs.existsSync(log)
        ? fs.readFileSync(log, 'utf8').split('\n').filter((l) => l.length > 0)
        : [],
  };
}

// A farm: a root holding a main checkout with one commit, plus whatever branches
// the case wants to pretend somebody is already working on.
function farm({ branches = [], files = {} } = {}) {
  const root = tmp('ingest-farm-');
  const main = mkdirp(path.join(root, 'main'));
  for (const [rel, body] of Object.entries(files)) writeFile(path.join(main, rel), body);
  if (!Object.keys(files).length) writeFile(path.join(main, 'README.md'), '# fixture\n');
  const git = (...args) =>
    spawnSync('git', ['-C', main, ...args], {
      encoding: 'utf8',
      env: { ...process.env, GIT_AUTHOR_NAME: 't', GIT_AUTHOR_EMAIL: 't@t', GIT_COMMITTER_NAME: 't', GIT_COMMITTER_EMAIL: 't@t' },
    });
  git('init', '-q', '-b', 'main');
  git('add', '-A');
  git('commit', '-qm', 'fixture');
  for (const b of branches) git('branch', b);
  return { root, main, git };
}

function sandbox(extra = {}) {
  const home = extra.HOME ?? tmp('ingest-home-');
  const cache = extra.HERDR_INGEST_CACHE ?? tmp('ingest-cache-');
  return {
    HOME: home,
    HERDR_INGEST_CACHE: cache,
    PATH: extra.PATH ?? TOOL_PATH,
    SHELL: '/bin/sh',
    ...extra,
  };
}

function run(args, { env = {}, input = undefined, cwd = REPO } = {}) {
  const res = spawnSync('bash', [CLI, ...args], {
    encoding: 'utf8',
    cwd,
    input,
    env: { ...sandbox(env) },
  });
  return { code: res.status, out: res.stdout ?? '', err: res.stderr ?? '', all: (res.stdout ?? '') + (res.stderr ?? '') };
}

function runLazy(args, { env = {}, input = '' } = {}) {
  const res = spawnSync('bash', [LAZY, ...args], {
    encoding: 'utf8',
    input,
    // /usr/bin/true accepts and ignores -l, so the script's final `exec $SHELL -l`
    // terminates instead of parking on a real login shell.
    env: { ...sandbox(env), SHELL: '/usr/bin/true' },
  });
  return { code: res.status, out: res.stdout ?? '', err: res.stderr ?? '' };
}

// --- payload fixtures --------------------------------------------------------

const SENTRY_PAYLOAD = [
  {
    id: '4512345678',
    shortId: 'PROJ-4F',
    title: "TypeError: cannot read 'quote' of undefined",
    culprit: 'app/services/quote.py in build',
    level: 'error',
    count: 1203,
    userCount: 31,
    firstSeen: '2026-08-01T10:00:00.000Z',
    lastSeen: '2026-08-19T22:10:00.000Z',
    status: 'unresolved',
    permalink: 'https://sentry.io/x/1',
    metadata: { type: 'TypeError', value: "cannot read 'quote' of undefined" },
  },
  {
    id: '4512999999',
    shortId: 'PROJ-9Z',
    title: 'TimeoutError: upstream took too long',
    culprit: 'app/clients/rpc.py in call',
    level: 'warning',
    count: 12,
    userCount: 2,
    firstSeen: '2026-08-18T10:00:00.000Z',
    lastSeen: '2026-08-20T01:00:00.000Z',
    status: 'unresolved',
    permalink: 'https://sentry.io/x/2',
    metadata: { type: 'TimeoutError', value: 'upstream took too long' },
  },
];

const LINEAR_PAYLOAD = {
  data: {
    issues: {
      pageInfo: { hasNextPage: false },
      nodes: [
        {
          id: 'uuid-1',
          identifier: 'ENG-412',
          title: 'Quote endpoint 500s on empty route',
          description: 'Reproduced on staging.',
          url: 'https://linear.app/x/ENG-412',
          branchName: 'dev/eng-412-quote-endpoint-500s',
          priority: 1,
          priorityLabel: 'Urgent',
          createdAt: '2026-08-10T09:00:00.000Z',
          updatedAt: '2026-08-19T18:00:00.000Z',
          state: { name: 'In Progress', type: 'started' },
          assignee: { displayName: 'Sam', email: 'sam@x.dev' },
          creator: { displayName: 'Ana' },
          labels: { nodes: [{ name: 'backend' }, { name: 'bug' }] },
          project: { name: 'Platform' },
          team: { key: 'ENG', name: 'Platform' },
          comments: { nodes: [{ createdAt: '2026-08-11T10:00:00.000Z', body: 'Router returns None.', user: { displayName: 'Ana' } }] },
        },
        {
          id: 'uuid-2',
          identifier: 'ENG-500',
          title: 'Add retry to rpc client',
          description: '',
          url: 'https://linear.app/x/ENG-500',
          branchName: '',
          priority: 3,
          priorityLabel: 'Medium',
          createdAt: '2026-08-15T09:00:00.000Z',
          updatedAt: '2026-08-16T09:00:00.000Z',
          state: { name: 'Todo', type: 'unstarted' },
          assignee: null,
          creator: { displayName: 'Sam' },
          labels: { nodes: [] },
          project: { name: 'Platform' },
          team: { key: 'ENG', name: 'Platform' },
          comments: { nodes: [] },
        },
      ],
    },
  },
};

const GITHUB_PAYLOAD = [
  {
    number: 412,
    title: 'Flaky test in quote suite',
    body: 'Fails 1 in 5 runs.',
    html_url: 'https://github.com/o/r/issues/412',
    state: 'open',
    created_at: '2026-08-01T00:00:00Z',
    updated_at: '2026-08-19T00:00:00Z',
    user: { login: 'ana' },
    labels: [{ name: 'flaky' }, { name: 'tests' }],
    assignees: [{ login: 'dev' }],
    comments: 3,
    milestone: { title: 'v2' },
  },
  {
    number: 420,
    title: 'Bump deps',
    body: '',
    html_url: 'https://github.com/o/r/pull/420',
    state: 'open',
    created_at: '2026-08-18T00:00:00Z',
    updated_at: '2026-08-20T00:00:00Z',
    user: { login: 'bot' },
    labels: [],
    assignees: [],
    comments: 0,
    pull_request: { url: 'x' },
  },
];

function payload(obj, name = 'payload.json') {
  return writeFile(path.join(tmp('ingest-payload-'), name), JSON.stringify(obj));
}

// A dry run with the sentry source over the fixture payload, which is the
// cheapest way to exercise stages 1 through 6 without a token or a herdr.
function dryRun(extraArgs = [], { fixture = SENTRY_PAYLOAD, source = 'sentry', env = {} } = {}) {
  const f = farm();
  const cache = tmp('ingest-cache-');
  const items = payload(fixture);
  const res = run(
    ['--source', source, '--root', f.root, '--items-json', items, '--auto', '--dry-run', ...extraArgs],
    { env: { HERDR_INGEST_CACHE: cache, ...env } },
  );
  return { ...res, farm: f, cache, sourceDir: path.join(cache, source), items };
}

const readCache = (dir, rel) => fs.readFileSync(path.join(dir, rel), 'utf8');
const cacheHas = (dir, rel) => fs.existsSync(path.join(dir, rel));

// --- the shape of the product -----------------------------------------------

test('the library is safe to source: it defines functions and runs nothing', () => {
  const res = spawnSync('bash', ['-c', `. ${q(LIB)} && declare -F | grep -c herdr_ingest_`], {
    encoding: 'utf8',
    env: sandbox(),
  });
  assert.equal(res.status, 0);
  assert.ok(Number(res.stdout.trim()) > 20, 'sourcing defines the engine functions');
  assert.equal(res.stdout.includes('sentry'), false, 'sourcing prints nothing');
});

test('every shipped bash file parses', () => {
  const files = [
    LIB,
    CLI,
    LAZY,
    path.join(REPO, 'profiles', 'example.sh'),
    path.join(REPO, 'examples', 'summarise-git-blame'),
    ...fs.readdirSync(path.join(REPO, 'lib', 'sources')).map((f) => path.join(REPO, 'lib', 'sources', f)),
  ];
  for (const f of files) {
    const res = spawnSync('bash', ['-n', f], { encoding: 'utf8' });
    assert.equal(res.status, 0, `${path.basename(f)} does not parse: ${res.stderr}`);
  }
});

test('--version matches package.json', () => {
  const res = run(['--version']);
  assert.equal(res.code, 0);
  assert.equal(res.out.trim(), PKG.version);
});

test('--help documents the six stages and both replaceable ones', () => {
  const res = run(['--help']);
  assert.equal(res.code, 0);
  for (const needle of [
    'fetch',
    'normalise',
    'select',
    'summarise',
    'prompt',
    'spawn',
    '--no-summarise',
    '--no-prompt',
    '--prompt-template',
    '--profile',
  ]) {
    assert.ok(res.out.includes(needle), `--help omits ${needle}`);
  }
  // The loaded source appends its own flags.
  assert.ok(res.out.includes('sentry source flags'), '--help omits the source flags');
});

test('--help for a chosen source shows that source flags', () => {
  const res = run(['--source', 'linear', '--help']);
  assert.equal(res.code, 0);
  assert.ok(res.out.includes('linear source flags'));
  assert.ok(!res.out.includes('sentry source flags'));
});

test('sources lists every built-in adapter with its prefix', () => {
  const res = run(['sources']);
  assert.equal(res.code, 0);
  for (const id of ['sentry', 'linear', 'github', 'json']) {
    assert.ok(new RegExp(`^${id}\\s`, 'm').test(res.out), `sources omits ${id}`);
  }
  assert.ok(/^github\s+gh\s/m.test(res.out), 'github declares the gh prefix');
});

test('an unknown source and an unknown flag both exit 2', () => {
  const bad = run(['--source', 'jira']);
  assert.equal(bad.code, 2);
  assert.ok(bad.err.includes('unknown source: jira'));
  assert.ok(bad.err.includes('sentry'), 'the error names the built-ins');

  const flag = run(['--nope']);
  assert.equal(flag.code, 2);
  assert.ok(flag.err.includes('unknown flag: --nope'));
});

test('a source file given by path drives the whole run', { skip: !HAS_JQ || !HAS_GIT }, () => {
  const dir = tmp('ingest-src-');
  const good = writeFile(
    path.join(dir, 'good.sh'),
    `HERDR_INGEST_SOURCE_ID=custom
HERDR_INGEST_SOURCE_PREFIX=cus
ingest_source_describe() { printf 'custom\\tone hard-coded item\\n'; }
ingest_source_fetch() { printf '[{"id":"Q-9","name":"Widget is stuck"}]'; }
ingest_source_normalize() { jq -c '[.[] | {key: .id, title: .name}]'; }
`,
  );
  const f = farm();
  // No --items-json: stage 1 comes from the file, which proves it is loaded.
  const ok = run(['--source', good, '--root', f.root, '--auto', '--dry-run', '--no-summarise'], {
    env: { HERDR_INGEST_CACHE: tmp('ingest-cache-') },
  });
  assert.equal(ok.code, 0, ok.err);
  assert.match(ok.out, /^custom · 1 of 1 item\(s\) kept/m);
  assert.match(ok.out, /Q-9\s+cus-q-9\s+would spawn -> fix\/cus-q-9-widget-is-stuck/);

  const bad = writeFile(path.join(dir, 'bad.sh'), `ingest_source_describe() { :; }\n`);
  const refused = run(['--source', bad, '--root', f.root]);
  assert.equal(refused.code, 2);
  assert.ok(refused.err.includes('ingest_source_fetch'), 'the error names the missing verb');
});

// --- stage 1 and 2: sources --------------------------------------------------

test('the sentry source normalises its payload and reproduces the farm naming', { skip: !HAS_JQ || !HAS_GIT }, () => {
  const r = dryRun();
  assert.equal(r.code, 0);
  assert.match(r.out, /sentry · 2 of 2 item\(s\) kept/);
  assert.match(r.out, /PROJ-4F\s+sentry-4512345678\s+would spawn -> fix\/sentry-4512345678-cannot-read-quote-of-undefined/);
  assert.match(r.out, /PROJ-9Z\s+sentry-4512999999\s+would spawn -> fix\/sentry-4512999999-upstream-took-too-long/);
});

test('the linear source keeps the branch name Linear itself suggested', { skip: !HAS_JQ || !HAS_GIT }, () => {
  const r = dryRun([], { fixture: LINEAR_PAYLOAD, source: 'linear' });
  assert.equal(r.code, 0);
  assert.match(r.out, /ENG-412\s+linear-eng-412\s+would spawn -> dev\/eng-412-quote-endpoint-500s/);
  // No branch in the payload, so the engine derives one from the title.
  assert.match(r.out, /ENG-500\s+linear-eng-500\s+would spawn -> fix\/linear-eng-500-add-retry-to-rpc-client/);
});

test('the linear source sweeps a team offline with --team and normalises items', { skip: !HAS_JQ || !HAS_GIT }, () => {
  const r = dryRun(['--team', 'ENG'], { fixture: LINEAR_PAYLOAD, source: 'linear' });
  assert.equal(r.code, 0, r.err);
  assert.match(r.out, /linear · 2 of 2 item\(s\) kept/);
  assert.match(r.out, /ENG-412\s+linear-eng-412\s+would spawn -> dev\/eng-412-quote-endpoint-500s/);
  assert.match(r.out, /ENG-500\s+linear-eng-500\s+would spawn -> fix\/linear-eng-500-add-retry-to-rpc-client/);
});

test('HERDR_INGEST_LINEAR_TEAM supplies the default and --team beats it', { skip: !HAS_JQ || !HAS_GIT }, () => {
  // A curl stub records the POST body and answers with an empty page, so a live
  // fetch completes offline and the filter it built is inspectable.
  const dir = tmp('ingest-curl-');
  const body = path.join(dir, 'body.json');
  writeExec(
    path.join(dir, 'curl'),
    `#!/bin/sh
prev=
for a in "$@"; do
  [ "$prev" = --data-binary ] && printf '%s' "$a" > ${q(body)}
  prev="$a"
done
printf '%s\\n200' '{"data":{"issues":{"pageInfo":{"hasNextPage":false},"nodes":[]}}}'
`,
  );
  const stubbedPath = `${dir}:${TOOL_PATH}`;
  const f = farm();

  const fromEnv = run(['--source', 'linear', '--root', f.root, '--auto', '--dry-run'], {
    env: { LINEAR_API_KEY: 'lin_api_x', HERDR_INGEST_LINEAR_TEAM: 'ENG', PATH: stubbedPath },
  });
  assert.equal(fromEnv.code, 0, fromEnv.err);
  assert.ok(fs.readFileSync(body, 'utf8').includes('"eq":"ENG"'), 'the profile default reaches the filter');

  const overridden = run(['--source', 'linear', '--root', f.root, '--team', 'PLT', '--auto', '--dry-run'], {
    env: { LINEAR_API_KEY: 'lin_api_x', HERDR_INGEST_LINEAR_TEAM: 'ENG', PATH: stubbedPath },
  });
  assert.equal(overridden.code, 0, overridden.err);
  const sent = fs.readFileSync(body, 'utf8');
  assert.ok(sent.includes('"eq":"PLT"'), 'the command-line --team wins');
  assert.ok(!sent.includes('"eq":"ENG"'), 'the default is not carried alongside it');
});

test('the linear source folds the discussion into the brief', { skip: !HAS_JQ || !HAS_GIT }, () => {
  const r = dryRun([], { fixture: LINEAR_PAYLOAD, source: 'linear' });
  const brief = readCache(r.sourceDir, 'briefs/eng-412.md');
  assert.ok(brief.includes('Reproduced on staging.'));
  assert.ok(brief.includes('### Discussion'));
  assert.ok(brief.includes('Router returns None.'));
  assert.ok(brief.includes('| priority | urgent |'));
});

test('the github source badges a pull request apart from an issue', { skip: !HAS_JQ || !HAS_GIT }, () => {
  const all = dryRun(['--no-summarise'], { fixture: GITHUB_PAYLOAD, source: 'github' });
  assert.match(all.out, /2 of 2 item\(s\) kept/);
  assert.match(all.out, /#420\s+gh-420/);
  assert.match(all.out, /#412\s+gh-412/);

  const issues = dryRun(['--no-summarise', '--badge', 'issue'], { fixture: GITHUB_PAYLOAD, source: 'github' });
  assert.match(issues.out, /1 of 2 item\(s\) kept/);
  assert.match(issues.out, /#412/);
  assert.ok(!issues.out.includes('#420'));
});

test('the json source maps an arbitrary payload through a jq expression', { skip: !HAS_JQ || !HAS_GIT }, () => {
  const r = dryRun(
    [
      '--prefix',
      'ops',
      '--json-map',
      '[.tickets[] | {key: .code, title: .summary, url: .link, badge: .sev, state: .status, updated: .touched, body: .notes}]',
    ],
    {
      source: 'json',
      fixture: { tickets: [{ code: 'OPS-7', summary: 'Rotate the staging cert', link: 'https://ops/7', sev: 'high', status: 'open', touched: '2026-08-19T12:00:00Z', notes: 'expires friday' }] },
    },
  );
  assert.equal(r.code, 0);
  assert.match(r.out, /1 of 1 item\(s\) kept/);
  assert.match(r.out, /OPS-7\s+ops-ops-7\s+would spawn -> fix\/ops-ops-7-rotate-the-staging-cert/);
  const brief = readCache(r.sourceDir, 'briefs/ops-7.md');
  assert.ok(brief.includes('expires friday'), 'the mapped body reaches the brief');
});

test('a source flag actually sticks: it is parsed in the engine shell, not a subshell', { skip: !HAS_JQ || !HAS_GIT }, () => {
  // --json-map is a source flag. If the source parsed it in a command
  // substitution the value would be lost and nothing would be kept.
  const kept = dryRun(['--json-map', '[.rows[] | {key: .id, title: .name}]'], {
    source: 'json',
    fixture: { rows: [{ id: 'A1', name: 'first' }] },
  });
  assert.match(kept.out, /1 of 1 item\(s\) kept/);

  const dropped = dryRun([], { source: 'json', fixture: { rows: [{ id: 'A1', name: 'first' }] } });
  assert.match(dropped.out, /0 of 0 item\(s\) kept/, 'without the map the wrapper object yields no key');
});

test('an item needs only a key: every other field is filled in', { skip: !HAS_JQ || !HAS_GIT }, () => {
  const r = dryRun([], { source: 'json', fixture: [{ key: 'BARE-1' }] });
  assert.equal(r.code, 0);
  assert.match(r.out, /1 of 1 item\(s\) kept/);
  const brief = readCache(r.sourceDir, 'briefs/bare-1.md');
  assert.ok(brief.includes('# BARE-1 — untitled'), 'ref falls back to key, title to untitled');
  const row = readCache(r.sourceDir, 'items.rows').trim().split('\u001f');
  assert.deepEqual(row.slice(0, 4), ['BARE-1', 'BARE-1', '-', '-']);
});

test('an item with no labels does not shift the fields after it', { skip: !HAS_JQ || !HAS_GIT }, () => {
  // Tab is IFS whitespace, so a tab-separated row would collapse the empty
  // labels field and hand the branch slug the url. The row separator is the
  // unit separator for exactly this reason.
  const r = dryRun(['--no-summarise'], { fixture: GITHUB_PAYLOAD, source: 'github' });
  const rows = readCache(r.sourceDir, 'items.rows').trim().split('\n');
  const bump = rows.find((l) => l.includes('Bump deps')).split('\u001f');
  assert.equal(bump.length, 9, 'nine fields, empty ones included');
  assert.equal(bump[6], '', 'labels is empty');
  assert.equal(bump[7], 'Bump deps', 'title still lands in the title field');
  assert.match(r.out, /gh-420\s+would spawn -> fix\/gh-420-bump-deps/);
});

// --- stage 3: select ---------------------------------------------------------

test('--badge, --state, --label and --match each narrow the sweep', { skip: !HAS_JQ || !HAS_GIT }, () => {
  assert.match(dryRun(['--no-summarise', '--badge', 'error']).out, /1 of 2/);
  assert.match(dryRun(['--no-summarise', '--badge', 'error,warning']).out, /2 of 2/);
  assert.match(dryRun(['--no-summarise', '--state', 'unresolved']).out, /2 of 2/);
  assert.match(dryRun(['--no-summarise', '--state', 'resolved']).out, /0 of 2/);
  assert.match(dryRun(['--no-summarise', '--label', 'timeouterror']).out, /1 of 2/);
  assert.match(dryRun(['--no-summarise', '--match', 'timeout']).out, /1 of 2/);
  assert.match(dryRun(['--no-summarise', '--match', 'quote.py']).out, /1 of 2/, '--match sees the subtitle too');
});

test('--sort badge orders by the severity the source declared', { skip: !HAS_JQ || !HAS_GIT }, () => {
  const r = dryRun(['--no-summarise', '--sort', 'badge']);
  const order = r.out.match(/PROJ-\w+/g);
  assert.deepEqual(order, ['PROJ-4F', 'PROJ-9Z'], 'error before warning');

  const byUpdated = dryRun(['--no-summarise', '--sort', 'updated']);
  assert.deepEqual(byUpdated.out.match(/PROJ-\w+/g), ['PROJ-9Z', 'PROJ-4F'], 'newest first');
});

test('--badge-order ranks badges the source never declared', { skip: !HAS_JQ || !HAS_GIT }, () => {
  // The whole point of the flag: a generic payload carries whatever severity
  // words its tracker uses, and the json source cannot know how to rank them.
  const f = farm();
  const items = payload([
    { key: 'a', badge: 'low', title: 'a' },
    { key: 'b', badge: 'critical', title: 'b' },
    { key: 'c', badge: 'medium', title: 'c' },
  ]);
  const sweep = (extra) =>
    run(['--source', 'json', '--json-map', '.', '--items-json', items, '--root', f.root,
      '--auto', '--dry-run', '--no-summarise', '--sort', 'badge', ...extra],
      { env: { HERDR_INGEST_CACHE: tmp('ingest-cache-') } });

  // The lookahead keeps this to the worktree column; the branch column repeats
  // the same token as `fix/item-b-<slug>`.
  const spawned = (r) => r.out.match(/item-[abc](?=\s)/g);

  assert.deepEqual(spawned(sweep(['--badge-order', 'critical,medium,low'])),
    ['item-b', 'item-c', 'item-a']);

  // Reversing the ranking reverses the sweep, which proves the flag is what
  // ordered it rather than any incidental payload order.
  assert.deepEqual(spawned(sweep(['--badge-order', 'low,medium,critical'])),
    ['item-a', 'item-c', 'item-b']);
});

test('--badge-order beats the ranking the source declared', { skip: !HAS_JQ || !HAS_GIT }, () => {
  // sentry ranks fatal > error > warning in its own file; the flag inverts it.
  const r = dryRun(['--no-summarise', '--sort', 'badge', '--badge-order', 'warning,error']);
  assert.deepEqual(r.out.match(/PROJ-\w+/g), ['PROJ-9Z', 'PROJ-4F'], 'warning before error');
});

test('--updated-last and --created-last drop what falls outside the window', { skip: !HAS_JQ || !HAS_GIT }, () => {
  // The fixture timestamps are fixed in the past, so any real window excludes
  // both items and a very wide one keeps them.
  assert.match(dryRun(['--no-summarise', '--updated-last', '1h']).out, /0 of 2/);
  assert.match(dryRun(['--no-summarise', '--updated-last', '52w']).out, /(0|1|2) of 2/);
  const bad = dryRun(['--updated-last', '2x']);
  assert.equal(bad.code, 2);
  assert.ok(bad.err.includes('invalid window'));
});

test('--limit caps the kept items and --max-spaces caps one sweep', { skip: !HAS_JQ || !HAS_GIT }, () => {
  assert.match(dryRun(['--no-summarise', '--limit', '1']).out, /1 of 2/);
  const capped = dryRun(['--no-summarise', '--max-spaces', '1']);
  assert.match(capped.out, /1 more item\(s\) held back by --max-spaces 1/);
  assert.equal((capped.out.match(/would spawn/g) ?? []).length, 1);
});

test('non-positive numbers and a bad --sort exit 2', { skip: !HAS_JQ || !HAS_GIT }, () => {
  for (const args of [['--limit', '0'], ['--max-spaces', 'x'], ['--interval', '-1'], ['--sort', 'sideways']]) {
    const r = dryRun(args);
    assert.equal(r.code, 2, `${args.join(' ')} should exit 2`);
  }
});

test('--watch without --auto is refused', () => {
  const f = farm();
  const r = run(['--root', f.root, '--watch', '--items-json', payload(SENTRY_PAYLOAD), '--dry-run']);
  assert.equal(r.code, 2);
  assert.ok(r.err.includes('--watch needs --auto'));
});

// --- stage 4: summarise ------------------------------------------------------

test('the source summariser is the default, and the header names the mode', { skip: !HAS_JQ || !HAS_GIT }, () => {
  // The sentry summariser needs a token to fetch an event, so with --items-json
  // it resolves to `source` and quietly produces nothing.
  const r = dryRun();
  assert.match(r.out, /summarise source · prompt builtin/);
  assert.equal(fs.readFileSync(path.join(r.sourceDir, 'summaries/4512345678.md'), 'utf8'), '');
  assert.ok(!readCache(r.sourceDir, 'briefs/4512345678.md').includes('## Context'));
});

test('--no-summarise turns stage 4 off', { skip: !HAS_JQ || !HAS_GIT }, () => {
  const r = dryRun(['--no-summarise']);
  assert.match(r.out, /summarise off/);
});

test('--summarise CMD writes the brief Context section', { skip: !HAS_JQ || !HAS_GIT }, () => {
  const r = dryRun(['--summarise', 'printf "seen %s in %s\\n" "$(jq -r .key "$1")" "$2"']);
  const brief = readCache(r.sourceDir, 'briefs/4512345678.md');
  assert.ok(brief.includes('## Context'));
  assert.ok(brief.includes('seen 4512345678 in'), 'the hook receives the item and the worktree');
  assert.ok(brief.includes('sentry-4512345678'), 'the worktree argument is the item worktree');
});

test('the shipped git-blame summariser reports the history of the culprit file', { skip: !HAS_JQ || !HAS_GIT }, () => {
  const f = farm({ files: { 'app/services/quote.py': 'def build():\n    return None\n' } });
  const cache = tmp('ingest-cache-');
  const script = path.join(REPO, 'examples', 'summarise-git-blame');
  const r = run(
    [
      '--root', f.root,
      '--items-json', payload(SENTRY_PAYLOAD),
      '--auto', '--dry-run',
      '--summarise', `exec ${q(script)} "$1" "$2"`,
    ],
    { env: { HERDR_INGEST_CACHE: cache } },
  );
  assert.equal(r.code, 0);
  const brief = readCache(path.join(cache, 'sentry'), 'briefs/4512345678.md');
  assert.ok(brief.includes('Recent history of `app/services/quote.py`'));
  assert.ok(brief.includes('fixture'), 'the commit subject appears');
});

test('a failing summariser costs the item its summary, never its space', { skip: !HAS_JQ || !HAS_GIT }, () => {
  const r = dryRun(['--summarise', 'printf partial; exit 7']);
  assert.equal(r.code, 0, 'the sweep still succeeds');
  assert.match(r.out, /would spawn/);
  assert.ok(r.err.includes('summariser failed'), 'the failure is reported');
  assert.equal(fs.readFileSync(path.join(r.sourceDir, 'summaries/4512345678.md'), 'utf8'), '',
    'a partial summary is discarded, not pasted into the brief');
});

// --- stage 5: prompt ---------------------------------------------------------

test('the built-in brief carries the item table, the task and the branch', { skip: !HAS_JQ || !HAS_GIT }, () => {
  const r = dryRun(['--no-summarise']);
  const brief = readCache(r.sourceDir, 'briefs/4512345678.md');
  assert.ok(brief.startsWith("# PROJ-4F — TypeError: cannot read 'quote' of undefined"));
  assert.ok(brief.includes('| key | `4512345678` |'));
  assert.ok(brief.includes('| events | 1203 |'));
  assert.ok(brief.includes('| source | sentry |'));
  assert.ok(brief.includes('`fix/sentry-4512345678-cannot-read-quote-of-undefined`'));
  assert.ok(brief.includes('## Task'));
  assert.ok(brief.includes('Do not push to main.'));
});

test('the built-in brief points at the repository workflow when the checkout ships one', { skip: !HAS_JQ || !HAS_GIT }, () => {
  const f = farm({ files: { '.claude/skills/sentry-triage-fix/SKILL.md': '# workflow\n', 'README.md': 'x\n' } });
  const cache = tmp('ingest-cache-');
  const r = run(['--root', f.root, '--items-json', payload(SENTRY_PAYLOAD), '--auto', '--dry-run', '--no-summarise'], {
    env: { HERDR_INGEST_CACHE: cache },
  });
  assert.equal(r.code, 0);
  const brief = readCache(path.join(cache, 'sentry'), 'briefs/4512345678.md');
  assert.ok(brief.includes('.claude/skills/sentry-triage-fix/SKILL.md'));
  assert.ok(brief.includes('Honour its drop rules'));
});

test('--prompt-template renders every documented slot', { skip: !HAS_JQ || !HAS_GIT }, () => {
  const tpl = writeFile(
    path.join(tmp('ingest-tpl-'), 't.md'),
    ['{{ref}}|{{key}}|{{title}}|{{badge}}|{{state}}|{{labels}}|{{source}}',
      'branch={{branch}}',
      'worktree={{worktree}}',
      'main={{main}}',
      'url={{url}}',
      'item={{item_json}}',
      'fields:',
      '{{fields}}',
      'summary:',
      '{{summary}}',
      'body:',
      '{{body}}',
      ''].join('\n'),
  );
  const r = dryRun(['--prompt-template', tpl, '--summarise', 'printf "CTX\\n"']);
  assert.match(r.out, /prompt template/);
  const brief = readCache(r.sourceDir, 'briefs/4512345678.md');
  assert.ok(brief.startsWith("PROJ-4F|4512345678|TypeError: cannot read 'quote' of undefined|error|unresolved|TypeError|sentry"));
  assert.ok(brief.includes('branch=fix/sentry-4512345678-cannot-read-quote-of-undefined'));
  assert.ok(brief.includes('- events: 1203'), 'the fields slot expands to a list');
  assert.ok(brief.includes('CTX'), 'the summary slot carries stage 4 output');
  assert.ok(brief.includes(path.join(r.sourceDir, 'items/4512345678.json')), 'item_json is a real path');
  assert.ok(!brief.includes('{{'), 'no slot is left unrendered');
});

test('a template survives a body carrying regex and backslash metacharacters', { skip: !HAS_JQ || !HAS_GIT }, () => {
  const tpl = writeFile(path.join(tmp('ingest-tpl-'), 't.md'), 'BODY[{{body}}]\n');
  const nasty = 'a & b \\1 \\n & c $0 {{ref}}';
  const r = dryRun(['--prompt-template', tpl, '--no-summarise'], {
    source: 'json',
    fixture: [{ key: 'X1', title: 'x', body: nasty }],
  });
  const brief = readCache(r.sourceDir, 'briefs/x1.md');
  assert.equal(brief.trim(), `BODY[${nasty}]`, 'the body is substituted literally');
});

test('--prompt CMD writes the brief, and an empty one means no brief', { skip: !HAS_JQ || !HAS_GIT }, () => {
  const wrote = dryRun(['--no-summarise', '--prompt', 'printf "custom %s\\n" "$(jq -r .ref "$1")" > "$3"']);
  assert.match(wrote.out, /prompt cmd/);
  assert.equal(readCache(wrote.sourceDir, 'briefs/4512345678.md').trim(), 'custom PROJ-4F');
  assert.ok(readCache(wrote.sourceDir, 'sentry-4512345678.kdl').includes('briefs/4512345678.md'));

  const silent = dryRun(['--no-summarise', '--prompt', 'true']);
  const kdl = readCache(silent.sourceDir, 'sentry-4512345678.kdl');
  assert.match(kdl, /lazy-brief" \{ args "-"/, 'a prompt that writes nothing yields no brief');
});

test('--no-prompt hands the pane a dash instead of a brief', { skip: !HAS_JQ || !HAS_GIT }, () => {
  const r = dryRun(['--no-summarise', '--no-prompt']);
  assert.match(r.out, /prompt off/);
  const kdl = readCache(r.sourceDir, 'sentry-4512345678.kdl');
  assert.match(kdl, /lazy-brief" \{ args "-" "PROJ-4F"/);
  assert.ok(!cacheHas(r.sourceDir, 'briefs/4512345678.md'));
});

test('a bad --prompt-template path exits 2', () => {
  const r = dryRun(['--prompt-template', '/nope/nope.md']);
  assert.equal(r.code, 2);
  assert.ok(r.err.includes('no such prompt template'));
});

// --- profiles ----------------------------------------------------------------

test('a profile hook replaces both stages, and a flag still beats the profile', { skip: !HAS_JQ || !HAS_GIT }, () => {
  const prof = writeFile(
    path.join(tmp('ingest-prof-'), 'p.sh'),
    `HERDR_INGEST_MAX_SPACES=1
ingest_summarise() { printf 'PROFILE SUMMARY\\n'; }
ingest_prompt() { printf 'PROFILE BRIEF %s\\n' "$4" > "$3"; }
`,
  );
  const withProfile = dryRun(['--profile', prof]);
  assert.match(withProfile.out, /summarise hook · prompt hook/);
  assert.match(withProfile.out, /held back by --max-spaces 1/, 'the profile default applies');
  const brief = readCache(withProfile.sourceDir, 'briefs/4512999999.md');
  assert.ok(brief.startsWith('PROFILE BRIEF fix/sentry-4512999999'));

  const overridden = dryRun(['--profile', prof, '--no-summarise', '--max-spaces', '5']);
  assert.match(overridden.out, /summarise off · prompt hook/);
  assert.ok(!overridden.out.includes('held back'), 'the flag overrides the profile default');
});

test('a prompt hook may decline an item, leaving its pane without a brief', { skip: !HAS_JQ || !HAS_GIT }, () => {
  const prof = writeFile(
    path.join(tmp('ingest-prof-'), 'p.sh'),
    `ingest_prompt() {
  case "$(jq -r .badge "$1")" in warning) return 0 ;; esac
  printf 'brief\\n' > "$3"
}
`,
  );
  const r = dryRun(['--profile', prof, '--no-summarise']);
  assert.match(readCache(r.sourceDir, 'sentry-4512999999.kdl'), /lazy-brief" \{ args "-"/);
  assert.match(readCache(r.sourceDir, 'sentry-4512345678.kdl'), /briefs\/4512345678\.md/);
});

test('the shipped example profile loads and drives both stages', { skip: !HAS_JQ || !HAS_GIT }, () => {
  const r = dryRun(['--profile', path.join(REPO, 'profiles', 'example.sh')]);
  assert.equal(r.code, 0);
  assert.match(r.out, /summarise hook · prompt hook/);
  const brief = readCache(r.sourceDir, 'briefs/4512345678.md');
  assert.ok(brief.includes('Farm state:'));
  assert.ok(brief.includes('Do not push to main.'));
});

test('a missing profile exits 2', () => {
  const r = dryRun(['--profile', '/nope/p.sh']);
  assert.equal(r.code, 2);
  assert.ok(r.err.includes('no such profile'));
});

test('a profile can carry the whole run, farm and source included', { skip: !HAS_JQ || !HAS_GIT }, () => {
  const f = farm();
  const items = payload(SENTRY_PAYLOAD);
  const cache = tmp('ingest-cache-');
  const prof = writeFile(
    path.join(tmp('ingest-prof-'), 'p.sh'),
    `HERDR_INGEST_ROOT=${f.root}
HERDR_INGEST_PREFIX=bug
HERDR_INGEST_ITEMS_FILE=${items}
HERDR_INGEST_AUTO=1
HERDR_INGEST_DRY=1
HERDR_INGEST_SUMMARISE_MODE=off
`,
  );
  // Everything but the profile itself comes from the profile.
  const r = run(['--profile', prof], { env: { HERDR_INGEST_CACHE: cache } });
  assert.equal(r.code, 0, r.err);
  assert.match(r.out, /would spawn -> fix\/bug-4512345678/, 'the profile root and prefix took effect');

  // A flag still beats it.
  const flagged = run(['--profile', prof, '--prefix', 'hot'], { env: { HERDR_INGEST_CACHE: cache } });
  assert.match(flagged.out, /would spawn -> fix\/hot-4512345678/);
});

test('HERDR_INGEST_ROOT and HERDR_INGEST_SOURCE work from the environment', { skip: !HAS_JQ || !HAS_GIT }, () => {
  const f = farm();
  const r = run(['--items-json', payload(LINEAR_PAYLOAD), '--auto', '--dry-run'], {
    env: { HERDR_INGEST_CACHE: tmp('ingest-cache-'), HERDR_INGEST_ROOT: f.root, HERDR_INGEST_SOURCE: 'linear' },
  });
  assert.equal(r.code, 0, r.err);
  assert.match(r.out, /^linear · 2 of 2/m);
});

test('a profile picks the source and configures it', { skip: !HAS_JQ || !HAS_GIT }, () => {
  const f = farm();
  const items = payload({ rows: [{ id: 'A1', name: 'first thing' }] });
  const prof = writeFile(
    path.join(tmp('ingest-prof-'), 'p.sh'),
    `HERDR_INGEST_SOURCE=json
HERDR_INGEST_JSON_MAP='[.rows[] | {key: .id, title: .name}]'
HERDR_INGEST_ROOT=${f.root}
HERDR_INGEST_ITEMS_FILE=${items}
HERDR_INGEST_AUTO=1
HERDR_INGEST_DRY=1
`,
  );
  const r = run(['--profile', prof], { env: { HERDR_INGEST_CACHE: tmp('ingest-cache-') } });
  assert.equal(r.code, 0, r.err);
  assert.match(r.out, /^json · 1 of 1 item\(s\) kept/m, 'the profile chose the source');
  assert.match(r.out, /A1\s+item-a1\s+would spawn -> fix\/item-a1-first-thing/, 'and configured it');

  // --source on the command line still wins over the profile.
  const flagged = run(['--profile', prof, '--source', 'sentry', '--items-json', payload(SENTRY_PAYLOAD)], {
    env: { HERDR_INGEST_CACHE: tmp('ingest-cache-') },
  });
  assert.match(flagged.out, /^sentry · 2 of 2/m);
});

test('--pane holds a terminal open but never blocks a pipe', { skip: !HAS_JQ || !HAS_GIT }, () => {
  // Every test here captures stdout, so stdout is a pipe and the hold must be a
  // no-op. A blocking read would hang the suite instead of failing it.
  const ok = dryRun(['--pane', '--no-summarise']);
  assert.equal(ok.code, 0);
  assert.match(ok.out, /would spawn/);
  assert.ok(!ok.out.includes('any key closes'), 'no prompt without a terminal');

  // The hold is armed before anything can exit, so it covers a failure too, and
  // the exit status still reaches the caller.
  const bad = run(['--pane', '--root', '/nope']);
  assert.equal(bad.code, 1);
  assert.ok(bad.err.includes('no such root'));
});

// --- stage 6: emission and the farm -----------------------------------------

test('a dry run writes the cache and needs neither herdr nor zellij', { skip: !HAS_JQ || !HAS_GIT }, () => {
  const stub = stubs([]); // a PATH with jq and git but no herdr and no zellij
  const f = farm();
  const cache = tmp('ingest-cache-');
  const r = run(['--root', f.root, '--items-json', payload(SENTRY_PAYLOAD), '--auto', '--dry-run', '--no-summarise'], {
    env: { PATH: stub.path, HERDR_INGEST_CACHE: cache },
  });
  assert.equal(r.code, 0);
  const dir = path.join(cache, 'sentry');
  for (const rel of [
    'raw.json',
    'items.json',
    'items.rows',
    'items/4512345678.json',
    'briefs/4512345678.md',
    'sentry-4512345678.kdl',
    'sentry-4512345678.boot.sh',
  ]) {
    assert.ok(cacheHas(dir, rel), `dry run did not write ${rel}`);
  }
  assert.equal(stub.calls().length, 0, 'nothing on the stub PATH was called');
  assert.ok(!cacheHas(f.root, 'sentry-4512345678'), 'no worktree was cut');
});

test('the layout puts a focused shell, nvim, and one waiting brief pane in the worktree', { skip: !HAS_JQ || !HAS_GIT }, () => {
  const r = dryRun(['--no-summarise']);
  const kdl = readCache(r.sourceDir, 'sentry-4512345678.kdl');
  assert.ok(kdl.includes(`cwd "${path.join(r.farm.root, 'sentry-4512345678')}"`));
  assert.ok(kdl.includes('pane name="shell" focus=true'));
  assert.ok(kdl.includes('pane name="nvim" command="nvim"'));
  assert.ok(kdl.includes(LAZY), 'the right pane runs lazy-brief');
  assert.ok(!kdl.includes('command="omp"'), 'no pane starts an agent directly');
});

test('the boot script attaches before it creates', { skip: !HAS_JQ || !HAS_GIT }, () => {
  const r = dryRun(['--no-summarise']);
  const boot = readCache(r.sourceDir, 'sentry-4512345678.boot.sh');
  const attach = boot.indexOf('zellij attach');
  const create = boot.indexOf('--new-session-with-layout');
  assert.ok(attach > -1 && create > attach, 'attach is tried first');
  assert.ok(fs.statSync(path.join(r.sourceDir, 'sentry-4512345678.boot.sh')).mode & 0o111);
});

test('a real sweep cuts one worktree per item and runs the boot script in its pane', { skip: !HAS_JQ || !HAS_GIT }, () => {
  const h = herdrStub();
  const f = farm();
  const cache = tmp('ingest-cache-');
  const r = run(['--root', f.root, '--items-json', payload(SENTRY_PAYLOAD), '--auto', '--no-summarise', '--no-focus'], {
    env: { PATH: h.path, HERDR_INGEST_CACHE: cache },
  });
  assert.equal(r.code, 0);
  assert.match(r.out, /space created on fix\/sentry-4512345678/);
  const calls = h.calls();
  assert.equal(calls.filter((c) => c.includes('worktree create')).length, 2, 'one create per item');
  assert.equal(calls.filter((c) => c.includes('pane run')).length, 2, 'one boot per item');
  assert.ok(calls.some((c) => c.includes('pane run wT:p1 exec') && c.includes('.boot.sh')));
  assert.ok(!calls.some((c) => c.includes('workspace focus')), '--no-focus keeps focus put');
  assert.ok(fs.existsSync(path.join(cache, 'sentry', 'spawned', '4512345678')), 'the spawn is recorded');
});

test('a sweep launched by herdr calls the herdr binary HERDR_BIN_PATH names', { skip: !HAS_JQ || !HAS_GIT }, () => {
  const h = herdrStub();
  const decoy = tmp('ingest-decoy-');
  writeExec(path.join(decoy, 'herdr'), '#!/bin/sh\necho "the PATH herdr ran" >&2\nexit 1\n');
  const f = farm();
  const r = run(['--root', f.root, '--items-json', payload([SENTRY_PAYLOAD[0]]), '--auto', '--no-summarise', '--no-focus'], {
    env: { PATH: `${decoy}:${h.path}`, HERDR_BIN_PATH: path.join(h.dir, 'herdr'), HERDR_INGEST_CACHE: tmp('ingest-cache-') },
  });
  assert.equal(r.code, 0, r.all);
  assert.ok(!r.all.includes('the PATH herdr ran'));
  assert.equal(h.calls().filter((c) => c.includes('worktree create')).length, 1);
});

test('a space already sitting in the worktree is reused, never duplicated', { skip: !HAS_JQ || !HAS_GIT }, () => {
  const f = farm();
  const cwd = path.join(f.root, 'sentry-4512345678');
  const h = herdrStub({ panes: [{ cwd, workspace_id: 'w9' }] });
  const cache = tmp('ingest-cache-');
  const r = run(['--root', f.root, '--items-json', payload([SENTRY_PAYLOAD[0]]), '--auto', '--no-summarise', '--no-focus'], {
    env: { PATH: h.path, HERDR_INGEST_CACHE: cache },
  });
  assert.equal(r.code, 0);
  assert.match(r.out, /w9\s+space exists, reused/);
  assert.equal(h.calls().filter((c) => c.includes('worktree')).length, 0, 'no worktree call at all');
});

test('an existing checkout is opened, not re-cut, and keeps its own branch', { skip: !HAS_JQ || !HAS_GIT }, () => {
  const f = farm();
  const wt = mkdirp(path.join(f.root, 'sentry-4512345678'));
  spawnSync('git', ['-C', f.main, 'worktree', 'add', '-q', '-f', wt, '-b', 'someone/else'], { encoding: 'utf8' });
  const h = herdrStub();
  const cache = tmp('ingest-cache-');
  const r = run(['--root', f.root, '--items-json', payload([SENTRY_PAYLOAD[0]]), '--auto', '--no-summarise', '--no-focus', '--respawn'], {
    env: { PATH: h.path, HERDR_INGEST_CACHE: cache },
  });
  assert.equal(r.code, 0);
  assert.ok(h.calls().some((c) => c.includes('worktree open')), 'open, not create');
  assert.ok(!h.calls().some((c) => c.includes('worktree create')));
  assert.match(r.out, /space created on someone\/else/, 'the existing branch is kept');
});

test('an item already spawned here, or already branched, is skipped unless --respawn', { skip: !HAS_JQ || !HAS_GIT }, () => {
  const f = farm({ branches: ['fix/sentry-4512999999-upstream-took-too-long'] });
  const cache = tmp('ingest-cache-');
  writeFile(path.join(cache, 'sentry', 'spawned', '4512345678'), '');
  const args = ['--root', f.root, '--items-json', payload(SENTRY_PAYLOAD), '--auto', '--dry-run', '--no-summarise'];

  const skipped = run(args, { env: { HERDR_INGEST_CACHE: cache } });
  assert.match(skipped.out, /PROJ-4F\s+skipped, already spawned here/);
  assert.match(skipped.out, /PROJ-9Z\s+skipped, branch exists/);
  assert.ok(!skipped.out.includes('would spawn'));

  const forced = run([...args, '--respawn'], { env: { HERDR_INGEST_CACHE: cache } });
  assert.equal((forced.out.match(/would spawn/g) ?? []).length, 2);
});

test('a branch the tracker itself named counts as work in flight', { skip: !HAS_JQ || !HAS_GIT }, () => {
  const f = farm({ branches: ['dev/eng-412-quote-endpoint-500s'] });
  const cache = tmp('ingest-cache-');
  const r = run(
    ['--source', 'linear', '--root', f.root, '--items-json', payload(LINEAR_PAYLOAD), '--auto', '--dry-run'],
    { env: { HERDR_INGEST_CACHE: cache } },
  );
  assert.match(r.out, /ENG-412\s+skipped, branch exists/);
  assert.match(r.out, /ENG-500\s+linear-eng-500\s+would spawn/);
});

test('--worktree-template and --branch-template rename what a sweep cuts', { skip: !HAS_JQ || !HAS_GIT }, () => {
  const r = dryRun([
    '--no-summarise',
    '--prefix', 'bug',
    '--worktree-template', 'wt/{key}',
    '--branch-template', '{prefix}/{ref}-{slug}',
  ]);
  assert.match(r.out, /wt\/4512345678\s+would spawn -> bug\/PROJ-4F-cannot-read-quote-of-undefined/);
});

test('a missing root, a missing main, and a non-checkout main each fail loudly', () => {
  const f = farm();
  assert.equal(run(['--root', '/nope']).code, 1);
  assert.ok(run(['--root', '/nope']).err.includes('no such root'));
  assert.ok(run(['--root', f.root, '--main', '/nope']).err.includes('no such main checkout'));
  const bare = tmp('ingest-bare-');
  mkdirp(path.join(bare, 'main'));
  assert.ok(run(['--root', bare]).err.includes('not a checkout'));
});

test('a live fetch without credentials reports what to set, and never spawns', { skip: !HAS_JQ || !HAS_GIT }, () => {
  const f = farm();
  const r = run(['--root', f.root, '--auto', '--dry-run'], {
    env: { SENTRY_AUTH_TOKEN: '', HERDR_INGEST_SENTRY_TOKEN: '' },
  });
  assert.equal(r.code, 1);
  assert.ok(r.err.includes('no Sentry token found'));
  assert.ok(r.err.includes('--items-json'), 'the error names the offline path');
});

test('linear and github refuse a live fetch with no target', { skip: !HAS_JQ || !HAS_GIT }, () => {
  const f = farm();
  const noCurl = stubs([]); // jq and git reachable, but curl is never wanted here
  const lin = run(['--source', 'linear', '--root', f.root, '--auto', '--dry-run'], {
    env: { LINEAR_API_KEY: 'lin_api_x', PATH: noCurl.path },
  });
  assert.equal(lin.code, 1);
  assert.ok(lin.err.includes('--team'), 'the error names --team');
  assert.ok(lin.err.includes('--project'), 'the error names --project');
  assert.ok(!lin.out.includes('would spawn'), 'nothing is spawned without a target');

  const gh = run(['--source', 'github', '--root', f.root, '--auto', '--dry-run'], {
    env: { GITHUB_TOKEN: 'x', PATH: MIN_PATH + ':' + TOOL_PATH },
  });
  assert.equal(gh.code, 1);
  assert.ok(gh.err.includes('--repo'));
});

test('--render prints one item for the picker preview', { skip: !HAS_JQ || !HAS_GIT }, () => {
  const r = dryRun(['--no-summarise']);
  const rendered = run(['--render', path.join(r.sourceDir, 'items'), '4512345678']);
  assert.equal(rendered.code, 0);
  assert.ok(rendered.out.includes('PROJ-4F'));
  assert.ok(rendered.out.includes('error'));
  assert.ok(rendered.out.includes('https://sentry.io/x/1'));
});

test('interactive mode without fzf says so instead of guessing', { skip: !HAS_JQ || !HAS_GIT }, () => {
  const h = herdrStub(); // herdr and zellij, but no fzf
  const f = farm();
  const r = run(['--root', f.root, '--items-json', payload(SENTRY_PAYLOAD), '--no-summarise'], {
    env: { PATH: h.path, HERDR_INGEST_CACHE: tmp('ingest-cache-') },
  });
  assert.notEqual(r.code, 0);
  assert.ok(r.err.includes('fzf not found'));
  assert.ok(!h.calls().some((c) => c.includes('worktree')), 'nothing was spawned');
});

// --- the y gate --------------------------------------------------------------

test('the pane prints the brief and starts nothing without a y', { skip: !HAS_JQ }, () => {
  const s = stubs(['omp']);
  const brief = writeFile(path.join(tmp('ingest-brief-'), 'b.md'), '# BRIEF BODY\n');
  const r = runLazy([brief, 'PROJ-4F', 'a title'], { env: { PATH: s.path }, input: 'n\n' });
  assert.ok(r.out.includes('BRIEF BODY'), 'the brief is shown');
  assert.ok(r.out.includes('PROJ-4F'));
  assert.ok(r.out.includes('start omp on this brief?'));
  assert.equal(s.calls().length, 0, 'declining starts no agent');
  assert.ok(r.out.includes('start it later with'));
});

test('EOF on the prompt declines instead of crashing', { skip: !HAS_JQ }, () => {
  const s = stubs(['omp']);
  const brief = writeFile(path.join(tmp('ingest-brief-'), 'b.md'), '# BRIEF\n');
  const r = runLazy([brief, 'PROJ-4F'], { env: { PATH: s.path }, input: '' });
  assert.equal(s.calls().length, 0);
  assert.ok(!r.err.includes('unbound variable'));
});

test('a y runs the agent on the brief', { skip: !HAS_JQ }, () => {
  const s = stubs(['omp']);
  const brief = writeFile(path.join(tmp('ingest-brief-'), 'b.md'), '# BRIEF\n');
  const r = runLazy([brief, 'PROJ-4F'], { env: { PATH: s.path }, input: 'y\n' });
  assert.equal(r.code, 0);
  assert.deepEqual(s.calls(), [`omp @${brief}`]);
});

test('--agent replaces the agent the pane offers, and the gate stays', { skip: !HAS_JQ || !HAS_GIT }, () => {
  const s = stubs(['claude']);
  const brief = writeFile(path.join(tmp('ingest-brief-'), 'b.md'), '# BRIEF\n');
  const declined = runLazy([brief, 'X'], { env: { PATH: s.path, HERDR_INGEST_AGENT: 'claude' }, input: 'n\n' });
  assert.ok(declined.out.includes('start claude on this brief?'));
  assert.equal(s.calls().length, 0);

  const accepted = runLazy([brief, 'X'], { env: { PATH: s.path, HERDR_INGEST_AGENT: 'claude' }, input: 'y\n' });
  assert.deepEqual(s.calls(), [`claude @${brief}`]);
  assert.equal(accepted.code, 0);

  // The layout carries the agent through the environment the engine exports.
  const r = dryRun(['--no-summarise', '--agent', 'claude']);
  assert.equal(r.code, 0);
});

test('a dash offers a bare session in the worktree, still behind the gate', { skip: !HAS_JQ }, () => {
  const s = stubs(['omp']);
  const declined = runLazy(['-', 'PROJ-4F', 'a title'], { env: { PATH: s.path }, input: 'n\n' });
  assert.ok(declined.out.includes('no brief'));
  assert.ok(declined.out.includes('start omp in this worktree?'));
  assert.equal(s.calls().length, 0);

  const accepted = runLazy(['-', 'PROJ-4F'], { env: { PATH: s.path }, input: 'y\n' });
  assert.deepEqual(s.calls(), ['omp ']);
  assert.equal(accepted.code, 0);
});

test('a brief path that does not exist drops to a shell and starts nothing', { skip: !HAS_JQ }, () => {
  const s = stubs(['omp']);
  const r = runLazy(['/nope/b.md', 'PROJ-4F'], { env: { PATH: s.path }, input: 'y\n' });
  assert.ok(r.out.includes('no brief at /nope/b.md'));
  assert.equal(s.calls().length, 0);
});

// --- documentation stays true ------------------------------------------------

test('the skill and the manifest agree with the code', () => {
  const skill = fs.readFileSync(SKILL, 'utf8');
  const toml = fs.readFileSync(path.join(REPO, 'herdr-plugin.toml'), 'utf8');
  const readme = fs.readFileSync(path.join(REPO, 'README.md'), 'utf8');

  assert.match(skill, /^---\nname: herdr-ingest\n/, 'the skill has front matter');
  assert.ok(skill.includes('description:'), 'the skill has a description');
  assert.equal(toml.includes(`version = "${PKG.version}"`), true, 'the manifest version matches');

  // Every flag the engine parses is documented in the usage text, the skill and
  // the README, so no flag can drift out of the docs unnoticed.
  const help = run(['--help']).out;
  for (const flag of [
    '--source', '--profile', '--root', '--main', '--base', '--prefix',
    '--worktree-template', '--branch-template', '--items-json',
    '--badge', '--badge-order', '--state', '--label', '--match',
    '--updated-last', '--created-last',
    '--sort', '--limit', '--summarise', '--no-summarise', '--prompt',
    '--prompt-template', '--no-prompt', '--agent', '--auto', '--max-spaces',
    '--watch', '--interval', '--respawn', '--no-focus', '--dry-run', '--pane',
  ]) {
    assert.ok(help.includes(flag), `--help omits ${flag}`);
    assert.ok(skill.includes(flag), `the skill omits ${flag}`);
    assert.ok(readme.includes(flag), `the README omits ${flag}`);
  }
});

test('the engine keeps no source-specific vocabulary in its own names', () => {
  const lib = fs.readFileSync(LIB, 'utf8');
  const fns = [...lib.matchAll(/^([a-z_]+)\(\) \{/gm)].map((m) => m[1]);
  const strays = fns.filter((f) => !f.startsWith('herdr_ingest_'));
  assert.deepEqual(strays, [], 'every engine function shares one prefix');
  const codeOnly = lib
    .split('\n')
    .filter((l) => !l.trimStart().startsWith('#'))
    .join('\n');
  for (const word of ['sentry_', 'linear_', 'github_', 'shortId', 'permalink', 'identifier']) {
    assert.ok(!codeOnly.includes(word), `the engine leaks the source concept ${word}`);
  }
});
