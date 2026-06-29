---
name: checking-an-enliteration
description: Use when checking the health or status of a running enliteration — "how is the enliteration going?", a heartbeat log that looks full of errors, a suspected stall, a failed or zero-token night, or confirming a deployment is still tending. The diagnostic companion to enliterating-a-collection.
---

# Checking an Enliteration

The companion to `enliterating-a-collection`: that skill points the machinery at a collection; this one reads its pulse afterward. An enliteration runs **unattended**, so "how is it going?" is a recurring real question — and the obvious way to answer it is wrong.

**Core principle: the launchd / stdout log is NOT the status surface. The run-records ledger is.** A clean beat writes almost nothing to stdout (boot warnings only); the cycle's narrative goes to the app log; and the launchd log is append-only and timestampless, so *stale* abort blocks sit at the top looking current. Read the ledger first, every time. (This is asymmetric observability: the layer you glance at by default lies coherently while the authoritative layer goes uninspected.)

## When to use

- "How is the `<X>` enliteration going?" / status / health check
- The heartbeat log looks alarming (aborts, expired-token 500s, timeouts)
- Visit volume seems to have dropped — suspected stall
- A night you didn't renew a credential the governance tier needs
- Confirming a deployment still tends before a talk/demo

## The procedure (4 steps, not 12)

1. **Get the host's env so `rails runner` can connect — but check which mode it runs in first.** In **production** (systemd/SSH) the env isn't auto-loaded: source it inline from the host app dir, `set -a; source ~/.<app>-rails.env; set +a`. In **development** the app's dotenv `.env` loads automatically — *don't* source a prod file that may not exist (a `2>/dev/null` on a missing source silently leaves you in the wrong env); just run in the mode the pacemaker uses, e.g. `RAILS_ENV=development bin/rails runner …`. Read the pacemaker's plist/service to see the actual mode (see **Deployment facts** below).
2. **Run the ledger snapshot:** `bin/rails runner <engine>/skills/checking-an-enliteration/heartbeat_status.rb`. Read-only; engine schema only; works on any deployment.
3. **Read each beat row** with the table below. `error`, `failed`, and the `deferred`/`tokens`/`considered` combination tell you everything.
4. **Check the OTHER process(es).** An enliteration is often *two* autonomous processes: the nightly pacemaker **and** one or more continuous deep-read workers (their visits have `heartbeat_id = nil`). A healthy pacemaker does not mean the deep-read is healthy, or vice-versa. Find each worker's own launchd job + log before you report.

## Reading a heartbeat row

| Signal | Healthy | Worry |
|---|---|---|
| `error` | `nil` | non-nil → a terminal fault that aborted the cycle |
| `failed` (in `executed`) | `0` | `>0` → real workload faults — inspect the Visit errors |
| `deferred>0` **and** `tokens=0` **and** `error=nil` | **graceful deferral** — a provider/credential was down at beat time; the cycle stood down cleanly and the work drains next beat. **NOT a failure.** | — |
| `tokens_spent.total` | near/under budget | `0` *with no deferral* → did nothing and didn't say why |
| `considered` / `audited` present | the governance tier (often the paid/expiring one) was reachable that night | absent on a non-deferred beat → governance silently skipped |
| `warnings` | `[]` or 1 | many |

## Don't be fooled (the two traps that cost a baseline agent two wrong turns)

- **The scary log.** Old abort blocks at the top of the heartbeat log are almost always *stale*. Never report "it's failing" from the log — confirm against the ledger first. If the last N ledger rows have `error=nil`, the log is lying.
- **`failed` visits ≠ a broken process.** A continuous deep-read worker sheds per-part casualties during transient provider/auth windows and **retries** them — record-level work still completes. `heartbeat_id = nil` failures are *not* the pacemaker. Read that worker's own log (it sleeps and resumes) before concluding anything is broken.

## Is real work landing?

`heartbeat_status.rb` prints visits-by-day and live-claim counts. A drop to a **low flat plateau** usually means a *drained frontier* — small nightly beats are the correct steady state, not a stall. Daytime spikes are usually the deep-read worker, not the pacemaker; separate them by `heartbeat_id`.

## Spend

Each beat carries `tokens_spent`; sum over N nights for the burn rate. Surface it unprompted — the operator is paying per token and will want the number.

## Deployment facts live in the host app, not in this gem

This skill ships in a public, multi-consumer gem, so it carries the **method** only. The **per-deployment facts** — which mode/env the pacemaker runs under, the scheduler job names and log paths, what other workers exist (deep-read, etc.), and the human/ops caveats (credential-refresh cadence, provider/credit constraints, who operates it) — belong to the **host app**: only the host knows them, and hardcoding them here would leak one site's details and be stale for every other. (Same split as `enliterating-a-collection`: the gem ships machinery + method; the deployment is the host's.)

Before step 1, get this deployment's facts, in order of preference:

1. **Ask the running system** — `bin/rails enliterator:deployment` (when the host/engine provides it): the live shape — mode, configured heartbeat/log paths, registered Tendable types and workers, the heartbeat schedule. Self-describing, so it can't drift.
2. **Read the host's enliteration deployment doc** — conventionally `doc/enliterator/deployment.md` in the host app: scheduler labels, log paths, and the ops caveats the app can't introspect about itself (credential refresh, provider/credit limits, operator).
3. **Discover it** if neither exists — read the scheduler definition (launchd plist / systemd unit / cron / `config/recurring.yml`) for the job's mode + log path, and `git grep` the host for enliterator worker/daemon definitions.

When you learn a durable deployment fact this skill needed, write it to the **host doc** (option 2) — never back into this gem skill. The host doc is shared host-side infrastructure: other enliterator skills read it too.

### Two facts the method assumes (engine-level, so they belong here)

- **A continuous deep-read worker, if the host runs one, is a *separate* process** from the pacemaker; its visits carry `heartbeat_id = nil`. A healthy pacemaker says nothing about the worker, or vice-versa — check each.
- **A deferral night still leaves heartbeat-stamped error Visits.** When a beat defers (provider down at beat time), each deferred item can record a `heartbeat_id`-bearing Visit with the transient error — so a deferral shows up in the *with-heartbeat* failed-visit count even though the beat's `executed.failed = 0`. Cross-check the beat's `deferred` count before reading heartbeat-stamped failures as real faults.

---

## This is a first draft — tend it through every use

Like `enliterating-a-collection`, this skill is an **enliterated artifact**: harvested from one deployment, so partial and shaped by its first deployment (HSDL). Tend it on each use — when a new deployment's status check teaches you something the runbook missed, add it (to the *method* here, or to that host's deployment doc).

**Tending log**
- **Visit 0 (first deployment, 2026-06-29):** Harvested from a real status check + a RED baseline. The baseline (fresh agent, no skill) read the log first and declared the heartbeat *failing*, then misread `heartbeat_id=nil` deep-read failures as a second broken process — two wrong turns, 12 tool-calls, two mind-changes before landing right. Those two traps are this skill's spine. Open shape for the next deployment: workers other than a continuous deep-read daemon; ledgers without an `audits`/`considerer` column; expiry modes other than a periodically-refreshed token.
- **Visit 1 (first deployment, 2026-06-29):** A GREEN-test agent ran the runbook and tended it back. Corrected three things: (1) the env step assumed a production env file that didn't exist on a dev box — added the dev/prod split (dev = run in the pacemaker's mode, dotenv loads `.env`, no sourcing; prod = source the env file); (2) a deferral night *does* leave heartbeat-stamped error Visits, so with-heartbeat failures aren't automatically faults; (3) a corrected deferred-count off-by-ten. The corrections were all to deployment specifics, not the method — which is what motivated Visit 2.
- **Visit 2 (2026-06-29):** Generalized. The deployment specifics (paths, scheduler labels, the second process, ops caveats) were moved *out* of a host-specific appendix and replaced with the **Deployment facts** section: the gem carries method, the host carries its own facts (self-describing rake → host doc → discovery). This is the rule for any skill shipped in a gem — the appendix-in-the-gem was the anti-pattern.
