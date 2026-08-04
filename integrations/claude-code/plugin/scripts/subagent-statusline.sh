#!/bin/sh
# Claude Code `subagentStatusLine` hook — renders a custom row for every
# subagent shown in the agent panel (docs: "Subagent status lines",
# https://code.claude.com/docs/en/statusline#subagent-status-lines).
#
# WHAT THIS SCRIPT ACTUALLY KNOWS, STATED PLAINLY:
#
# Claude Code hands this script one JSON object per refresh tick containing
# a `tasks` array — one entry per visible subagent, each with its own `id`,
# `status`, `model`, `tokenCount`, `cwd`, etc. The obvious feature to build
# here is "show *this* subagent's resource cost." `sentryctl` cannot do
# that today: `sentryctl session-report` (SentryCLI/main.swift's
# `session-report` case, backed by `MCPXPCService.getSessionResourceReport`)
# attributes cost to *the calling XPC connection's own session* — see
# `AgentSessionIdentity` and `SentryKit/Services/AgentSessionReport.swift` —
# and this script's own invocation of `sentryctl` is one connection, not
# one-per-subagent. There is no `--session-id` / `--task-id` flag to point
# it at a specific Claude Code task, and Claude Code's `tasks[].id` has no
# relationship to a Sentry `AgentSessionIdentity` UUID at all: subagents are
# in-process Claude Code constructs, not separate processes that ever dial
# Sentry's XPC service themselves.
#
# So: this script calls `sentryctl session-report` **once per tick**,
# scoped to whatever session identity that one `sentryctl` invocation gets
# (in practice, grouped by the `sentryctl` client name — see
# `MCPXPCService.getSessionResourceReport`'s fallback), and paints the
# *same* line onto every visible subagent row, tagged "mac:" so nobody
# mistakes it for a per-agent number. That is a real, honest gap, not a
# rounding error, and it is why this script ships as a documented
# placeholder rather than a finished feature. Closing it for real needs
# `sentryctl` (or a wrapper) to thread a per-subagent identity through to
# `getSessionResourceReport`, which is CLI work out of scope for this
# integration-glue pass — see the plugin README for the full writeup.
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
report=$(sentryctl session-report --since="$SINCE_SECONDS" --json 2>/dev/null) || exit 0
[ -n "$report" ] || exit 0

# Handing both blobs to python3 via the environment (rather than stdin,
# already consumed, or argv, which has length/quoting limits on some
# shells) keeps the JSON parsing in one place that can reason about missing
# fields instead of scattering `grep`/`cut` across this file the way the
# simplest main-statusline.sh example does — that approach is fine for two
# flat string fields; it is not fine for "build one line from up to six
# optional numeric fields, then repeat it once per task in a JSON array."
SENTRY_SUBAGENT_PAYLOAD="$payload" SENTRY_SUBAGENT_REPORT="$report" /usr/bin/python3 <<'PYEOF'
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
    # printing "mac: " alone would be noise, not data.
    sys.exit(0)

# "mac:" prefix, not "agent:" or a per-task label — see the header comment.
# This is the one place in the line that is doing load-bearing honesty
# work: every subagent row gets the exact same suffix precisely because
# there is exactly one number to show, not N of them.
line = "mac: " + " · ".join(segments)
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
