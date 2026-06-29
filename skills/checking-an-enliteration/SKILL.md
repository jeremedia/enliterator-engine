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

1. **Get the host's env so `rails runner` can connect — but check which mode it runs in first.** In **production** (systemd/SSH) the env isn't auto-loaded: source it inline from the host app dir, `set -a; source ~/.<app>-rails.env; set +a`. In **development** the app's dotenv `.env` loads automatically — *don't* source a prod file that may not exist (a `2>/dev/null` on a missing source silently leaves you in the wrong env); just run in the mode the pacemaker uses, e.g. `RAILS_ENV=development bin/rails runner …`. Read the pacemaker's plist/service to see the actual mode (see appendix for HSDL).
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

## HSDL appendix (the worked example — first enliteration)

- Host app dir: `/Volumes/jer4TBv3/workspaces/work/hsdl-ai`. **On this dev machine** the pacemaker runs `RAILS_ENV=development` and dotenv loads the project `.env` — run the script with `RAILS_ENV=development bin/rails runner …`, **no sourcing**. (`~/.hsdl-rails.env` is the *production/staging* server pattern and does **not** exist on this box; sourcing it is a silent no-op.)
- **Pacemaker:** launchd `app.domt.hsdl-ai-enliterator-heartbeat`, 01:30 PT (= 03:30 on the system/Central clock — the plist fires on system time, the ledger stamps app-zone Pacific). Log (NOT the authority): `~/Library/Logs/hsdl-ai-enliterator-heartbeat.log`.
- **Second process:** launchd `chds-deepread` — a continuous `KeepAlive` worker doing analytical deep-reads of theses; its `heartbeat_id=nil` per-part failures during auth windows are retried, not lost. Check its own log.
- **The standing caveat:** the governance/audit work runs on Bedrock; the SSO token lives ~9h and the beat is 01:30, so an unattended beat needs a fresh token. Jeremy re-auths nightly (so recent beats are clean); the permanent fix is the non-expiring NPS IAM key. A night without re-auth = a graceful **deferred** beat (id=63 / 2026-06-24: `tokens=0, deferred=43, error=nil`, drained by id=64).
- **A deferral night still leaves heartbeat-stamped error Visits.** id=63's 43 deferred items each recorded a `heartbeat_id`-bearing Visit with a transient gateway 500 — so a deferral shows up in the *with-heartbeat* failed-visit count even though the beat's `executed.failed=0`. Cross-check the beat's `deferred` count before reading heartbeat-stamped failures as real faults.

---

## This is a first draft — tend it through every use

Like `enliterating-a-collection`, this skill is an **enliterated artifact**: harvested from one deployment, so partial and HSDL-shaped. Tend it on each use — when a new deployment's status check teaches you something the runbook missed, add it.

**Tending log**
- **Visit 0 (HSDL, 2026-06-29):** Harvested from a real status check + a RED baseline. The baseline (fresh agent, no skill) read the log first and declared the heartbeat *failing*, then misread `heartbeat_id=nil` deep-read failures as a second broken process — two wrong turns, 12 tool-calls, two mind-changes before landing right. Those two traps are this skill's spine. Open shape for the next deployment: workers other than a `KeepAlive` deep-read daemon; ledgers without an `audits`/`considerer` column; non-Bedrock expiry modes.
- **Visit 1 (HSDL, 2026-06-29):** GREEN-test agent ran the runbook and tended it back. Corrected three things: (1) the env step assumed a prod `~/.hsdl-rails.env` that doesn't exist on the dev box — added the dev/prod split (dev = `RAILS_ENV=development`, dotenv `.env`, no sourcing); (2) a deferral night *does* leave heartbeat-stamped error Visits (id=63 → 43 of them), so with-heartbeat failures aren't automatically faults; (3) id=63's deferred count is 43, not 33. The skill still produced a ledger-first, both-processes, no-wrong-turns investigation — the corrections were to the HSDL appendix, not the method.
