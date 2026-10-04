# Troubleshooting

Symptoms, causes, fixes. Every command and path here is real and verified.

## `autodev: command not found`

The installer puts commands in `~/.local/bin`. If that is not on your `PATH`:

```sh
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc && source ~/.bashrc
```

Installed system-wide instead? Use `/usr/local/bin`.

## `autodev: cannot find lib/common.sh`

`lib/common.sh` is missing from every location the loader searches. Either the
install was interrupted, or it was copied without the `lib/` directory. Reinstall:

```sh
curl -fsSL https://raw.githubusercontent.com/aimonext/cline-autodev/main/install.sh | sh
```

If you keep it somewhere unusual, point at it: `export AUTODEV_LIB=/your/path`.

## `autodev-daemon start` says `REFUSING: N agent process(es) are already running`

**This is the safety interlock, working correctly.** An agent is already using
that repo. Two agents in one working tree corrupt each other's commits.

If you know the agent is legitimate and want the supervisor to take over, stop it
first:

```sh
autodev-stop <job>      # or, for a hand-started one:
kill <pid>
```

To confirm what is running where:

```sh
for p in $(pgrep -f -- '--auto-approve'); do
  [ "$(cat /proc/$p/comm)" = ".cline" ] && echo "$p -> $(readlink /proc/$p/cwd)"
done
```

## The agent runs forever and never commits

Check the heartbeat and the run log. A fresh heartbeat with no commit usually
means the agent is still working, not stuck.

```sh
cat ~/.local/state/autodev/<job>/heartbeat
autodev-daemon logs <job> 1     # tail of the last run transcript
```

## Runs fail with `No space left on device` (os error 28)

The disk filled. A full disk kills a build mid-flight and loses the work.

autodev now refuses to *start* a run below `AUTODEV_MIN_FREE_MB` (default 1024),
but an already-running build can still hit it. Free space:

```sh
df -h /
du -sh ~/.local/state/autodev/*/runs      # transcripts
du -sh /path/to/repo/target               # build cache
```

Run logs are capped at `AUTODEV_KEEP_RUN_LOGS` (default 5) per job. Build caches
are the usual culprit — `target/` (Rust) and `node_modules` are safe to delete and
regenerate.

## `autodev-scheduler start` says another scheduler holds the lock

Correct behaviour — a duplicate `start` would let two schedulers each fill a
slot and overshoot `AUTODEV_SLOTS`. If you are sure none is running:

```sh
pgrep -af 'autodev-scheduler __loop'
```

A stale `scheduler.lock` is harmless: `flock` is advisory and released when the
holder exits.

## A job shows `DRAINED` but I want it back

```sh
rm ~/.local/state/autodev/<job>/DRAINED
autodev-daemon start <job>
```

## `task: unspecified` in status

The repo has no task file autodev recognises. This is **cosmetic** — it does not
affect whether runs start. Point it at your own file:

```sh
JOB_TASKFILE=docs/TASKS.md
JOB_TASK_RE='^## T[0-9]+'
```

Queue-shaped files get smarter handling automatically: autodev reports the first
task that is *not* already `DONE`.

## The supervisor exits immediately and says nothing

Check the supervisor log — it is separate from the run transcripts:

```sh
tail -20 ~/.local/state/autodev/<job>/supervisor.log
```

Common causes: `cline` not on `PATH`, the repo directory no longer exists, or no
`PROMPT`/`PROMPT_TEXT` in the job file.

## Nothing runs even though the scheduler is up

The job may be paused, or not listed in the rotation:

```sh
autodev-scheduler status     # shows queued / running / paused / DONE per job
autodev-resume <job>         # clear a pause
```

Only job names listed in `~/.config/autodev/slots.conf` are ever started. Adding
a job to `jobs/` is not enough — `autodev-add` does both, but if you copied a
`.conf` by hand, add the name to `slots.conf` too.

## Report a bug

Include the output of:

```sh
autodev-status
autodev-daemon status <job>
tail -30 ~/.local/state/autodev/<job>/supervisor.log
cat VERSION
```
