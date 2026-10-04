# AGENTS.md — working ON the autodev codebase

This file is the authoritative context for any AI agent (or human) modifying
autodev. **Read it fully before editing anything.** Every factual claim here was
verified against the source at the version in `VERSION`. If the code and this
document disagree, the code is right — fix this document in the same change.

---

## 1. What autodev is

A set of shell programs that run [cline](https://github.com/cline/cline) as an
**unattended, looping supervisor** against git repositories.

It exists to replace hardcoded per-project agent rigs. Its defining property is
that **nothing in it assumes a language, a framework, a directory layout, or a
project name.** A job declares a repo; autodev detects the rest.

It is *not* an AI coding tool. It does not write code. It spawns cline and
supervises it.

## Repository map

| Path | Purpose | Read it when |
|---|---|---|
| [`AGENTS.md`](AGENTS.md) | **Authoritative context for agents and humans changing this code.** Invariants, config schema, exit-code contract, known limitations, pre-commit checklist. | **Always, before editing anything.** |
| [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) | Symptom → cause → fix for users. | Something is broken at runtime. |
| `install.sh` | POSIX `sh` installer. No sudo. | Changing install behaviour. |
| `lib/common.sh` | All shared logic. Every command sources it. | Changing detection, job loading, or task labels. |
| `bin/autodev-*` | The commands. | Changing behaviour. |
| `VERSION` | Single line, bumped with behaviour changes. | Releasing. |

If you are an agent about to modify this repository: **`AGENTS.md` is not
optional.** It records the safety invariants and the deliberate limitations, so
you do not "fix" something that is broken on purpose.

## 2. The one thing you must not break

> **Exactly one agent process may ever have its working directory inside a given
> repository.**

Two agents in one working tree concurrently edit and commit the same files.
They will corrupt each other's history, and the damage is silent. This is a hard
invariant, not a tunable preference, and not something to "improve".

It is enforced in `cmd_start` (`bin/autodev-daemon`) in two layers:

1. **Repo lock** — `$AUTODEV_STATE/.repo-locks/<mangled-path>/owner` names the
   owning job. Refuses if that owner has a live pidfile.
2. **Live process scan** — `ad_agent_count "$REPO"` walks real processes and
   counts any agent whose `/proc/<pid>/cwd` is the repo. This catches an agent
   left behind by a *different* supervisor, or started by hand, which the lock
   file alone cannot see.

**Layer 2 exists because layer 1 was insufficient in practice.** If you refactor
`cmd_start`, keep both. Do not replace the process scan with a lock-file check
"because it is simpler" — that reopens a bug that caused real corruption.

## 3. Layout

```
install.sh              POSIX sh installer (no sudo, no root)
VERSION                 single line, e.g. 1.0.0

## 4. The library loader (portability contract)

Each command in `bin/` begins with an identical `_ad_libdir()` block that locates
`lib/common.sh`. Search order:

1. `$AUTODEV_LIB`
2. `~/.local/lib/autodev`, `~/lib/autodev`
3. `/usr/local/lib/autodev`, `/usr/lib/autodev`, `/opt/autodev/lib`
4. relative to the script: `../lib/autodev`, `../lib`, `./lib`

Step 4 is what lets a bare `git clone` work without installing. **Keep the block
byte-identical across all six commands.** If you must change it, change all six
and test all three install modes (checkout, `curl | sh`, `--prefix`).

## 5. Configuration schema

Job files: `$AUTODEV_CONFIG/jobs/<name>.conf` (`.env` is also accepted for
backwards compatibility). Sourced as shell, so it must live in a user-owned dir.

| Key | Required | Meaning |
|---|---|---|
| `JOB_REPO` | **yes** | absolute path to the working tree |
| `PROMPT` / `PROMPT_TEXT` | **yes** | prompt file path, or inline text |
| `PROMPT_CONTINUE` | no | shorter prompt used from the 2nd run onward |
| `JOB_NAME` | no | label; defaults to the file name |
| `JOB_AGENT` | no | agent binary (default `cline`) |
| `JOB_MODEL` / `JOB_THINKING` / `JOB_TIMEOUT` | no | per-job overrides |
| `JOB_TASKFILE` / `JOB_TASK_RE` | no | **cosmetic only** — shown in status |
| `JOB_DONE_CMD` | no | exit 0 ⇒ queue drained, stop looping |

Only `JOB_REPO` and a prompt are required. A job with neither is invalid; the
supervisor logs `ERROR: no PROMPT/PROMPT_TEXT` and backs off rather than
crash-looping.

### Environment variables (all optional)

| Var | Default | Effect |
|---|---|---|
| `AUTODEV_CONFIG` | `~/.config/autodev` | config root |
| `AUTODEV_STATE` | `~/.local/state/autodev` | runtime state root |
| `AUTODEV_LIB` | — | explicit `common.sh` location |
| `AUTODEV_AGENT_CMD` | `cline` | default agent binary |
| `AUTODEV_MODEL` | `stealth/space-bunny-alpha` | model id |
| `AUTODEV_THINKING` | `xhigh` | reasoning effort |
| `AUTODEV_TIMEOUT` | `7200` | seconds per run |
| `AUTODEV_COOLDOWN` | `90` | seconds between runs |
| `AUTODEV_MAX_BACKOFF` | `900` | backoff ceiling |
| `AUTODEV_SLOTS` | `2` | concurrent agents |
| `AUTODEV_POLL` | `60` | scheduler poll seconds |
| `AUTODEV_KEEP_RUN_LOGS` | `5` | transcripts kept per job |
| `AUTODEV_MIN_FREE_MB` | `1024` | refuse to start below this free disk |
| `AUTODEV_RAW` | GitHub raw base | installer's download base |
| `AUTODEV_PREFIX` | `~/.local` | installer's prefix |

## 6. Exit codes — a public contract

`autodev-status` is designed to be consumed by monitoring:

| Code | Meaning |
|---|---|
| `0` | everything idle/ok |
| `1` | at least one agent running |
| `2` | a supervisor CRASHED — work is **not** happening |

**`0` and `1` are both normal, healthy states.** Only `2` is an alarm. Do not
"fix" idle into a failure — on a small box most queued jobs are legitimately idle
at any moment, and reporting that as a failure cried wolf.

`autodev-queue-done`: `0` drained, `1` work remains, `2` cannot tell. `2` is
fail-safe: the supervisor keeps going, because a false "done" silently abandons
a project.

## 7. Session continuity — what it really does

**Cline cannot resume a session unattended.** This was tested, not assumed.
`cline --id <session-id>` exists ("Resume an existing session by ID") but always
forces interactive mode:

| Invocation | Result |
|---|---|
| `--id <id> --json "<prompt>"` | `JSON output mode requires a prompt argument or piped stdin (interactive mode is unsupported)` |
| `--id <id> --json` + prompt on stdin | same refusal |
| `--id <id> "<prompt>"` (no `--json`) | `interactive mode requires a TTY (stdin/stdout must both be terminals)` |

The running hub (`--cline-hub-daemon`) exposes no session-continuation API —
`/hub`, `/hub/sessions`, `/hub/api/sessions`, `/hub/openapi.json` all return
404 — and `cline history` offers only `delete`, `update`, `export`. There is no
`continue` subcommand.

**Therefore every supervised run is necessarily a cold session.** Do not add a
`cline schedule` or `--id` integration hoping to change this.

Given that, autodev attacks the *cost* of a cold start instead:

1. **`PROMPT_CONTINUE`** — the first run of a job uses `PROMPT`, which does a
   full orientation. Every later run uses `PROMPT_CONTINUE`, which forbids
   re-reading the project's documentation and points the agent at its hand-off
   files instead. The prompt text is barely smaller; **the saving is in the
   document reads the agent no longer performs**, which is where the tokens go.
2. **Carried summary** — `ad_capture_summary` pulls the closing `done` event's
   text out of the finished run's transcript and `ad_continue_prompt` appends it
   to the next run's prompt. The agent already wrote that summary; reusing it is
   free.

Measured on a real job: 6 of 8 run logs contain a `done` event and yield a
usable summary (~2KB). The 2 that do not were killed mid-run, so no summary
exists — extraction correctly returns failure and the run simply gets the plain
continuation prompt.

### Warm/cold state

- `$STATE/coldstart.done` — written after **any** finished run, success or not.
  A failed run still learned things; its retry should not re-orient from zero.
- `$STATE/last-summary` — the captured closing text.

Delete `coldstart.done` to force the next run to do a full orientation.

### Honest limits of this design

- The summary is the agent's **own words** and is injected as a *record*, not an
  instruction. The continuation prompt says so explicitly, because a stale or
  mistaken summary must not silently steer the next session.
- `ad_capture_summary` uses `grep -o '"text":"[^"]*"'`, so a summary containing
  an escaped quote is truncated at that quote. It degrades to a shorter summary,
  never to a corrupt one. Do not "fix" this with a JSON parser dependency.
- Streaming `content_start` deltas are **not** reassembled — on a long run those
  are the entire transcript, and rebuilding them in shell would be slow and
  fragile.

## 8. How the supervisor loop works

`__run` in `bin/autodev-daemon`, once per iteration:

1. If `STOP` flag exists → exit.
2. If `JOB_DONE_CMD` exits 0 → write `DRAINED`, exit permanently.
3. If free disk `< MIN_FREE_MB` → heartbeat, sleep 300s, **do not start a run**.
4. Prune run logs to `KEEP_RUN_LOGS`.
5. Choose the prompt: `PROMPT_CONTINUE` if the job is warm and one is
   configured, otherwise `PROMPT`.
6. Write heartbeat, then spawn the agent as a background child under `timeout`.
7. Poll every 20s: refresh heartbeat, honour a `STOP` flag that appears.
8. On exit: capture the closing summary, mark the job warm. `rc==0` resets
   backoff to `COOLDOWN`; failure doubles backoff up to `MAX_BACKOFF`.
9. 8 consecutive failures → circuit breaker, halt the job.

The agent is invoked exactly as:

```sh
cd "$REPO" && timeout --signal=TERM --kill-after=120 "$TIMEOUT" \
  "$AGENT_CMD" --auto-approve true --model "$MODEL" --thinking "$THINKING" \
  --timeout "$agent_timeout" --json "$prompt"
```

`agent_timeout` is `TIMEOUT - 120`, **clamped to a minimum of 1**. The 120s
difference lets the supervisor's `TERM` land before the outer `timeout` fires.
A negative `--timeout` was a real bug; the clamp is load-bearing.

### autodev does NOT use `cline schedule`

There is no `cline schedule` call anywhere in this codebase, and there must
never be one. Cline's `schedule` subsystem is unreliable (it queues runs that
never dispatch). Continuity here comes **solely** from `autodev-daemon` and
`autodev-scheduler`. If you are tempted to add a schedule integration, do not.

## 9. Process detection

```sh
ad_agent_comm()   # basename of $AGENT_CMD prefixed with "."  -> cline becomes ".cline"
ad_agent_pids()   # pgrep -f -- "--auto-approve", filtered by /proc/<pid>/comm, then by cwd
```

## 10. Known limitations — read before "fixing" anything

These are real and deliberate. Each has a reason.

1. **Linux-only.** Uses `/proc`, `readlink /proc/*/cwd`, `pgrep -f`, `flock`.
   It will not work on macOS or BSD. Fixing this means replacing `/proc`
   traversal, not adding a guard.
2. **Task label is best-effort and cosmetic.** `ad_task_label` tries an explicit
   `JOB_TASK_RE`, then several state-file shapes, then the first non-terminal
   queue heading, then the dirty-file count, then `unspecified`. It never blocks
   a run. A repo with an unusual layout legitimately shows `unspecified` —
   that is correct behaviour, not a bug to chase.
3. **Stack detection is heuristic.** `autodev-add` recognises Rust, PHP/Laravel,
   Node, Python, Go, Make, and falls back to `generic`. It inspects filenames
   only (`Cargo.toml`, `composer.json`, …). It does not parse manifests, and a
   polyglot repo matches the first branch in file order.
4. **No agent-output parsing.** autodev never reads what the agent decided. It
   supervises a process; it does not understand the work.
5. **`JOB_SETUP` is detected but not executed.** `autodev-add` computes a setup
   line and emits it only as a comment in the job file. Detected verify commands
   are likewise comments — the generated *prompt* embeds them as text for the
   agent to run, nothing more. Do not wire these into the supervisor; doing so
   would run unverified shell from a heuristic into every job.
6. **Scheduler `flock` must not be inherited.** `start_job` closes fd 9 (`9>&-`)
   when spawning a daemon. Without it the child holds the scheduler's lock for
   its whole life and the scheduler can never be restarted.
7. **Pidfile cleanup is conditional.** The scheduler only removes its pidfile if
   it still contains its own `$$`. A plain `rm` races with a restarting
   successor and orphans a live scheduler.
8. **Session continuity is a mitigation, not a fix.** Cline cannot resume a
   session unattended (see §7), so autodev reduces cold-start cost instead. The
   carried summary is the agent's own text and may be stale, truncated at an
   escaped quote, or absent entirely. It is advisory. Do not let any decision
   depend on it, and do not describe it to users as "session resume".

## 11. Before you commit

```sh
sh -n install.sh                      # POSIX sh
for f in bin/* lib/common.sh; do bash -n "$f"; done
```

Then, in a **throwaway `HOME`** so you never disturb a running machine:

```sh
export HOME=$(mktemp -d)/h && mkdir -p "$HOME"
./install.sh                          # from the checkout
./install.sh --prefix /tmp/sysinst --no-config
./install.sh --uninstall
PATH="$HOME/.local/bin:$PATH" autodev-daemon list   # must print a header, exit 0
```

And test the network path, which the checkout path does not exercise:

```sh
(cd . && python3 -m http.server 8899 &) ; sleep 2
HOME=$HOME AUTODEV_RAW=http://127.0.0.1:8899 sh -c 'curl -fsSL "$AUTODEV_RAW/install.sh" | sh'
PATH="$HOME/.local/bin:$PATH" autodev-status
```

**Never test an installer or supervisor change against a `HOME` that has live
agents.** Starting a second agent in a repo that already has one is the exact
failure this project exists to prevent.

## 12. Rules for changing this codebase

- **Never weaken a safety check to make something pass.** No removing the
  process scan, no lowering the disk guard, no deleting a test.
- **Never invent behaviour in comments or docs.** If you cannot point at the line
  that does it, do not write it down.
- **Never fabricate verification.** If you did not run a command, do not report
  its result. Quote real output or say plainly that you could not run it.
- **POSIX `sh` for `install.sh`**; `bash` elsewhere (`local`, arrays). Each
  `bin/` command re-execs under bash if needed.
- **Keep the installer non-destructive.** It installs programs only. It must
  never overwrite `jobs/`, `prompts/` or `slots.conf`.
- Bump `VERSION` in the same change as a behaviour change.


Two deliberate details:

- **`comm`, not the full command line.** A supervised agent is three processes
  (`timeout` → runtime → `.cline`), and `timeout`'s argv embeds the agent's
  flags, so argv matching counts all three.
- **cwd filtering.** Agents are attributed to jobs by their working directory. A
  global scan would list every agent under every job.

The `.` prefix matters: cline's binary on disk is `.cline`, so `/proc/<pid>/comm`
is `.cline`, not `cline`.


lib/common.sh           sourced by every command; all shared logic lives here
bin/autodev-add         register a project; detects stack, writes job + prompt
bin/autodev-daemon      per-job supervisor loop
bin/autodev-scheduler   keeps N slots busy from a priority list
bin/autodev-status      one-shot verdict; exit 0/1/2
bin/autodev-pause       writes/clears a PAUSE marker
bin/autodev-resume      NOT A FILE — a symlink to autodev-pause
bin/autodev-stop        stop supervisor + orphaned agents, then verify
bin/autodev-queue-done  exit 0 when a queue is drained (used by JOB_DONE_CMD)
```

`autodev-resume` is created by `install.sh`, not tracked in git.
`bin/autodev-pause` derives its action from `${0##*/}` — that is what makes one
file serve both names. Do not "fix" this by adding a second script.
