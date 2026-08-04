#!/bin/sh
# Claude Code `subagentStatusLine` hook — renders a custom row for every
# subagent shown in the agent panel (docs: "Subagent status lines",
# https://code.claude.com/docs/en/statusline#subagent-status-lines).
#
# WHAT THIS SCRIPT ACTUALLY KNOWS, STATED PLAINLY (updated for the CLI
# session-scoping pass — read this before assuming the gap below is closed):
#
# Claude Code hands this script one JSON object per refresh tick containing
# a `tasks` array — one entry per visible subagent, each with its own `id`,
# `status`, `model`, `tokenCount`, `cwd`, etc. The obvious feature to build
# here is "show *this* subagent's resource cost." `sentryctl session-report`
# now *can* scope its answer to one self-reported MCP client via a
# `--client=<name>` flag (`SentryCLI/main.swift`'s `session-report` case,
# backed by `MCPXPCService.getSessionResourceReport(targetClientName:)` —
# see `SentryKit/Services/AgentSessionReport.swift` for the attribution math
# and `SentryKit/Services/AgentSessionIdentity.swift`/`AgentSessionRegistry
# .swift` for why a "client" is a self-reported name, not a session UUID).
# That flag genuinely did not exist before this pass; it does now.
#
# **What it does NOT do, and cannot do at this layer:** distinguish one
# subagent task from another. Claude Code's `tasks[].id` still has no
# relationship to any Sentry identity — a top-level Claude Code session
# spawns exactly one `SentryMCP` process (one MCP connection, one
# `MCPClientIdentity.sessionID`, one self-reported client name), and every
# subagent that session runs shares that one connection: subagents are
# in-process Claude Code constructs, not separate processes that ever dial
# Sentry's XPC service on their own. `--client=<name>` selects *which MCP
# client/session* to report on — useful when several different tools
# (Claude Code, Claude Desktop, Cursor, a bare `sentryctl` invocation) are
# all active on the same Mac and you want to exclude the others' noise —
# but it cannot select *which subagent within one Claude Code session*,
# because that finer identity does not exist anywhere on this boundary. This
# is a confirmed structural limitation, not a missing flag: closing it for
# real would require Claude Code itself to mint and forward a distinguishable
# identity per subagent down to the MCP server, which is outside `sentryctl`
# and outside this repo.
#
# So: this script still calls `sentryctl session-report` **once per tick**
# and paints the *same* line onto every visible subagent row — that part is
# unchanged and, per the above, unchangeable from here. What changed is
# *which* activity that one line reflects:
#
#   - `SENTRYCTL_STATUSLINE_CLIENT` unset (the default): no `--client` flag
#     is passed, so the report falls back to `sentryctl`'s own invocation
#     scope — the exact same whole-Mac-ish number this script always showed,
#     still tagged "mac:" for the same honesty reason as before.
#   - `SENTRYCTL_STATUSLINE_CLIENT` set to a client name (get the exact,
#     case-sensitive spelling from `sentryctl sessions` — typically whatever
#     your MCP client self-reports, e.g. "Claude Code"): the report is
#     scoped to that one client's activity via `--client`, and the line is
#     tagged "client:" instead of "mac:" so it's never confused with the
#     whole-Mac figure. Still one number, still repeated on every subagent
#     row — narrower attribution, not per-agent attribution.
#
# WHAT IS REAL: every number below comes verbatim from
# `sentryctl session-report --json`'s actual fields (averageCPUPercent,
# peakCPUPercent, peakSoCTemperatureCelsius, secondsThrottling, alertsFired,
# keepAwakeSecondsHeld) — see SentryKit/XPC/MCPPayloads.swift's
# `SessionResourceReport`. Nothing here is fabricated or guessed; a field
# that's `null` (the collector never got a reading in the window) is simply
# omitted from the line, per this codebase's "missing reading is an absent
# segment, never a zero" rule (see StatuslineRenderer.swift's doc comment)
# — never rendered as a fake 0.

# How far back `session-report` looks. 900s (15m) balances "recent enough
# to mean something" against Sentry's default MCP rate limit (20 calls/min,
# Settings -> AI Access) — this script makes one call per refresh tick, same
# budget concern as ../../docs/integrations/claude-code.md's main statusline.
SINCE_SECONDS="${SENTRYCTL_STATUSLINE_SINCE:-900}"

# Optional client-name scope (CLI session-scoping pass) — see the header
# comment above for exactly what this narrows and what it still can't.
# Unset by default: opting in requires knowing your own MCP client's exact
# self-reported name, which this script has no way to discover on its own
# (it's a fact about the *other* end of the connection, the MCP client, not
# something visible from this hook's stdin payload).
TARGET_CLIENT="${SENTRYCTL_STATUSLINE_CLIENT:-}"

command -v sentryctl >/dev/null 2>&1 || exit 0
command -v /usr/bin/python3 >/dev/null 2>&1 || exit 0

# Claude Code pipes the request JSON on stdin exactly once — read it before
# shelling out, since stdin can't be re-read afterward.
payload=$(cat)

# `|| exit 0`: same discipline as ../../docs/integrations/claude-code.md's
# main statusline script (`|| true`). A `sentryctl` failure (Sentry not
# running, XPC bridge not set up, MCP tool disabled in Settings -> AI
# Access) must degrade this hook to "say nothing" — emitting no reply line
# for any task keeps Claude Code's own default `name · description · token
# count` row, which is exactly the doc's documented fallback ("Omit a
# task's id to keep the default rendering for that row").
if [ -n "$TARGET_CLIENT" ]; then
    report=$(sentryctl session-report --since="$SINCE_SECONDS" --client="$TARGET_CLIENT" --json 2>/dev/null) || exit 0
else
    report=$(sentryctl session-report --since="$SINCE_SECONDS" --json 2>/dev/null) || exit 0
fi
[ -n "$report" ] || exit 0

# Handing both blobs to python3 via the environment (rather than stdin,
# already consumed, or argv, which has length/quoting limits on some
# shells) keeps the JSON parsing in one place that can reason about missing
# fields instead of scattering `grep`/`cut` across this file the way the
# simplest main-statusline.sh example does — that approach is fine for two
# flat string fields; it is not fine for "build one line from up to six
# optional numeric fields, then repeat it once per task in a JSON array."
SENTRY_SUBAGENT_PAYLOAD="$payload" SENTRY_SUBAGENT_REPORT="$report" SENTRY_SUBAGENT_SCOPED="$TARGET_CLIENT" /usr/bin/python3 <<'PYEOF'
import json
import os
import sys

def load(env_var):
    raw = os.environ.get(env_var, "")
    if not raw:
        return None
    try:
        return json.loads(raw)
    except Exception:
        return None

payload = load("SENTRY_SUBAGENT_PAYLOAD")
report = load("SENTRY_SUBAGENT_REPORT")
scoped_to = os.environ.get("SENTRY_SUBAGENT_SCOPED", "")

if not isinstance(payload, dict) or not isinstance(report, dict):
    sys.exit(0)

tasks = payload.get("tasks")
if not isinstance(tasks, list) or not tasks:
    sys.exit(0)

# `columns` is the usable row width Claude Code told us about. Fall back to
# a conservative width rather than guessing something large enough to wrap.
try:
    columns = int(payload.get("columns") or 60)
except (TypeError, ValueError):
    columns = 60

def fmt_minutes(seconds):
    minutes = seconds / 60.0
    # Under a minute reads as "0m", which looks like nothing happened —
    # round up so a 20s keep-awake hold doesn't disappear.
    return "<1m" if 0 < minutes < 1 else f"{minutes:.0f}m"

segments = []

avg_cpu = report.get("averageCPUPercent")
peak_cpu = report.get("peakCPUPercent")
if avg_cpu is not None and peak_cpu is not None:
    segments.append(f"⚙️{avg_cpu:.0f}/{peak_cpu:.0f}% cpu")
elif avg_cpu is not None:
    segments.append(f"⚙️{avg_cpu:.0f}% cpu")

peak_temp = report.get("peakSoCTemperatureCelsius")
if peak_temp is not None:
    segments.append(f"\U0001F321{peak_temp:.0f}°C")

throttling = report.get("secondsThrottling")
if isinstance(throttling, (int, float)) and throttling > 0:
    segments.append(f"\U0001F525{fmt_minutes(throttling)} throttled")

awake = report.get("keepAwakeSecondsHeld")
if isinstance(awake, (int, float)) and awake > 0:
    segments.append(f"{fmt_minutes(awake)} awake")

alerts = report.get("alertsFired")
if isinstance(alerts, (int, float)) and alerts > 0:
    segments.append(f"{int(alerts)} alert(s)")

if not segments:
    # `session-report` answered, but every field in the window was empty
    # (fresh app launch, no samples yet) — nothing honest to show, and
    # printing the prefix alone would be noise, not data.
    sys.exit(0)

# "mac:" when unscoped, "client:" when `--client=<name>` narrowed the
# report to one self-reported MCP client — never "agent:" or a per-task
# label, and never the client name itself repeated verbatim, because
# *every visible row still gets the exact same line* (see the header
# comment): there is exactly one number to show here, not N of them, no
# matter which of the two modes produced it.
prefix = "client: " if scoped_to else "mac: "
line = prefix + " · ".join(segments)
if columns > 0 and len(line) > columns:
    line = line[: max(0, columns - 1)] + "…"

for task in tasks:
    if not isinstance(task, dict):
        continue
    task_id = task.get("id")
    if not task_id:
        continue
    sys.stdout.write(json.dumps({"id": task_id, "content": line}) + "\n")
PYEOF
