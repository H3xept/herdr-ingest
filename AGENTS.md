# Repository guidance

`lib/herdr-ingest.sh` is the single source of behavior for the engine.
`bin/herdr-ingest` only sources it and calls `herdr_ingest_main`.
`skills/herdr-ingest/SKILL.md` and `README.md` document that behavior; they do
not redefine it.

The engine is source-agnostic and must stay that way. Every source concept lives
in `lib/sources/<id>.sh` behind the adapter contract; the engine knows only the
canonical item. An engine function that names a tracker, or reads a
tracker-specific field such as `shortId`, `permalink` or `identifier`, is a bug.
The test suite asserts this.

Keep the product dependency-free. It needs `bash`, `git`, `jq` and `curl`, plus
`fzf` for the picker and `herdr` and `zellij` to create real spaces. Node is
used only for `npx` distribution and `npm test` (`node:test`). Do not add
runtime dependencies.

Run `npm test` after any change to the engine, an adapter, `lazy-brief`, a
profile, an example, `herdr-plugin.toml`, the agent skill, or version metadata.
Tests must not require `herdr`, `zellij`, `fzf`, an agent, or any token on
`PATH` or in the environment.

Always exercise a change with `--dry-run` first. A dry run writes items,
summaries, briefs, KDL layouts and boot scripts into the cache directory,
creates no spaces, and needs neither `herdr` nor `zellij`. Point it at a fixture
root and set `HERDR_INGEST_CACHE` to keep the output isolated. With
`--items-json` it also needs no token, so any source can be exercised offline.

Never start an agent by itself. A right-hand pane runs `lazy-brief`, which waits
for an explicit `y` before it calls the agent. Anything else, including EOF,
drops to a login shell. This is the cost-control contract for the product; do
not bypass it.

Keep installation idempotent. Spaces are matched by working directory, not
label, so a renamed space is reused rather than duplicated. An existing checkout
is opened, never re-cut, and keeps its own branch. The boot script tries
`zellij attach` before creating from the layout, so a live session is never
rebuilt underneath you. An item is skipped when the cache recorded a spawn or
the farm already carries a branch for it; only `--respawn` overrides that.

Stage 4 and stage 5 are the customisation surface, and their precedence is part
of the contract. Stage 4: `--no-summarise`, then `--summarise CMD`, then a
profile hook, then the source's own, then off. Stage 5: `--no-prompt`, then
`--prompt CMD`, then `--prompt-template`, then a profile hook, then the built-in
brief. A flag always beats a profile default. The status line names the mode that
won, and the tests read that line. A failing stage-4 command costs the item its
summary, never its space.

Keep `package.json`, `herdr-plugin.toml` and `herdr_ingest_version` on the same
version. All three must read `1.0.0`.

## Vocabulary

One term per concept. The engine's own vocabulary is `item`, `source`,
`summary`, `brief`, `space` — never `issue`, which belongs to a source.

|Term|Meaning|
|---|---|
|source|an ingestion adapter: a file defining the three `ingest_source_*` verbs|
|item|one canonical work object, whatever tracker it came from|
|key|the item's stable id; it names the worktree and the cache files|
|ref|what a human calls the item|
|badge|the item's severity or kind, ranked by its source|
|raw|the untouched source object carried inside the item|
|stage|one of the six pipeline steps|
|summary|stage 4 output for one item|
|brief|the markdown file stage 5 writes, and the pane hands to the agent|
|profile|a bash file sourced before the flags, carrying defaults and hooks|
|hook|`ingest_summarise` or `ingest_prompt` defined by a profile|
|space|a herdr space|
|zellij session|a zellij session inside a space|
|pane|a zellij pane|
|checkout|a directory containing `.git`|
|worktree|a sibling checkout in a farm, cut from its main checkout|
|farm|a root directory holding a main checkout and its sibling worktrees|
|sweep|one pass of the pipeline|
|plugin pane|what the herdr popup opens, not a zellij pane|
