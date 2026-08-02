# Integrating `macstat` into things you already run

`macstat` is the shell-facing half of Sentry. It talks to the running
`Sentry.app` over the same local XPC connection `MacStatMCP` uses, so it
adds no new data path, no new permission model, and no second sampling loop
— just a different transport with ergonomics aimed at a script instead of
an LLM tool call (plan §21.2).

Everything here is a config snippet. None of it requires Sentry to know the
tool it is being embedded in.

| Page | What it sets up |
|---|---|
| [`tmux.md`](tmux.md) | `status-right` showing live battery/CPU/temperature |
| [`starship.md`](starship.md) | A `custom` module in your shell prompt |
| [`claude-code.md`](claude-code.md) | Claude Code's `statusLine`, plus the hooks in [`../../integrations/claude-code/README.md`](../../integrations/claude-code/README.md) |
| [`watch.md`](watch.md) | Streaming NDJSON into `jq`, a log file, or a chart |

## Two things to get right first

### 1. The binary lives inside the app bundle

```bash
/Applications/Sentry.app/Contents/MacOS/macstat --help
```

It is not on `$PATH` by default and it cannot simply be copied elsewhere:
it links `MacStatKit.framework` through `@executable_path/../Frameworks`, so
a loose copy dies in dyld before `main` runs. Symlink it instead:

```bash
ln -s /Applications/Sentry.app/Contents/MacOS/macstat /usr/local/bin/macstat
```

A symlink is fine — dyld resolves `@executable_path` against the *real* path
behind the link. Every snippet in these pages assumes `macstat` resolves.

### 2. Sentry has to be running, with the read tool enabled

`macstat` reads nothing from the hardware itself. If `Sentry.app` is not
running you get a non-zero exit and this on stderr:

```
macstat: Couldn't reach MacStat.app: Couldn’t communicate with a helper
application.. Is MacStat running?
```

If it *is* running but MCP access is off, you get the reason from
**Settings → AI Access** instead. `get_system_snapshot` is a read tool and
is enabled by default, but the master switch (`mcpServerEnabled`) is off
until you turn it on — a deliberate default, not an oversight.

Neither case ever produces a fabricated reading. This is worth stating
plainly because a status line is the easiest place in a system to get away
with one.

## Enabling command-line access (one-time)

The Mach service every snippet on these pages depends on is published by a
launch agent bundled inside Sentry.app, and it is **off until you turn it
on**: Sentry > Settings > AI Access > Command-Line Access > "Turn On
Command-Line Access". macOS may ask you to approve the item under System
Settings > General > Login Items & Extensions; the Settings pane links
straight there and reports which of the three states you are in
(registered / waiting for approval / off). Once registered, a connecting
`macstat` even starts Sentry on demand if it isn't running.

Two honest caveats:

* **Signed builds only.** `SMAppService` refuses to register an agent for
  an ad-hoc-signed build (any local Debug build without a
  `DEVELOPMENT_TEAM`). The Settings pane says so instead of failing
  silently, and the CLI's error text names the real cause rather than
  asking "is MacStat running?".
* **Only Sentry's own binaries can connect.** The app verifies each peer's
  code signature (same team as the app, and one of the two bundled client
  binaries) before the connection reaches the service; refusals are logged
  under the `XPCListener` category in Console. Copying `macstat` out of
  Sentry.app already didn't work (rpath), and re-signing it differently
  won't either — both are by design.

This section replaces an earlier "Known limitation" that documented the
service as unreachable: `AppDelegate` started an
`NSXPCListener(machServiceName:)` but nothing ever declared the name in a
launchd `MachServices` key, so launchd never routed a connection to it.
The fix is `LaunchAgent/dev.malekswilam.macstat.xpc.plist` +
`MCPAgentRegistrar` (SMAppService), i.e. the standard registered-agent
shape — the same one the fan helper uses one privilege level up.
