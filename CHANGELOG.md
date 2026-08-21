# Changelog

All notable changes appear in this file. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [1.0.0] - 2026-08-21

First public release. Extracted from the Sentry triage command in
[H3xept/hedr_learn](https://github.com/H3xept/hedr_learn) and generalised until
the engine no longer knows what a tracker is. The `herdr_ingest_*` function
prefix and the `HERDR_INGEST_*` variable prefix date from that extraction and
are the stable public contract.

### Added

- Six-stage pipeline — fetch, normalise, select, summarise, prompt, spawn —
  with one canonical item shape between stage 2 and stage 3, so every filter,
  every sort and the whole test suite are source-independent.
- `--source ID|FILE`: four built-in adapters (`sentry`, `linear`, `github`,
  `json`) and any bash file defining `ingest_source_describe`,
  `ingest_source_fetch` and `ingest_source_normalize`. Optional
  `ingest_source_option`, `ingest_source_usage`, `ingest_source_check` and
  `ingest_source_summarise`. A file missing a required verb is refused by name.
  `herdr-ingest sources` lists the built-ins, and a chosen source appends its
  own flags to `--help`.
- `json` source: `--json-cmd` and `--json-map` turn any command that prints
  JSON into items, so a tracker with no adapter needs no code.
- `linear` source: `--team` and `--project`, either or both. Both together
  narrow to the intersection; neither is refused before a fetch.
- Replaceable stage 4: `--summarise CMD`, `--no-summarise`, a profile's
  `ingest_summarise`, or the source's own. A failing summariser costs the item
  its summary, never its space.
- Replaceable stage 5: `--prompt CMD`, `--prompt-template FILE` with eighteen
  slots, `--no-prompt`, a profile's `ingest_prompt`, or the built-in brief.
  Template substitution is a single left-to-right pass, so a body containing
  `{{ref}}` is never re-read as a slot.
- `--profile FILE` and `HERDR_INGEST_PROFILE`: a bash file sourced before the
  flags, carrying defaults and both hooks. A flag always beats a profile.
- Selection over the canonical rows: `--badge`, `--state`, `--label`,
  `--match`, `--updated-last`, `--created-last`, `--sort`, `--limit`.
- Farm control: `--root`, `--main`, `--base`, `--prefix`,
  `--worktree-template`, `--branch-template`, all templated on
  `{prefix} {key} {ref} {slug}`.
- Sweep control: `--auto`, `--max-spaces`, `--watch`, `--interval`,
  `--respawn`, `--no-focus`, `--dry-run`, and an fzf picker by default.
- `lazy-brief`: the `y` gate in front of the agent, `--agent CMD` to replace it,
  and a bare-session offer when stage 5 produced no brief.
- `--items-json FILE`: read any source's payload from a file, so every source
  can be exercised with no token and no network.
- `herdr-plugin.toml`: one popup pane (`pick`) and three actions (`sweep`,
  `dry-run`, `sources`).
- Installable agent skill; an example profile replacing both stages; a prompt
  template using every slot; a working stage-4 summariser;
  `examples/items.json`, a canonical payload that makes the whole pipeline run
  with no credentials; and `examples/sources/todo.sh`, a complete adapter that
  needs no token.
- A `node:test` suite that runs fully offline: no `herdr`, no `zellij`, no
  `fzf`, no agent and no token.

[1.0.0]: https://github.com/H3xept/herdr-ingest/releases/tag/v1.0.0
