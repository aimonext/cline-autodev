# autodev — universal autonomous-agent supervision

Runs unattended coding agents against **any** repository, in **any** language.
Nothing here assumes Rust, AGOS, or any particular directory layout.

## Install

One line, on any machine that has [cline](https://github.com/cline/cline) on `PATH`:

```sh
curl -fsSL https://raw.githubusercontent.com/aimonext/cline-autodev/main/install.sh | sh
```

No `sudo`, no root — everything lands in `~/.local`. To install system-wide:

```sh
curl -fsSL https://raw.githubusercontent.com/aimonext/cline-autodev/main/install.sh | sh -s -- --prefix /usr/local
```

Prefer to clone it? `git clone <repo> && cd autodev && ./install.sh` works too —
the installer detects a checkout and skips the network entirely.

Uninstall (keeps your jobs and config):

```sh
./install.sh --uninstall
```

### Requirements

- **Linux** (uses `/proc`, `pgrep -f`, `flock`). Not macOS/BSD — see
  [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).
- `bash` — the commands use `local` and arrays
- [`cline`](https://github.com/cline/cline) on `PATH`
- `git`
- No root or `sudo` required

## Commands

| Command | Purpose |
|---|---|
| `autodev-add <path>` | Register any project. Detects the stack and writes a job + prompt. |
| `autodev-daemon <job>` | Supervise one job in a loop (`list`/`start`/`stop`/`status`/`logs`/`tail`). |
| `autodev-scheduler` | Keep N slots busy from a priority list. |
| `autodev-status` | One-shot verdict on everything. Exit 0 idle / 1 running / 2 crashed. |
| `autodev-pause <job>` | Take a job out of rotation (does not stop a running agent). |
| `autodev-resume <job>` | Put it back. |
| `autodev-stop <job>` | Stop supervisor **and** orphaned agents, then verify. |
| `autodev-queue-done` | Exit 0 when a task queue is drained. Used by `JOB_DONE_CMD`. |

`autodev-status` exit codes are a contract for monitoring: **0 idle, 1 running,
2 crashed**. 0 and 1 are both healthy; only 2 means work has stopped.

## Quick start

```sh
autodev-add ~/projects/my-new-project     # any language
autodev-daemon start my-new-project
autodev-status
```

`autodev-add` detects: Rust, PHP/Laravel, Node, Python, Go, Make, or falls back
to `generic`. It writes a prompt containing that stack's real verify commands.

## Session continuity

Cline **cannot resume a session unattended**. `cline --id <session-id>` exists
but always forces interactive mode and refuses to run without a TTY, the hub
exposes no continuation API, and `cline history` has no `continue` subcommand.
So every supervised run is a cold session.

autodev reduces the cost of that cold start instead:

- **First run** uses `PROMPT` and does a full orientation.
- **Every later run** uses `PROMPT_CONTINUE`, which tells the agent it has no
  memory, forbids re-reading the project's documentation, and points it at its
  hand-off files.
- The previous run's **closing summary** is extracted from its transcript and
  appended to the next prompt. The agent already wrote it; reusing it is free.

State lives in the job's state dir:

```
coldstart.done     written after any finished run; delete to force full orientation
last-summary       the carried closing summary
```

Measured effect is in the *document reads skipped*, not prompt size — the two
prompts are nearly the same length. The carried summary is advisory: it is the
agent's own words and may be stale, truncated, or missing when a run was killed.

See [AGENTS.md §7](AGENTS.md) for the full analysis and its limits.

## Safety

- **One agent per repository, enforced.** `start` refuses when any agent process
  already has that repo as its working directory — including one left by a
  different supervisor. Two agents in one tree corrupt each other's commits.
- **Disk guard.** A run will not start when free space is below
  `AUTODEV_MIN_FREE_MB` (default 1024). A full disk kills a build mid-flight.
- **Bounded logs.** Only `AUTODEV_KEEP_RUN_LOGS` (default 5) run transcripts are
  kept per job.
- **Graceful drain.** When `JOB_DONE_CMD` reports the queue empty, the supervisor
  exits permanently instead of waking forever.
- **Circuit breaker.** 8 consecutive failures halts a job.

## Layout

```
~/.config/autodev/jobs/<name>.conf     job definitions (plain KEY=value)
~/.config/autodev/prompts/<name>.md    generated prompts
~/.config/autodev/slots.conf           priority order, highest first
~/.local/state/autodev/<name>/         pidfile, heartbeat, run logs
~/.local/lib/autodev/common.sh         shared helpers
```

## Job file

Only `JOB_REPO` and a prompt are required. Everything else is optional:

```sh
JOB_NAME=myproject
JOB_REPO=/home/you/projects/myproject
PROMPT=~/.config/autodev/prompts/myproject.md   # or PROMPT_TEXT='inline...'
JOB_AGENT=cline          # any agent binary
JOB_MODEL=...            # defaults to $AUTODEV_MODEL
JOB_THINKING=xhigh
JOB_TIMEOUT=7200
JOB_TASKFILE=.agent/progress/QUEUE.md   # cosmetic: shown in status
JOB_TASK_RE='^...'                       # optional override
JOB_DONE_CMD='autodev-queue-done paired "$REPO/TASKS.md" "^#+ T[0-9]+" DONE'
```

## Environment

| Var | Default | Meaning |
|---|---|---|
| `AUTODEV_CONFIG` | `~/.config/autodev` | config root |
| `AUTODEV_STATE` | `~/.local/state/autodev` | runtime state root |
| `AUTODEV_SLOTS` | `2` | concurrent agents |
| `AUTODEV_TIMEOUT` | `7200` | seconds per run |
| `AUTODEV_COOLDOWN` | `90` | seconds between runs |
| `AUTODEV_MIN_FREE_MB` | `1024` | refuse to start below this free disk |
| `AUTODEV_KEEP_RUN_LOGS` | `5` | run transcripts kept per job |

## Safety properties

- **One agent per repository, always.** `start` refuses when any agent process
  has its cwd in that repo — including one left behind by a *different*
  supervisor. Two agents in one tree corrupt each other's commits.
- **Disk guard.** A run does not start when free space is under the threshold;
  a full disk kills an agent mid-build with ENOSPC and loses its work.
- **Bounded logs.** Only N run transcripts are kept per job.
- **Graceful drain.** When `JOB_DONE_CMD` reports the queue empty, the
  supervisor exits permanently instead of waking forever.
- **Circuit breaker.** 8 consecutive failures halts a job.

## Migrating from agos-*

The old `agos-*` scripts are untouched and still work. To switch a job over:

```sh
autodev-add ~/projects/agos/agos-tools --name agos-tools
# carry across the hand-tuned done-check:
grep JOB_DONE_CMD ~/.config/agos/jobs/agos-tools.env
#   -> append (single-quoted) to ~/.config/autodev/jobs/agos-tools.conf
autodev-daemon start agos-tools
```

Both systems share the one-agent-per-repo rule, so stop the old supervisor for
a repo before starting the new one.

## Contributing

Read [`AGENTS.md`](AGENTS.md) first — it documents the safety invariants, the
exit-code contract, and the limitations that are deliberate. It also has the
pre-commit checklist (syntax gate plus a throwaway-`$HOME` install test).

## License

MIT — see [LICENSE](LICENSE).
