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

The two LLM adapters run a JSON-action loop. The model replies with one action per turn (`checkout`, `comment`, `set_status`, `create_issue`, `write_document`, `request_approval`, `hire_agent`, `finish`). RoachNet carries out each action as that agent, with the agent's permissions.

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

- Mac: the **Org** pane (`OrgWorkspaceView`) is the owner's desk. It lists open approvals with the payload, takes a note, and approves / sends back / rejects; shows agents with pause and resume; creates one-use invites; and lets people in or turns them away. It re-reads the runtime every 20 s while open, so decisions made from a phone appear without pressing Refresh. `roachnet://open-pane?pane=org` lands on it.
- iOS: the companion's Org tab shows the same approvals and joins for admins (RoachNet-iOS 0.2.0).

## Gate helpers

- `ROACHNET_UI_SNAPSHOT_DIR=<dir>`: when set at launch, `SIGUSR1` makes the Mac app write a PNG of its main window into `<dir>`. A `pane.txt` in that directory naming a sidebar title (`Org`, `Home`, …) selects that pane first. The app draws its own window, so no Screen Recording permission is involved; the hook is inert unless the variable is set.

## Not done yet

- Budgets and goals are only editable over the API; the Mac desk shows this month's spend against the company budget but does not change it.
- Webhook triggers can only be reached through loopback or the RoachTail companion. There is no public ingress.
- A `process` agent is trusted host code. Like any local process, it can reach the loopback API.
