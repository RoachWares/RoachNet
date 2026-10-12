# RoachClaw Org

RoachClaw Org lets RoachClaw run a company of AI agents. It is RoachNet's own Swift code (`native/macos/Sources/RoachNetRuntime/Org/`) and is served by the native runtime under `/api/org`. Paperclip was the design reference. No Paperclip code, Node service or database is used.

## What it does

- **Companies and org charts.** The first agent hired becomes the CEO. Reporting lines are checked for cycles. Each agent has a role, title, instructions, skills, heartbeat settings and a monthly budget. Every config change is saved as a revision that can be rolled back.
- **Work.** Goals, projects, labels and issues. Issues get `PREFIX-N` identifiers, follow a status state machine and support blockers (with cycle detection), sub-issues, comments with `@agent` mentions, atomic checkout, documents with compare-and-swap revisions, and work products.
- **Governance.**
  - Execution-policy review and approval stages route "done" through reviewers.
  - Approvals cover hire gates, board decisions and budget overrides.
  - Budget policies apply per company, agent or project, with soft warnings and hard stops. A hard stop pauses the affected scope until the board approves an override or the month rolls over.
- **Execution.** A wake queue applies admission gates, coalescing and per-issue execution locks. It runs heartbeats, wakes agents on assignment, comments, mentions, resolved blockers, completed children and decided approvals, records run transcripts, and writes a cost ledger.
- **Routines.** Each routine can have cron triggers (five fields, any time zone), webhook triggers (bearer or HMAC-SHA256 with a replay window) and API triggers. A concurrency policy decides what happens when a routine fires again before its last issue is closed.
- **Skills and secrets.** A versioned company skill library. Secrets are kept in a vault directory (files are mode 0600). Their values are never returned by the API or included in exports.
- **Export/import.** Exports a company as a portable template. Keys, invites, run history and secret values are left out. An imported company starts paused.

## Agent adapters

| Adapter | Runs | Notes |
|---|---|---|
| `roachclaw_local` (default) | RoachNet's native inference engine through `/api/chat` | Offline. Loopback endpoints only. Cost is recorded as `local`. |
| `openai_compatible` | Any `/v1/chat/completions` provider | Optional. Requires https (or http on this Mac). The API key comes from the vault (`apiKeySecret`). Cost is estimated from per-million-token prices when configured. |
| `http` | POSTs the run context to an agent service | The service calls back with the run token. |
| `process` | A host command | Only the RoachNet owner can configure it. The command receives the `ROACHNET_ORG_*` variables and `AGENT_HOME`. |
| `claude_local` | The person's own Claude Code (`claude -p --output-format stream-json`) | Owner-only. See Bring your own agents. |
| `codex_local` | The person's own Codex CLI (`codex exec --json`) | Owner-only. |
| `gemini_local` | Gemini CLI (`gemini --output-format stream-json`) | Owner-only. Built to the vendor's documented headless interface; not run live on the gate Mac. |
| `opencode_local` | OpenCode (`opencode run --format json`) | Owner-only. Same caveat as Gemini CLI. |
| `cursor_local` | Cursor CLI (`cursor-agent -p --output-format stream-json`) | Owner-only. Same caveat as Gemini CLI. |

The two LLM adapters run a JSON-action loop. The model replies with one action per turn (`checkout`, `comment`, `set_status`, `create_issue`, `write_document`, `request_approval`, `hire_agent`, `finish`). RoachNet carries out each action as that agent, with the agent's permissions.

## Bring your own agents

The coding agents people already use join a company as employees and work with the others through issues, comments, @mentions, sub-issues and approvals, as Paperclip agents do. RoachNet runs the person's own installed CLI, signed in the way they signed it in (a Claude or ChatGPT plan, or an API key in the agent's environment). It never reads, copies or stores their account credentials.

- **Finding them.** `GET /api/org/adapters` (owner only) lists each CLI: path, version, whether it is signed in and how (`claude auth status`, `codex login status`, `cursor-agent status`), and the models it offers (`codex debug models`). Account emails and org ids are not passed along. The runtime looks in PATH plus `~/.local/bin`, `~/.claude/local`, `/opt/homebrew/bin` and the other places these CLIs install, because an app-started runtime inherits launchd's short PATH. It sets `USER` when missing, because Claude Code finds its sign-in in the login Keychain under `$USER`.
- **Testing one.** `POST /api/org/adapters/:type/test` with `{ "adapterConfig": {...}, "probe": true }` sends "Reply with the single word ok." through the CLI, read-only, in a scratch folder, and reports the reply, latency, model and billing, or the error with a fix (sign in, update the CLI, plan limit).
- **A run.** The CLI gets:
  - the agent's identity, teammates (ids and @keys), instructions and skills: the system prompt for Claude Code, the start of the prompt for the others;
  - the wake reason, issue, recent comments and sub-issues on stdin;
  - the `ROACHNET_ORG_*` variables, `AGENT_HOME` and `TRACEPARENT`;
  - `AGENT_HOME/ROACHNET_ORG.md`, an API guide, and `AGENT_HOME/bin/roachnet-org`, a one-line wrapper (`roachnet-org POST /issues/ROAC-1/comments '{"body":"..."}'`). Claude Code's permission rules allow `Bash(roachnet-org:*)` and `Bash(curl:*)`.
  If the agent finishes without commenting on its issue, its final reply is posted there for it.
- **Access levels** (`adapterConfig.access`):
  - `read_only`: Claude Code in `dontAsk` mode with read tools only, or the Codex `read-only` sandbox.
  - `standard` (the default): Claude Code in `acceptEdits` mode with an allow-list, or the Codex `workspace-write` sandbox with network on so the agent can reach the Org API.
  - `full`: no sandbox and no prompts. The owner opts in for each agent.
- **Setup.** `useMySetup: false` runs Claude Code with `--setting-sources project,local --strict-mcp-config` and Codex with `--ignore-user-config`, so the agent runs without the person's own hooks, plugins and MCP servers. That is quicker and uses fewer tokens. `claudeAgent` runs one of the person's custom agents from `~/.claude/agents`.
- **Sessions.** Each issue keeps its own CLI session, saved on the agent with its working folder, so an agent resumes where it left off when it wakes on the same issue (`--resume`, `codex exec resume`, `--session`). If the saved session is gone, the run starts a fresh one.
- **Usage and cost.** Tokens come from the CLI's stream, with cached prompt tokens counted. A run on a plan is `subscription_included` and costs $0 here; Claude Code's API-equivalent cost and its rate-limit window go into the trace. A run on an API key is `metered_api`, with the cost the CLI reports or an estimate from the person's price table.
- **Mac.** Org › Agents › Hire Agent picks where the agent runs, shows each CLI's install and sign-in state with a Sign In in Terminal handoff, and sets the model, access level, setup, custom agent, working folder and reasoning effort. It also has Test and Hire buttons. Edit on an agent row opens the same sheet.

## Tracing

Every run is a RoachTrace trace (`/api/traces`, and `/api/org/companies/:id/traces` scoped to a company): the agent's span, a generation for each model turn with tokens, time to first token and speed, and a span for each tool call. The Org desk has a Traces board, and Settings › RoachClaw › Tracing sets retention, content capture and OTLP export to Langfuse or any collector. Model calls an agent makes to RoachNet's own model server carry `traceparent` and land in the same trace.

## People and access

- A loopback caller on this Mac, or the primary RoachTail device, is the **owner**.
- A paired RoachTail **peer** device acts as the person it is linked to. An unlinked peer can only accept an invite.
- `x-roachnet-org-key: rnorg_…` is a person or agent API key. Keys are stored as SHA-256 hashes and are revoked when an agent is terminated.
- `x-roachnet-org-key: rnrun_…` is a run token. It is HMAC-signed and only valid while its run is running.
- Company roles are owner, admin, operator and viewer. They can be extended with grants: `agents:create`, `users:invite`, `users:manage_permissions`, `tasks:assign`, `joins:approve`, `budgets:manage`, `secrets:manage`.
- Agents can never change adapter settings, mint keys, write secrets or change budgets.

## Storage

`<storage>/RoachClaw/org/` contains:

- `instance.json`
- `companies/<id>/state.json`
- `activity.jsonl`
- `runs/<runId>.log`
- `secrets/`

All files are written atomically with owner-only permissions. Runs that were in flight when the process stopped are marked `process_lost` on the next start.

## Configuration

- `ROACHNET_ORG_SCHEDULER=0` turns off the timer. Tests call `POST /api/org/engine/tick` instead.
- `ROACHNET_ORG_TICK_MS` sets the scheduler interval. The default is 30 s.

## Surfaces

- Mac: the **Org** pane (`OrgWorkspaceView`) is the owner's desk. It lists open approvals with the payload, takes a note, and approves / sends back / rejects; hires agents and edits how they run; shows agents with pause and resume; creates one-use invites; and lets people in or turns them away. Boards for Issues, the Org chart, Routines, Budgets and Traces sit beside the desk. It re-reads the runtime every 20 s while open, so decisions made from a phone appear without pressing Refresh. `roachnet://open-pane?pane=org` lands on it.
- iOS: the companion's Org tab shows the same approvals and joins for admins (RoachNet-iOS 0.2.0).

## Gate helpers

- `ROACHNET_UI_SNAPSHOT_DIR=<dir>`: when set at launch, `SIGUSR1` makes the Mac app write a PNG of its main window into `<dir>`. The app draws its own window, so no Screen Recording permission is involved; the hook is inert unless the variable is set. Optional files in `<dir>`:
  - `pane.txt` names what to show first: a sidebar title (`Org`, `Home`, …), `Org#Traces` for an Org board, `Org!hire` for the Hire sheet, or `settings:roachClaw` for a Settings pane.
  - `theme.txt` switches the theme (`<theme id> [dark|light|system]`).
  - `scroll.txt` (`0` to `1`, or `bottom`) scrolls the main scroll view first.

## Not done yet

- Goals are only editable over the API.
- Webhook triggers can only be reached through loopback or the RoachTail companion. There is no public ingress.
- A `process` agent is trusted host code. Like any local process, it can reach the loopback API. The same goes for a CLI agent on `full` access.
- The CLI's own child processes are not put in a process group, so a tool a CLI leaves running can outlive a cancelled run.
