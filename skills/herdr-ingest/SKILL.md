---
name: herdr-ingest
description: Turn a queue of work items into one git worktree plus one herdr space each, from Sentry, Linear, GitHub or any JSON pipeline. Use when sweeping a tracker into worktrees, wiring a new ingestion source, replacing the summarisation or brief-writing step, dry-running what a sweep would spawn, or debugging why an item was skipped. Triggers on herdr-ingest, ingest to spaces, spawn a space per item, worktree per item, brief pane, ingestion source, --json-map, prompt template, profile hook.
---

# herdr-ingest

One work item becomes one worktree, one herdr space, and one pane that waits for
`y` before it starts an agent. The product is a six-stage pipeline; the source
and two of the stages are replaceable.

```
1 fetch      the source pulls a raw payload
2 normalise  the payload becomes canonical items
3 select     filter, sort, cap, then --auto or an fzf pick
4 summarise  replaceable
5 prompt     replaceable
6 spawn      worktree + herdr space + a pane behind the `y` gate
```

Stages 1, 2, 3 and 6 are the engine and are the same for every source. Stage 4
and stage 5 are the customisation surface.

## Read this first

`lib/herdr-ingest.sh` is the single source of behavior. `bin/herdr-ingest` only
sources it and calls `herdr_ingest_main`. `lib/sources/*.sh` are the adapters.
`lazy-brief` is the pane. This document describes behavior; it does not define
it.

## Always dry-run first

```bash
herdr-ingest --source linear --project ENG --root /tmp/farm --auto --dry-run
```

A dry run writes items, summaries, briefs, KDL layouts and boot scripts into the
cache and creates no spaces. It needs neither `herdr` nor `zellij`. With
`--items-json FILE` it needs no token either, so it is also how the tests run.

## The canonical item

Every source normalises to the same object. `key` is the only required field:

| field | meaning |
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
|`fields[{name,value}]`|the brief's table|
|`body`|markdown detail|
|`raw`|the untouched source object|

Anything omitted is filled in by the engine. `herdr_ingest_canonicalize` is the
only place that decides a default.

## Sources

`herdr-ingest sources` lists them. `--source` takes an id or a path to a file.

|id|prefix|ingests|needs|
|---|---|---|---|
|`sentry`|`sentry`|issues of one project active inside a window|`SENTRY_AUTH_TOKEN`, `--org`, `--project`|
|`linear`|`linear`|issues of one project or team, with description and discussion|`LINEAR_API_KEY`, `--team` or `--project`|
|`github`|`gh`|issues and pull requests of one repository|`GITHUB_TOKEN`, `--repo`|
|`json`|`item`|any command or file that prints JSON|`--json-cmd`, or `--items-json`|

Source flags append to `--help` once `--source` is set:
`herdr-ingest --source github --help`.

Per-source flags: sentry takes `--org`, `--project`, `--api-base`, `--query`,
`--active-last`, `--fetch-sort`, `--fetch-limit`. Linear takes `--team`,
`--project`, `--api-base`, `--state-types`, `--fetch-limit`. GitHub takes `--repo`,
`--api-base`, `--gh-state`, `--gh-labels`, `--gh-assignee`, `--fetch-limit`,
`--comments`. The json source takes `--json-cmd` and `--json-map`.

### Reaching a tracker with no adapter

Use the json source. It is the escape hatch and the reason the product is not
tied to a tracker:

```bash
herdr-ingest --source json \
  --json-cmd 'jira-export --project ENG' \
  --json-map '[.issues[] | {key: .key, title: .fields.summary, url: .self,
                            state: .fields.status.name, body: .fields.description}]' \
  --prefix jira --auto --dry-run
```

### Writing an adapter

A source file is bash defining three functions and two variables:

```bash
HERDR_INGEST_SOURCE_ID=myjira
HERDR_INGEST_SOURCE_PREFIX=jira
ingest_source_describe()  { printf 'myjira\tissues of one board\n'; }
ingest_source_fetch()     { curl -sS ... ; }          # raw payload to stdout
ingest_source_normalize() { jq -c '[.issues[] | {...}]'; }
```

Three optional hooks: `ingest_source_option` claims flags (set
`HERDR_INGEST_OPT_SHIFT` to how many arguments it consumed),
`ingest_source_usage` appends to `--help`, `ingest_source_summarise` supplies
the source's own stage 4. The engine refuses a file missing a required verb, and
names the verb.

## Stage 4: summarise

Precedence, highest first: `--no-summarise`, `--summarise CMD`, a profile's
`ingest_summarise`, the source's own, then off. The status line names the mode
that won (`summarise cmd`, `summarise hook`, `summarise source`, `summarise off`).

`--summarise CMD` runs per item with `$1` the item JSON path, `$2` the worktree
path, the item on stdin, and stdout becoming the brief's `## Context` section.
`HERDR_INGEST_ITEM`, `HERDR_INGEST_WORKTREE`, `HERDR_INGEST_MAIN_CHECKOUT` and
`HERDR_INGEST_SOURCE_ID` are exported. A failing summariser costs the item its
summary, never its space, and its partial output is discarded.

`examples/summarise-git-blame` is a working one.

## Stage 5: prompt

Precedence, highest first: `--no-prompt`, `--prompt CMD`,
`--prompt-template FILE`, a profile's `ingest_prompt`, the built-in brief.

`--prompt CMD` runs per item with `$1` item JSON, `$2` summary, `$3` the brief
path to write, `$4` branch, `$5` worktree. Writing nothing is a valid answer: the
pane then offers a bare agent session instead of a brief.

`--prompt-template FILE` substitutes `{{key}} {{ref}} {{title}} {{subtitle}}
{{url}} {{badge}} {{state}} {{labels}} {{body}} {{fields}} {{summary}}
{{branch}} {{worktree}} {{main}} {{source}} {{repo_skill}} {{item_json}}`. The
scan is one left-to-right pass, so a body containing `{{ref}}` is not re-read as
a slot, and an unknown slot is kept verbatim.
`examples/prompt-template.md` uses every slot.

## Profiles

`--profile FILE` is a bash file sourced before the source is loaded and before
the flags are parsed. Four layers decide every knob, and each only fills what
the layer before it left empty:

1. the engine's defaults
2. the profile — which is why it can choose the source itself
3. the source — its id, prefix, badge ranking and option defaults
4. the flags

So a profile sets any `HERDR_INGEST_*` name `--help` lists, including
`HERDR_INGEST_SOURCE`, `HERDR_INGEST_ROOT`, `HERDR_INGEST_MAIN`,
`HERDR_INGEST_BASE`, `HERDR_INGEST_PREFIX`, `HERDR_INGEST_SORT`,
`HERDR_INGEST_AUTO`, `HERDR_INGEST_DRY`, and any source option as
`HERDR_INGEST_<SOURCE>_<FLAG>` (`HERDR_INGEST_JSON_MAP`,
`HERDR_INGEST_SENTRY_ACTIVE_LAST`, `HERDR_INGEST_LINEAR_STATE_TYPES`,
`HERDR_INGEST_GITHUB_STATE`). It may also define `ingest_summarise` and
`ingest_prompt`. A flag always beats a profile. `profiles/example.sh` is a
working one, and `HERDR_INGEST_PROFILE` is the default profile.

When adding a knob to the engine, seed it with `herdr_ingest_seed` rather than
assigning it, or the profile layer silently stops working for that knob.

## Selection

`--badge`, `--state`, `--label` take comma lists. `--match` is a
case-insensitive regex over title and subtitle. `--updated-last` and
`--created-last` take `5m`, `2h`, `2d`, `1w`. `--sort` takes `updated`,
`created`, `age`, `badge`, `title`, `key` or `none`. `--limit` caps what is
kept. Every filter runs over the canonical rows, so `--items-json` and a live
fetch agree exactly.

## Spawning

`--auto` sweeps without asking; the default is an fzf picker where `TAB` marks
and `ENTER` spawns. `--max-spaces N` is a rate limit, not a filter: the rest
stay in the source and the next sweep picks them up. `--watch` with
`--interval SECONDS` keeps sweeping. `--no-focus` leaves focus where it is.
`--pane` holds the terminal open at the end, which is what makes a herdr popup
readable; it is a no-op when stdout is not a terminal.
`--agent CMD` (or `HERDR_INGEST_AGENT`) replaces the agent the pane offers.
`--root`, `--main`, `--base`, `--prefix`, `--worktree-template` and
`--branch-template` decide what gets cut and what it is called; both templates
take `{prefix} {key} {ref} {slug}`.

An item is skipped when this cache already recorded a spawn for it, or when a
branch for it exists in the farm. `--respawn` overrides both. A space already
sitting in the item's worktree is reused, matched by working directory, not
label. An existing checkout is opened, never re-cut, and keeps its own branch.

## The `y` gate

The pane runs `lazy-brief`, which prints the brief and waits for an explicit
`y`. Anything else, including EOF, drops to a login shell. No layout ever starts
an agent directly. This is the cost-control contract; do not bypass it.

## As a herdr plugin

`herdr-plugin.toml` declares one popup pane `pick` and three actions `sweep`,
`dry-run` and `sources`. Link it with `herdr plugin link /path/to/repo`. The
entrypoints read their farm and source from `HERDR_INGEST_PROFILE`, so set one
before binding a key.

## Where things live

|path|what|
|---|---|
|`lib/herdr-ingest.sh`|the engine; the single source of behavior|
|`lib/sources/*.sh`|the adapters|
|`bin/herdr-ingest`|CLI entry point|
|`lazy-brief`|the `y` gate in front of the agent|
|`profiles/example.sh`|a profile replacing both stages|
|`examples/`|a prompt template and a summariser|
|`herdr-plugin.toml`|the plugin manifest|
|`$HERDR_INGEST_CACHE/<source>/`|`raw.json`, `items.json`, `items.rows`, `items/`, `summaries/`, `briefs/`, `spawned/`, layouts and boot scripts|

The cache defaults to `~/.cache/herdr-ingest-<root>`, named after the farm.

## Gates

Run `npm test` after any change to the engine, an adapter, `lazy-brief`, the
manifest, this skill or the version. Tests must not require `herdr`, `zellij`,
`fzf`, an agent, or any token. Keep `package.json`, `herdr-plugin.toml` and
`herdr_ingest_version` on the same version.
