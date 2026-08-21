# Contributing to herdr-ingest

Thanks for taking a look. This is a small bash product with one strong opinion,
and the goal is to keep both properties.

By participating you agree to the [Code of Conduct](CODE_OF_CONDUCT.md).

## The two rules that shape every review

**The engine never knows what a tracker is.** `lib/herdr-ingest.sh` sees only the
canonical item. Every tracker concept lives in `lib/sources/<id>.sh` behind the
adapter contract. An engine function that names a tracker, or reads a
tracker-specific field such as `shortId`, `permalink` or `identifier`, is a bug,
and the test suite asserts it.

**No pane ever starts an agent by itself.** The right-hand pane runs
`lazy-brief`, which waits for an explicit `y`. Anything else, including EOF,
drops to a login shell. A fifteen-space sweep must cost nothing until a human
chooses. This is the product's cost-control contract, and a pull request that
bypasses it will be declined however convenient it is.

## Before you write code

Open an issue first for anything beyond an obvious fix. The answer is sometimes
"that is a `--summarise` command" or "that is four lines in a profile", and both
of those are better than a patch to the engine.

Good first contributions:

- A new adapter under `lib/sources/`. This is the most useful thing you can add
  and it touches no shared code.
- A tracker payload the `json` source cannot express, which is a real gap in the
  canonical item.
- A filter or sort that belongs on the canonical rows rather than in a source.
- Platform breakage. Development happens on macOS, so Linux gets less
  real-world use here than it deserves.

## Development setup

There is no build step and no dependency install. You need `bash`, `git`, `jq`
and `curl`. `fzf` is needed only for the picker, and `herdr` plus `zellij` only
to create real spaces. `node` 18+ runs the tests.

```bash
git clone git@github.com:H3xept/herdr-ingest.git
cd herdr-ingest
bin/herdr-ingest --help
```

Run it as a herdr plugin from your checkout:

```bash
herdr plugin link "$PWD"
```

## Always dry-run first, and always against a fixture

A dry run writes items, summaries, briefs, KDL layouts and boot scripts into the
cache, creates no spaces, and needs neither `herdr` nor `zellij`. Point it at a
throwaway farm and an isolated cache so it cannot touch your real ones:

```bash
mkdir -p /tmp/farm/main && git -C /tmp/farm/main init -q &&
  git -C /tmp/farm/main commit -q --allow-empty -m init

HERDR_INGEST_CACHE=/tmp/ingest-cache bin/herdr-ingest \
  --source json --json-map '.' --items-json examples/items.json \
  --root /tmp/farm --auto --dry-run
```

With `--items-json` it needs no token either, so every source can be exercised
offline. That is also how the whole test suite runs, and it is why a change to
selection or spawning can be verified without an account anywhere.

## Checks

```bash
npm test
```

Sixty-eight `node:test` cases against a throwaway fixture: a temp `$HOME`, a
temp farm with its own git checkout, a temp cache and a scrubbed `$PATH`.
Nothing requires `herdr`, `zellij`, `fzf`, an agent or a token, and nothing
reaches a tracker. **Keep it that way.** A test that needs a credential is a
test nobody can run, including CI.

CI also parses and lints every bash file in the repo, `docs/demo/` included:

```bash
for f in bin/herdr-ingest lazy-brief lib/herdr-ingest.sh lib/sources/*.sh \
         profiles/*.sh examples/sources/*.sh examples/summarise-git-blame \
         docs/demo/*.sh docs/demo/bin/*; do
  bash -n "$f" || exit 1
done
shellcheck -S warning bin/herdr-ingest lazy-brief lib/herdr-ingest.sh \
  lib/sources/*.sh profiles/*.sh examples/sources/*.sh \
  examples/summarise-git-blame docs/demo/*.sh docs/demo/bin/* docs/demo/bashrc
```

Run `npm test` after any change to the engine, an adapter, `lazy-brief`, a
profile, an example, `herdr-plugin.toml`, the agent skill, or version metadata.

## The GIFs in the README

`docs/*.gif` are build artifacts. Their source is the tapes in `docs/demo/`,
which are [vhs](https://github.com/charmbracelet/vhs) scripts, so a recording is
reproducible rather than a one-off screen capture. Re-record with:

```bash
brew install vhs gifsicle       # vhs brings ttyd and ffmpeg
bash docs/demo/record.sh        # all three, or `record.sh gate` for one
```

`docs/demo/setup.sh` builds a throwaway farm under `/tmp/herdr-ingest-demo` from
a fictional storefront, and `docs/demo/queue.json` is a fictional tracker
payload. **A recording never touches a real tracker and never needs a token.**
Keep it that way: a GIF is the most public artifact in the repo, and a leaked
ticket in one is not recoverable.

Two constraints worth knowing before you edit a tape. Every `Set` has to precede
the first keystroke, which is why the shared tapes are split into
`style.tape` and `boot.tape` and a tape that resizes sources them in that order.
And `Wait` only matches whole lines, so it cannot see the gate's `[y/N]` prompt,
which blocks mid-line on `read`; `gate.tape` uses `Sleep` throughout for that
reason.

## Writing an adapter

Three required verbs and two variables:

```bash
# shellcheck shell=bash
HERDR_INGEST_SOURCE_ID=myjira
HERDR_INGEST_SOURCE_PREFIX=jira

ingest_source_describe()  { printf 'id\tmyjira\n'; }
ingest_source_fetch()     { curl -sS "$MY_API/issues"; }
ingest_source_normalize() { jq -c '[.issues[] | {key: .key, title: .summary}]'; }
```

Optional: `ingest_source_option` to claim flags, `ingest_source_usage` to
document them, `ingest_source_check` to validate credentials before a fetch,
`ingest_source_summarise` to supply the source's own stage 4. The engine refuses
a file missing a required verb and names the verb.

`examples/sources/todo.sh` is a complete working adapter that needs no token, so
it is the cheapest thing to read and to copy.

Two things a new adapter must get right, because both have already caused bugs:

- **Build JSON with `jq`, never by concatenating strings.** A title containing a
  quote or a backslash must not be able to corrupt the payload.
- **Make `key` stable across sweeps.** The key names the worktree and the cache
  files, so a key that changes when the tracker is edited orphans a worktree
  somebody is working in.

Ship a test with it. Add a payload fixture and assert the normalisation, the way
the existing per-source cases do; `--items-json` means that needs no network.

## Pull requests

- One concern per pull request.
- Say what you ran and what you saw. "Dry-ran 12 Linear items into a fixture
  farm, briefs carry the discussion, `--sort badge` orders urgent first" is the
  useful kind of description.
- New flag, new default, or new environment variable? Update `herdr_ingest_usage`,
  the README and `skills/herdr-ingest/SKILL.md` together. A test asserts that
  every flag the engine parses appears in all three, so drift fails CI.
- Keep `package.json`, `herdr-plugin.toml` and `herdr_ingest_version` on one
  version. A test asserts that too.
- Add to `CHANGELOG.md` under an `Unreleased` heading.

## Code conventions

- `bash`, `git`, `jq` and `curl`. A new runtime dependency needs a real
  argument, because "no install step" is a headline feature. `node` is for
  `npm test` and `npx` distribution only, never at runtime.
- Comments explain *why*. The *what* is readable from the code.
- Seed a new knob with `herdr_ingest_seed` rather than assigning it, or the
  profile layer silently stops working for that knob. Four layers decide every
  value — defaults, profile, source, flags — and each only fills what the layer
  before it left empty.
- A flag always beats a profile. The status line names the mode that won, and
  the tests read that line.
- One term per concept. The engine's vocabulary is `item`, `source`, `summary`,
  `brief`, `space`, `farm`, `sweep`. Never `issue`, which belongs to a source.
- Failure is data, not an exception. A failing stage-4 command costs the item
  its summary, never its space. One broken item must never break a sweep.
- Installation is idempotent. Spaces are matched by working directory rather
  than label, an existing checkout is opened rather than re-cut, and the boot
  script tries `zellij attach` before it creates from a layout.

## Releasing

Maintainer only. Bump the version in `package.json`, `herdr-plugin.toml` and
`herdr_ingest_version`, update `CHANGELOG.md`, tag the commit, and push the tag.
