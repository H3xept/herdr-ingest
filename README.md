<div align="center">

# herdr-ingest

**One work item becomes one worktree, one Herdr space, and one agent brief that waits for `y`.**

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Herdr](https://img.shields.io/badge/herdr-%E2%89%A50.8.0-6e5494.svg)](https://herdr.dev)
[![Dependencies](https://img.shields.io/badge/runtime%20dependencies-none-brightgreen.svg)](#install)

</div>

Point it at a tracker. It cuts one git worktree per item, opens one
[herdr](https://herdr.dev) space on each, writes each one a brief, and stops.
Nothing starts an agent until you press `y`.

```bash
herdr-ingest --source linear --team ENG --root ~/farm --auto --dry-run   # see it
herdr-ingest --source linear --team ENG --root ~/farm --auto             # do it
```

<div align="center">
  <img src="docs/sweep.gif" alt="A queue of six items becomes six ready worktrees, then the same sweep narrowed by label" width="100%">
</div>

Fifteen items become fifteen ready workspaces: each on its own branch, each with
the item's detail already written down, each one keystroke away from an agent
that has the context. The keystroke is the product. A sweep is free until you
choose which items are worth spending on.

The engine does not know what a tracker is. Sentry, Linear and GitHub are
adapters over one canonical item; a `jq` expression adds a fourth without any
code, and one bash file with three functions adds a first-class one.

`bin/herdr-ingest` and the adapter it loads are just this repo's bash. There is
no build step, so a clone is a working install; put the checkout's `bin` on your
`PATH` for a bare `herdr-ingest`.

## What it does

```
1 fetch      the source pulls a raw payload
2 normalise  the payload becomes canonical items
3 select     filter, sort, cap, then --auto or an fzf pick
4 summarise  replaceable
5 prompt     replaceable
6 spawn      worktree + herdr space + a pane behind the `y` gate
```

Stages 1, 2, 3 and 6 are the engine. Stage 4 and stage 5 are yours.

Each selected item gets a sibling worktree in the farm, cut from the farm's main
checkout on its own branch, and a herdr space holding one zellij session split
vertically: an interactive shell and `nvim .` on the left, one brief pane on the
right. The brief pane prints the item and waits. **No pane ever starts an agent
by itself.**

<div align="center">
  <img src="docs/gate.gif" alt="The brief pane shows the item, then waits: y starts the agent on the brief, anything else drops to a shell" width="100%">
</div>

Both halves of that are the point. `y` is the only thing that spends an agent
turn; anything else, including EOF, leaves you a shell in a worktree that is
already on the right branch with the brief still on disk.

## Install

As a herdr plugin, from GitHub:

```bash
herdr plugin install H3xept/herdr-ingest
```

Or from a checkout:

```bash
./bin/herdr-ingest --help            # no install, run from this checkout
export PATH="$PWD/bin:$PATH"        # once, to get a bare `herdr-ingest`
herdr plugin link /path/to/this/repo # or link the checkout as a herdr plugin
```

The plugin runs as your user, with your environment and the full herdr CLI.
`herdr plugin install` shows the manifest and every command it runs before it
installs; read them, and pin a revision with `--ref <tag-or-sha>` if you want
one. See herdr's
[trust and security guidance](https://herdr.dev/docs/plugins/#trust-and-security)
and [SECURITY.md](SECURITY.md).

Needs `bash`, `git`, `jq` and `curl`. `fzf` is needed only for the interactive
picker. `herdr` and `zellij` are needed only to create real spaces — a dry run
needs neither.

Install the agent skill from the checkout:

```bash
npx skills add ./skills/herdr-ingest
```

### Try it with no credentials

`examples/items.json` is a payload of canonical items, so the whole pipeline
runs with no token, no network and no tracker account:

```bash
mkdir -p /tmp/farm/main && git -C /tmp/farm/main init -q &&
  git -C /tmp/farm/main commit -q --allow-empty -m init

bin/herdr-ingest --source json --json-map '.' --items-json examples/items.json \
  --root /tmp/farm --auto --dry-run
```

That writes items, summaries, briefs, KDL layouts and boot scripts under the
cache and creates nothing. Read a brief, then drop `--dry-run` when you want the
spaces.

## Sources

`herdr-ingest sources` lists them. `--source` takes an id or a file path.

|id|prefix|ingests|needs|
|---|---|---|---|
|`sentry`|`sentry`|issues of one project active inside a window|`SENTRY_AUTH_TOKEN`, `--org`, `--project`|
|`linear`|`linear`|issues of one project or team, with description and discussion|`LINEAR_API_KEY`, `--team` or `--project`|
|`github`|`gh`|issues and pull requests of one repository|`GITHUB_TOKEN`, `--repo`|
|`json`|`item`|any command or file that prints JSON|`--json-cmd`, or `--items-json`|

Once `--source` is set, that source's own flags append to the help:

```bash
herdr-ingest --source github --help
```

Sentry adds `--org`, `--project`, `--api-base`, `--query`, `--active-last`,
`--fetch-sort` and `--fetch-limit`. Linear adds `--team`, `--project`, `--api-base`,
`--state-types` and `--fetch-limit`. GitHub adds `--repo`, `--api-base`,
`--gh-state`, `--gh-labels`, `--gh-assignee`, `--fetch-limit` and `--comments`.

### Any other tracker

The `json` source takes anything that prints JSON and a jq expression that maps
it to items. A Jira export, a psql query, a saved payload, a Python script:

```bash
herdr-ingest --source json \
  --json-cmd 'jira-export --project ENG' \
  --json-map '[.issues[] | {key: .key, title: .fields.summary, url: .self,
                            badge: (.fields.priority.name | ascii_downcase),
                            state: .fields.status.name,
                            updated: .fields.updated,
                            body: .fields.description}]' \
  --prefix jira --root ~/farm --auto --dry-run
```

### The canonical item

Every source normalises to one object. `key` is the only required field:

```
key ref title subtitle url branch badge state created updated
labels[] fields[{name,value}] body raw
```

|field|meaning|
|---|---|
|`key`|stable id; names the worktree and the cache files|
|`ref`|what a human calls it (`PROJ-4F`, `ENG-412`, `#412`)|
|`title`|one line|
|`subtitle`|second line: a culprit, a project, a milestone|
|`url`|link back to the tracker|
|`branch`|branch the tracker itself suggests, if any|
|`badge`|severity or kind; `--badge` and `--sort badge` read it|
|`state`|tracker state; `--state` reads it|
|`created`, `updated`|ISO timestamps|
|`labels[]`|strings; `--label` reads them|
|`fields[]`|the table at the top of the brief|
|`body`|markdown detail|
|`raw`|the untouched source object, for a hook that needs a field the item dropped|

Anything you leave out is filled in. The smallest useful mapping is a key and a
title.

### Writing an adapter

A source is a bash file defining three functions and two variables:

```bash
HERDR_INGEST_SOURCE_ID=myjira
HERDR_INGEST_SOURCE_PREFIX=jira

ingest_source_describe()  { printf 'myjira\tissues of one board\n'; }
ingest_source_fetch()     { curl -sS "$MY_API/issues"; }
ingest_source_normalize() { jq -c '[.issues[] | {key: .key, title: .summary}]'; }
```

Point `--source` at it. Four optional hooks: `ingest_source_option` to claim
flags, `ingest_source_usage` to document them, `ingest_source_check` to validate
credentials before a fetch, `ingest_source_summarise` to supply the source's own
stage 4. A file missing a required verb is refused by name, not silently
ignored.

`examples/sources/todo.sh` is a complete one you can run right now. It scans a
checkout for `TODO:` and `FIXME:` comments and turns each into an item, so it
needs no token and no network:

```bash
# scans the farm's main checkout by default; --todo-path PATH points it elsewhere
bin/herdr-ingest --source examples/sources/todo.sh \
  --root ~/farm --auto --dry-run --sort badge
```

<div align="center">
  <img src="docs/adapter.gif" alt="Five functions in one bash file, then the same engine sweeping TODO comments into worktrees" width="100%">
</div>

It matches the literal text, so pointing it at this repo finds this paragraph
rather than any real work. Point it at code.

Two things an adapter must get right, because both have bitten this codebase.
Build JSON with `jq`, never by concatenating strings, or the first title
containing a quote corrupts the payload. And keep `key` stable across sweeps:
it names the worktree and the cache files, so a key that moves when the tracker
is edited orphans a worktree somebody is working in.

## Customising the summary and the brief

These are the two steps worth owning, because they decide what the agent reads.

### Stage 4, summarise

Precedence: `--no-summarise` > `--summarise CMD` > a profile hook > the source's
own > off. The status line says which won.

```bash
# who last touched the code this item blames
herdr-ingest --summarise 'examples/summarise-git-blame "$1" "$2"'
```

`$1` is the item JSON, `$2` the worktree, stdin the item. Stdout becomes the
brief's `## Context` section. A summariser that fails costs the item its
summary, never its space.

### Stage 5, prompt

Precedence: `--no-prompt` > `--prompt CMD` > `--prompt-template FILE` > a profile
hook > the built-in brief.

```bash
herdr-ingest --prompt-template examples/prompt-template.md
```

Slots: `{{key}} {{ref}} {{title}} {{subtitle}} {{url}} {{badge}} {{state}}
{{labels}} {{body}} {{fields}} {{summary}} {{branch}} {{worktree}} {{main}}
{{source}} {{repo_skill}} {{item_json}}`. Substitution is a single
left-to-right pass, so a description containing `{{ref}}` survives intact.

For full control, `--prompt CMD` gets `$1` item JSON, `$2` summary, `$3` the
brief path to write, `$4` branch, `$5` worktree. Writing nothing is a valid
answer: the pane then offers a bare agent session in the worktree.

`--no-prompt` skips the step entirely.

### Profiles

A profile is a bash file sourced before the source is loaded and before the
flags are parsed. It carries your defaults and, optionally, both hooks:

```bash
# ~/.config/herdr-ingest/eng.sh
HERDR_INGEST_SOURCE=linear
HERDR_INGEST_LINEAR_PROJECT=Platform
HERDR_INGEST_ROOT=$HOME/farm
HERDR_INGEST_MAX_SPACES=3
HERDR_INGEST_SORT=badge

ingest_summarise() { git -C "$2" log -3 --oneline 2>/dev/null; }
ingest_prompt()    { printf '# %s\n\nFix it in %s.\n' "$(jq -r .ref "$1")" "$5" > "$3"; }
```

```bash
herdr-ingest --profile ~/.config/herdr-ingest/eng.sh --auto
```

Four layers decide every knob, and each one only fills what the layer before it
left empty:

1. the engine's defaults
2. the profile — so it can choose the source itself
3. the source — its own id, prefix, badge ranking and option defaults
4. the flags

So a profile can set anything `--help` names: `HERDR_INGEST_ROOT`,
`HERDR_INGEST_MAIN`, `HERDR_INGEST_BASE`, `HERDR_INGEST_PREFIX`,
`HERDR_INGEST_SOURCE`, `HERDR_INGEST_AGENT`, `HERDR_INGEST_SORT`,
`HERDR_INGEST_LIMIT`, `HERDR_INGEST_MAX_SPACES`, `HERDR_INGEST_AUTO`,
`HERDR_INGEST_DRY`, and every source option as
`HERDR_INGEST_<SOURCE>_<FLAG>` — `HERDR_INGEST_SENTRY_ACTIVE_LAST`,
`HERDR_INGEST_LINEAR_STATE_TYPES`, `HERDR_INGEST_GITHUB_STATE`,
`HERDR_INGEST_JSON_MAP`. A flag always wins over a profile.
`HERDR_INGEST_PROFILE` sets the default profile. See `profiles/example.sh`.

## Selecting what to sweep

|flag|effect|
|---|---|
|`--badge CSV`|keep these badges: `error,fatal`, `urgent,high`, `issue`|
|`--state CSV`|keep these tracker states|
|`--label CSV`|keep items carrying any of these labels|
|`--match REGEX`|case-insensitive match over title and subtitle|
|`--updated-last WINDOW`|updated within `5m`, `2h`, `2d`, `1w`|
|`--created-last WINDOW`|created within that window|
|`--sort KEY`|`updated`, `created`, `age`, `badge`, `title`, `key`, `none`|
|`--badge-order CSV`|rank badges for `--sort badge`, most severe first; a source ships its own, a generic payload needs this|
|`--limit N`|items to keep|
|`--items-json FILE`|read the payload from a file instead of fetching|

Filters run over the canonical rows, so `--items-json` and a live fetch behave
identically. That is why the whole test suite runs offline.

## Spawning

|flag|effect|
|---|---|
|`--root PATH`|the worktree farm|
|`--main PATH`|checkout new worktrees are cut from (default `<root>/main`)|
|`--base REF`|base for a new branch (default `origin/main`, else `HEAD`)|
|`--prefix STR`|worktree and branch namespace|
|`--worktree-template TPL`|default `{prefix}-{key}`|
|`--branch-template TPL`|default `fix/{prefix}-{key}-{slug}`|
|`--agent CMD`|agent the pane offers (default `omp`)|
|`--auto`|no picker|
|`--max-spaces N`|spaces one auto sweep may create|
|`--watch`, `--interval SECONDS`|keep sweeping|
|`--respawn`|spawn again for items already spawned or already branched|
|`--no-focus`|create the spaces, leave focus alone|
|`--dry-run`|write everything, create nothing|
|`--pane`|hold the terminal open at the end, for a herdr popup|

Both templates take `{prefix} {key} {ref} {slug}`.

Re-running is safe. An item is skipped when this cache recorded a spawn for it,
or when a branch for it already exists in the farm — somebody is on it.
`--max-spaces` is a rate limit, not a filter: the rest stay in the source and the
next sweep picks them up. A space already sitting in the item's worktree is
reused, matched by working directory rather than label, so a renamed space is
never duplicated. An existing checkout is opened rather than re-cut and keeps
its own branch. The boot script tries `zellij attach` before creating from the
layout, so a live session is never rebuilt underneath you.

## The `y` gate

The right-hand pane runs `lazy-brief`. It prints the brief, then waits:

```
start omp on this brief? [y/N]
```

Anything but `y`, including EOF, drops to a login shell and prints the command
to start it later. No layout starts an agent directly, so a fifteen-space sweep
costs nothing until you choose. This is the cost-control contract for the
product; do not bypass it.

## As a herdr plugin

`herdr-plugin.toml` declares one popup pane and three actions:

```bash
herdr plugin install H3xept/herdr-ingest   # or: herdr plugin link /path/to/this/repo
herdr plugin pane open --plugin h3xept.herdr-ingest --entrypoint pick
herdr plugin action invoke h3xept.herdr-ingest.sweep
```

|entrypoint|what|
|---|---|
|pane `pick`|the fzf picker in a popup with `--pane`, so the tiled layout is untouched and the popup stays readable|
|action `sweep`|`--auto --max-spaces 3`|
|action `dry-run`|write briefs and layouts, create nothing|
|action `sources`|list the adapters|

Bind one to a key:

```toml
[[keys.command]]
key = "prefix+i"
type = "plugin_action"
command = "h3xept.herdr-ingest.sweep"
description = "sweep items into spaces"
```

A plugin entrypoint inherits no shell, so export `HERDR_INGEST_PROFILE` from your
login profile: that one variable tells every entrypoint your source, your farm
and your two stages.

## Where things live

|path|what|
|---|---|
|`lib/herdr-ingest.sh`|the engine; the single source of behavior|
|`lib/sources/sentry.sh`, `linear.sh`, `github.sh`, `json.sh`|the adapters|
|`bin/herdr-ingest`|CLI entry point|
|`lazy-brief`|the `y` gate in front of the agent|
|`profiles/example.sh`|a profile replacing both replaceable stages|
|`examples/items.json`|canonical items, for a run that needs no credentials|
|`examples/sources/todo.sh`|a complete adapter that needs no token|
|`examples/prompt-template.md`|a template using every slot|
|`examples/summarise-git-blame`|a working stage-4 summariser|
|`herdr-plugin.toml`|the plugin manifest|
|`skills/herdr-ingest/SKILL.md`|the agent skill|
|`tests/herdr-ingest.test.mjs`|the suite, fully offline|

The cache defaults to `~/.cache/herdr-ingest-<root>`, named after the farm so
two farms never share one, and overridden wholesale by `HERDR_INGEST_CACHE`.
Per source it holds `raw.json`, `items.json`, `items.rows`, one JSON file per
item under `items/`, `summaries/`, `briefs/`, a `spawned/` marker per item, and
one KDL layout plus one boot script per space.

`HERDR_INGEST_LAZY` overrides the pane binary, and `HERDR_INGEST_REPO_SKILL`
overrides the repository workflow the built-in brief points the agent at, which
is otherwise found by looking for `.claude/skills/<source>-triage-fix/SKILL.md`
then `AGENTS.md` in the main checkout. Every other variable is a default for the
flag of the same name — see the `environment` section of `--help`, and
`HERDR_INGEST_<SOURCE>_<FLAG>` for a source's own options.

## Tests

```bash
npm test
```

Every case runs against a throwaway fixture: a temp `$HOME`, a temp farm with
its own git checkout, a temp cache and a scrubbed `$PATH`. Nothing requires
`herdr`, `zellij`, `fzf`, an agent or a token, and nothing reaches a tracker —
payloads arrive through `--items-json`.

## License

MIT.
