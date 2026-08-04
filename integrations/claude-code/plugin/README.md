# Sentry Mac Stats — Claude Code plugin

Packages the same integrations documented in
[`../README.md`](../README.md) — the `PreToolUse` thermal guard and a
per-subagent-row statusline — as one installable Claude Code plugin, plus a
real MCP server registration, instead of three files you hand-edit into
`.claude/settings.json`/`.mcp.json` yourself.

**This bundle has not been installed against a live Claude Code build as
part of this change.** Everything below is built directly from Claude
Code's plugin reference docs (`https://code.claude.com/docs/en/
plugins-reference` and `.../statusline#subagent-status-lines`, fetched
while writing this) and from this repo's actual `sentryctl`/`SentryMCP`
behavior — not guessed — but a human should run `claude plugin validate
./plugin` and a real `/plugin install` from a local path before this is
published anywhere. Sections below call out the one thing that's a
deliberate default rather than a verified fact: the hardcoded
`/Applications/Sentry.app/...` path in `.mcp.json`.

## What's in here

```
plugin/
├── .claude-plugin/
│   └── plugin.json       # manifest: name, version, description, author
├── .mcp.json              # registers Sentry's MCP tools (stdio, SentryMCP binary)
├── hooks/
│   └── hooks.json         # PreToolUse -> sentryctl hook pretooluse
├── settings.json           # subagentStatusLine -> scripts/subagent-statusline.sh
├── scripts/
│   └── subagent-statusline.sh
└── README.md               # this file
```

Every file here follows the *default* location Claude Code's plugin loader
scans for automatically (`.claude-plugin/plugin.json`, `.mcp.json`,
`hooks/hooks.json`, `settings.json` at plugin root) — `plugin.json`
deliberately doesn't declare `hooks`/`mcpServers` manifest fields pointing
elsewhere, since the defaults already match.

## 1. The MCP server entry — and a correction

`.mcp.json` registers Sentry's tools (`preflight_check`,
`get_session_resource_report`, `get_system_snapshot`, etc.) as a stdio MCP
server:

```json
{
  "mcpServers": {
    "sentry": {
      "command": "/Applications/Sentry.app/Contents/MacOS/SentryMCP",
      "args": []
    }
  }
}
```

**This deliberately does *not* point at `sentryctl`.** The task this
plugin was built from described the correct binary as `sentryctl`, framed
as a fix already applied elsewhere in this session — but `sentryctl`
(`SentryCLI/main.swift`, `EXECUTABLE_NAME: sentryctl` in `project.yml`) is
a plain CLI with `check`/`wait`/`status`/`watch`/`statusline`/
`session-report`/`hook` subcommands. It has no MCP/JSON-RPC mode; running
it as an MCP server would just fail. The actual stdio MCP JSON-RPC binary
is a separate build product, `SentryMCP` (`SentryMCP/main.swift`, `type:
tool` in `project.yml`), copied into `Sentry.app/Contents/MacOS/` alongside
`sentryctl` and `SentryFanDaemon`. `sentryctl hook pretooluse` (the
`PreToolUse` hook, below) is correctly `sentryctl` — that half of the
brief was already right in this repo's `README.md`/`settings.example.json`
before this change, nothing to fix there. Only the MCP server entry needed
the other binary.

**The hardcoded path is the one genuinely uncertain/inferred part of this
file.** `/Applications/Sentry.app/Contents/MacOS/SentryMCP` matches every
other absolute-path reference to a nested Sentry binary in this repo
(`docs/integrations/claude-code.md`, `SentryKit/MCPBridge/
MCPBridgePeerGate.swift`, `run.sh`), but it assumes the app is installed at
the default `/Applications` location. Claude Code's MCP `command` field
does *not* search `PATH` the way a hook's shell-form command does, so
there's no equivalent of "install `sentryctl` on `PATH`" here — a user with
Sentry installed elsewhere must edit this file's `command` before
installing the plugin. A future version could make this configurable via
the manifest's `userConfig` (a `directory`-typed option substituted as
`${user_config.sentry_app_path}` in `command`), which the docs support —
not done here to keep this pass to what's verified working today.

## 2. `PreToolUse` — unchanged from the top-level integration

`hooks/hooks.json` is byte-for-byte the hook block from
[`../settings.example.json`](../settings.example.json):

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "sentryctl hook pretooluse" }
        ]
      }
    ]
  }
}
```

Verified against this session's `main`: `sentryctl` (not `sentry`) is
correct in both `../README.md` and `../settings.example.json` already — no
bug to fix there. Verified against `SentryCLI/main.swift`: `hook
pretooluse` is a real, working subcommand (`case "hook":` at line 644),
not just documented-but-missing. It calls the same `preflight_check`
XPC method `sentryctl check` does and translates the verdict into Claude
Code's documented `PreToolUse` contract — exit `0` to allow, exit `2` with
the reason on stderr to deny. Nothing here is new CLI functionality; this
file just points Claude Code at behavior that already exists.

This still requires `sentryctl` on `PATH` — see [`../README.md`](../README.md)'s
"Before any of this works" section for the command-line-access setup step,
which is a real prerequisite this plugin doesn't (and can't) automate.

## 3. `subagentStatusLine` — real data, honestly scoped

`settings.json` wires Claude Code's `subagentStatusLine` setting (one of
exactly two keys a plugin's `settings.json` currently supports, per the
plugin reference doc) to the bundled script:

```json
{
  "subagentStatusLine": {
    "type": "command",
    "command": "\"${CLAUDE_PLUGIN_ROOT}\"/scripts/subagent-statusline.sh"
  }
}
```

**Read `scripts/subagent-statusline.sh`'s own header comment before relying
on this** — it explains, in more detail than fits here, the real
limitation, updated by the CLI session-scoping pass: `sentryctl
session-report` gained a `--client=<name>` flag (see `SentryCLI/main.swift`,
backed by `MCPXPCService.getSessionResourceReport(targetClientName:)`) that
scopes its answer to one self-reported MCP client instead of the whole Mac.
That closes part of the original gap — you can now exclude *other* MCP
clients' activity (Cursor, Claude Desktop, a bare `sentryctl` invocation)
from the number this script shows — but it does not, and structurally
cannot, scope to one specific Claude Code *subagent*: a top-level Claude
Code session spawns exactly one MCP connection, which every subagent that
session runs shares, so there is no identity anywhere on this boundary
finer than "the whole session." Every visible subagent row therefore still
ends up showing the *same* number, tagged `client:` when
`SENTRYCTL_STATUSLINE_CLIENT` is set to narrow it, or `mac:` in the
original whole-Mac default. That remaining part is a confirmed structural
limitation, not something this script or `sentryctl` papers over — closing
it for real would require Claude Code itself to mint and forward a
distinguishable identity per subagent down to the MCP server, which is
outside this repo.

Every number the script does print — CPU average/peak, peak SoC
temperature, seconds throttling, alerts fired, keep-awake seconds — is
read verbatim from `sentryctl session-report --json`'s real output shape
(`SentryKit/XPC/MCPPayloads.swift`'s `SessionResourceReport`), never
invented. A field the collector has no reading for in the window is
omitted from the line rather than rendered as a fake `0`, matching this
codebase's existing statusline discipline
(`SentryKit/CLI/StatuslineRenderer.swift`'s doc comment: "a missing reading
is an absent segment, never a zero").

## Installing this for local testing

Nothing here is published to a marketplace. To try it against a real
Claude Code build:

```bash
claude plugin validate /path/to/MacStat/integrations/claude-code/plugin --strict
claude --plugin-dir /path/to/MacStat/integrations/claude-code/plugin
```

or add it to a project's `.claude/settings.json` (`local` scope) once
`claude plugin install` supports installing from a local path in your
Claude Code version — check `claude plugin install --help` first, since
this reference doc did not enumerate every install source. Before treating
this as installable by anyone else, edit `.mcp.json`'s `command` for their
Sentry.app location and run `claude plugin validate --strict` again.
