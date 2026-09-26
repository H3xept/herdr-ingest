# Security policy

## Supported versions

Only the latest release receives security fixes.

## Report a vulnerability

Do not open a public issue for a security problem.

Report it privately through
[GitHub security advisories](https://github.com/H3xept/herdr-ingest/security/advisories/new).
Include the version, your platform, the steps to reproduce, and the impact you
expect.

The maintainer answers in the advisory. When the fix ships, the advisory is
published and credits you, unless you ask to stay anonymous.

## Scope

The plugin runs `git`, `jq`, `curl`, `zellij` and herdr with the rights of your
user. It reads source tokens (Sentry, Linear, GitHub) from your environment or
your profile and sends them only to that source's API. Item text from a source
is data: it lands in brief files and pane titles, and no pane starts an agent
until you answer `y`.

A profile, a `--summarise` or `--prompt` command, and a custom source file are
your own code, and the plugin runs them as given. A way to make the plugin run
a command that item data chose, send a token anywhere but its own source, start
an agent without the `y` gate, or write outside the farm and the cache is in
scope.
