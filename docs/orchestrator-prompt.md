# Orchestrator prompt — finish Sentry's Tier 3 backlog

Paste everything below the line into a fresh Claude Code session at
`/Users/malekswilam/Developer/MacStatsProject`.

---

You are the **orchestrator** for the remaining feature backlog of Sentry
(codebase name: MacStat), a macOS menu-bar system monitor with iPhone and Apple
Watch companions. You will not write most of the code yourself — you will
dispatch subagents, review what they produce, integrate it, and keep `main`
green. Your job is judgement and integration, not typing.

## Repository

- Repo: `/Users/malekswilam/Developer/MacStatsProject/MacStat` (git; remote is
  `github.com/malekTheCoder/Sentry`)
- Planning docs live one level up in `/Users/malekswilam/Developer/MacStatsProject/`:
  `MacStat-Implementation-Plan.md` (the 21-section master plan),
  `MacStat-Fan-Control-Implementation-Plan.md`, `MacStat-Market-Research.md`,
  `MacStat-AI-Features-Research.md`, `MacStat-Launch-Readiness-Master-Prompt.md`
- The `.xcodeproj` is **generated** from `project.yml` by XcodeGen and is not
  committed. Run `/opt/homebrew/bin/xcodegen generate` after any `project.yml`
  edit, and before any build in a fresh worktree.

## First thing you must do

Do not trust this document's numbers. Establish ground truth yourself:

```sh
cd /Users/malekswilam/Developer/MacStatsProject/MacStat
git fetch --all --prune && git status -sb && git log --oneline -15
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
/opt/homebrew/bin/xcodegen generate
xcodebuild -project MacStat.xcodeproj -scheme MacStat -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath "$HOME/Library/Developer/MacStat-DerivedData" test
```

Record the actual test count as your baseline. At the time of writing it was
**632 tests, 0 failures**, with `MacStatMobile` (iOS Simulator) and
`MacStatWatch` (watchOS Simulator) both building clean — but work was still
landing, so verify rather than assume. There may also be unmerged branches
(`git branch -a`); check for `prep/signing`, `fix/battery-glyph`,
`fix/ios-metric-picker` and land them first if they exist and are green.

## The backlog

Ordered by value. **Not all of it should be built** — read the notes.

### 1. Pro tier — highest value, ship-blocking for revenue
`MacStatKit/Pro/ProGate.swift` and `ProEntitlement.swift` already implement the
free/paid cut correctly and are well tested. The gap is the concrete store: the
existing doc comment prescribes a StoreKit implementation, which is
**impossible** — the Mac app ships via Developer ID outside the Mac App Store,
and IAP does not exist there. It needs a `LicenseProEntitlementStore`
conforming to the same `ProEntitlementProviding` protocol: Ed25519 signature
verification over a license blob with the public key embedded in the app, an
activation call, and a cached offline grace period.

**You cannot finish this.** The checkout side needs a Paddle or Lemon Squeezy
account only the owner can create. Build the verification half, make it
testable with a locally generated key pair, and stop at the integration seam.
Do not invent API credentials or sign up for anything.

### 2. CLI stretch items — self-contained, genuinely parallel
`macstat watch` (streaming newline-JSON), `macstat statusline` (compact
one-liner for tmux/Starship/Claude Code status lines), and optionally a
loopback-only Prometheus `/metrics` endpoint. See the master plan §21 —
it specifies these in detail, including exit-code conventions (124 on timeout,
matching `timeout(1)`) and the "stdout is data, stderr is diagnostics" rule.
`MacStatCLI/` and the XPC service it talks to already exist.

The Prometheus endpoint opens a network listener; it must be loopback-only,
off by default, and gated in Settings the way `mcpRemoteAccessEnabled` already
is. Treat it as a security surface, not a convenience.

### 3. Theme editing — self-contained, medium value
15 presets exist and work. Missing: duplicate-and-edit, per-token colour wells,
per-metric colour assignment, import/export as JSON. Master plan §9.3.
Accessibility matters here — §9.4 requires a WCAG AA contrast check surfaced
inline in the editor, so a user cannot unknowingly build an unreadable theme.

### 4. Fan control Phase 3 — **do not delegate this unsupervised**
Phase 2 (the read-only shell) is merged. Phase 3 is actual SMC writes, which
require a **root LaunchDaemon** via `SMAppService`. The SMC protocol itself is
roughly a day's work; the daemon lifecycle, XPC peer verification, and failure
modes are not. Known hazards, already researched in `MacStat/docs/fan-control-spike.md`
and the Phase 2 agent's report:

- Requires a real enrolled Team ID; ad-hoc-signed daemons will not register.
- The daemon must clamp RPM to the SMC's own `F{i}Mn`/`F{i}Mx` **inside the
  daemon**, not just app-side — otherwise a compromised app requests any speed
  as root.
- It must revert `F{i}Md = 0` on client disconnect, on its own termination, and
  on heartbeat timeout.
- `SMAppService.unregister` is not reliably reached on a drag-to-Trash
  uninstall, so a leaked daemon can hold fans at 6000 rpm after the app is
  gone.

Design it, get the design reviewed by a human, and only then implement. Do not
auto-merge a root daemon to `main`.

### 5. Localization — **infrastructure only; do not machine-translate**
Three `.xcstrings` catalogs exist with ~350 English keys and zero translations.
An agent can extend coverage to strings that are still hardcoded, and can audit
for `Text(variable)` call sites that bypass `LocalizedStringKey`. An agent
should **not** produce shipping translations — untrusted machine translation in
a paid product is a quality and correctness risk, and nobody here can review
the output. Stop at coverage.

### 6. CloudKit sync — **recommend against building**
The plan assumed CloudKit, but the TLS-PSK remote listener already delivers the
actual use case (reach your Mac from anywhere) with lower latency and no
account infrastructure. Building CloudKit now would be a large, duplicative
workstream serving no unmet need. Only build it if the owner explicitly asks
after being told this. Report the recommendation; do not silently skip it.

## How to dispatch

**Calibrate scale to reality.** "Hundreds of agents" is the wrong shape for
this repo and will make things worse, not faster. Only three or four of these
workstreams are genuinely independent, and every one of them can touch
`project.yml` — parallel edits there produce merge conflicts that cost more
than the parallelism saves. Run **2–4 agents at a time**, each on its own git
worktree. Add more only when you have found genuinely disjoint work, and prefer
sequencing anything that touches shared build configuration.

The worktree pattern that has been working:

```sh
cd /Users/malekswilam/Developer/MacStatsProject/MacStat
git worktree add -b <branch> /Users/malekswilam/Developer/MacStatsProject/wt-<name> main
```

Each agent gets: its own worktree path, its own branch, its own
`-derivedDataPath` (e.g. `$HOME/Library/Developer/Sentry-<Name>-DD`) so
concurrent builds do not collide, and an explicit instruction **not to touch
the main checkout or sibling worktrees**, and **not to push or merge**. You do
all integration.

In every agent prompt, include:
- The exact build and test commands, plus the current baseline test count.
- That there is **no `timeout` command** on this machine.
- That builds take several minutes and must not be killed early — use a
  generous tool timeout (420000 ms has been reliable).
- That visual changes require actual visual verification (render to PNG, or
  drive the iOS Simulator MCP tools), because no passing test demonstrates
  "this looks right".
- The codebase conventions below, quoted, not summarised.

## Codebase conventions — quote these to every agent

This codebase has an unusually strict honesty discipline. Read the doc comments
in `MacStatMobile/Data/MockDataSource.swift`,
`MacStat/Settings/Panes/SyncPane.swift`,
`MacStatKit/LocalSync/LocalSyncClient.swift`, and
`MacStatKit/Services/FanControlBackend.swift` before writing anything.

- **Never ship a control that silently does nothing.** A control that cannot
  work must say why, in plain language, in the UI. If it cannot say why, it is
  omitted entirely rather than shown disabled — see `FanControlPane`'s absent
  "Return to Auto" button and `GeneralPane`'s absent Check-for-Updates button.
- **Never fabricate a reading.** "Zero" and "unavailable" must stay
  distinguishable in the type system, not just the UI. `FanSpeedReading` is an
  enum rather than `Double?` for exactly this reason.
- **Doc comments carry the why, at length** — rationale, tradeoffs, and
  anything deliberately *not* done, named explicitly so nobody re-derives it.
  Match the surrounding density; it is much higher than typical.
- **Theming**: `palette.*` / `theme.*` tokens only. Never hardcode a colour.
- **Settings persistence**: additive `decodeIfPresent ?? fallback` in
  `AppSettings`, so older settings files still decode.
- Commit messages are prose-heavy and explain the why. End with
  `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`.

## Integration protocol — non-negotiable

1. Never merge a branch you have not built and tested yourself, in the main
   checkout, after merging. An agent's claim of green is evidence, not proof.
2. Test count must be **≥ baseline**, failures must be **0**. A drop means
   tests were deleted or a target stopped compiling — investigate, do not push.
3. For anything touching iOS or watchOS, build those schemes too. The macOS
   suite will not catch a broken `MacStatMobile`.
4. Resolve conflicts by understanding both sides, not by picking one. The
   conflicts so far have been cases where **both** changes were correct
   (e.g. one branch fixed a stale product name in the same string another
   branch added keys to).
5. Push to `main` only when green. Use `--no-ff` merges so each workstream
   stays legible in history.
6. Clean up worktrees when done: `git worktree remove <path>`.

## Stop and ask the human — do not decide these yourself

- Anything requiring an account, credential, payment method, or signup.
- The root LaunchDaemon design for fan control Phase 3.
- Deleting remote branches, force-pushing, or rewriting published history.
- Whether to build CloudKit after reading the recommendation above.
- Shipping translations.

## Report honestly

When you finish, state the exact test count, what was built, what was
deliberately not built and why, and anything you could not verify. If something
failed, say so plainly with the output. An integration report that overclaims
is worse than one with acknowledged gaps — the owner is making release
decisions on it.
