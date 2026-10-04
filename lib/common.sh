#!/usr/bin/env bash
# autodev-common.sh — shared helpers for every autodev-* command.
#
# Design rule: NOTHING in here may assume a language, a directory layout, or a
# project called "agos". A job declares its own repo, and the helpers DETECT
# what kind of project it is. Detection is best-effort and always overridable
# from the job file — a wrong guess must never stop work.

# ---------------------------------------------------------------- locations
# Overridable so autodev can be pointed at a test root, and so a user with a
# different XDG layout is not forced to symlink.
: "${AUTODEV_CONFIG:=$HOME/.config/autodev}"
: "${AUTODEV_STATE:=$HOME/.local/state/autodev}"
JOBS_DIR="$AUTODEV_CONFIG/jobs"
PROMPTS_DIR="$AUTODEV_CONFIG/prompts"
SLOTS_CONF="$AUTODEV_CONFIG/slots.conf"

# ---------------------------------------------------------------- tunables
# Generic defaults. Override globally by exporting, or per-job in the job file.
AGENT_CMD="${AUTODEV_AGENT_CMD:-cline}"
MODEL="${AUTODEV_MODEL:-stealth/space-bunny-alpha}"
THINKING="${AUTODEV_THINKING:-xhigh}"
TIMEOUT="${AUTODEV_TIMEOUT:-7200}"
COOLDOWN="${AUTODEV_COOLDOWN:-90}"
MAX_BACKOFF="${AUTODEV_MAX_BACKOFF:-900}"
MAX_SLOTS="${AUTODEV_SLOTS:-2}"
POLL="${AUTODEV_POLL:-60}"
# Keep only N run transcripts per job. Without this, JSON transcripts grow
# unbounded and fill the disk — which is exactly what happened here.
KEEP_RUN_LOGS="${AUTODEV_KEEP_RUN_LOGS:-5}"
# Refuse to start a run when free disk is below this (MB). A full disk kills
# the agent mid-build with ENOSPC and loses the work in progress.
MIN_FREE_MB="${AUTODEV_MIN_FREE_MB:-1024}"

# Toolchains are NOT assumed. A Rust project's cargo is frequently installed
# but absent from the default PATH, so add it only if it actually exists —
# prepending a directory unconditionally would be an assumption about the box.
[ -d "$HOME/.cargo/bin" ] && PATH="$HOME/.cargo/bin:$PATH"
[ -d "$HOME/bin" ] && PATH="$HOME/bin:$PATH"
export PATH

# ---------------------------------------------------------------- utilities
ad_log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$1"; }

ad_die() { printf 'autodev: %s\n' "$1" >&2; exit "${2:-1}"; }

# Free space on the filesystem holding $1, in MB.
ad_free_mb() { df -Pm "$1" 2>/dev/null | awk 'NR==2{print $4}'; }

# True when there is room to work. Returns 0 = ok, 1 = too full.
ad_disk_ok() {
  local free; free=$(ad_free_mb "${1:-$HOME}")
  [ -n "$free" ] || return 0            # df failed; do not block work on a guess
  [ "$free" -ge "$MIN_FREE_MB" ]
}

# Keep only the newest KEEP_RUN_LOGS transcripts in a run-log dir.
ad_prune_logs() {
  local dir="$1" keep="${2:-$KEEP_RUN_LOGS}"
  [ -d "$dir" ] || return 0
  ls -1t "$dir"/*.log 2>/dev/null | tail -n +"$((keep + 1))" | while read -r f; do
    rm -f "$f"
  done
}

# ---------------------------------------------------------------- job loading
# A job file is a shell fragment of KEY=value lines. It is sourced, so it must
# live in a config dir the user owns.
ad_load_job() {
  local name="$1" f="$JOBS_DIR/$1.conf"
  [ -f "$f" ] || f="$JOBS_DIR/$1.env"          # accept the legacy extension
  [ -f "$f" ] || return 1
  JOB_FILE="$f"
  JOB_NAME="$name"
  unset JOB_REPO PROMPT JOB_AGENT JOB_MODEL JOB_THINKING JOB_TIMEOUT
  unset JOB_TASKFILE JOB_TASK_RE JOB_DONE_CMD JOB_STACK
  # shellcheck disable=SC1090
  . "$f"
  REPO="${JOB_REPO:-}"
  STATE="$AUTODEV_STATE/$name"
  PIDFILE="$STATE/daemon.pid"
  HEARTBEAT="$STATE/heartbeat"
  STOPFLAG="$STATE/STOP"
  RUNLOG="$STATE/runs"
  REPO_LOCK="$AUTODEV_STATE/.repo-locks/$(printf '%s' "$REPO" | tr '/' '_').lock"
  # Per-job overrides of the global defaults.
  [ -n "${JOB_AGENT:-}" ]    && AGENT_CMD="$JOB_AGENT"
  [ -n "${JOB_MODEL:-}" ]    && MODEL="$JOB_MODEL"
  [ -n "${JOB_THINKING:-}" ] && THINKING="$JOB_THINKING"
  [ -n "${JOB_TIMEOUT:-}" ]  && TIMEOUT="$JOB_TIMEOUT"
  return 0
}

ad_list_jobs() {
  mkdir -p "$JOBS_DIR"
  local f n
  for f in "$JOBS_DIR"/*.conf "$JOBS_DIR"/*.env; do
    [ -e "$f" ] || continue
    n=$(basename "$f"); n="${n%.*}"
    echo "$n"
  done | sort -u
}

ad_is_running() {
  [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null
}

# ---------------------------------------------------------------- processes
# Find the real agent process for a repo. A supervised agent is a process
# tree (timeout -> runtime -> cli), so matching the full command line would
# count all three; `timeout`'s argv also embeds the agent's flags.
#
# AGENT_COMM is the executable name of the leaf process. It is derived from the
# configured agent command so this works for any agent, not just cline.
ad_agent_comm() {
  local cmd="${AGENT_CMD##*/}"
  printf '.%s' "$cmd"
}

ad_agent_pids() {
  local repo="${1:-}" p cwd comm
  comm=$(ad_agent_comm)
  for p in $(pgrep -f -- "--auto-approve" 2>/dev/null); do
    [ "$(cat "/proc/$p/comm" 2>/dev/null)" = "$comm" ] || continue
    if [ -n "$repo" ]; then
      cwd=$(readlink "/proc/$p/cwd" 2>/dev/null)
      [ "$cwd" = "$repo" ] || continue
    fi
    echo "$p"
  done
}

ad_agent_count() { local n; n=$(ad_agent_pids "${1:-}" | wc -w); echo "${n:-0}"; }

# ---------------------------------------------------------------- task display
# Best-effort human label for "what is this job working on right now".
# Purely cosmetic: it never affects whether a run starts. The old implementation
# hardcoded one repo's Markdown shape and reported "unknown" for every other
# project — which made a healthy run indistinguishable from a wedged one.
ad_task_label() {
  local repo="$1" tf="$2" re="$3" line
  # 1. An explicit pattern from the job file wins.
  if [ -n "$tf" ] && [ -f "$repo/$tf" ]; then
    # Prefer a concrete "Implement T123" over a vaguer "Current phase:" line,
    # even when the phase line comes first in the file: a task id is the more
    # useful answer, and grep -m1 alone would take whichever appears first.
    line=$(grep -m1 -E '^[[:space:]]*(\*\*)?Implement[[:space:]]+\**T[0-9]+' "$repo/$tf" 2>/dev/null)
    [ -n "$line" ] || { [ -n "$re" ] && line=$(grep -m1 -E "$re" "$repo/$tf" 2>/dev/null); }
    if [ -n "$line" ]; then
      printf '%s' "$line" | sed 's/\*\*//g; s/^[#[:space:]]*//' | cut -c1-90
      return 0
    fi
  fi
  # 2. A state/progress file that names the CURRENT action. We require a task id
  #    on the line, so a bare heading like "## Current State" is not mistaken
  #    for an answer.
  local f
  for f in .agent/progress/STATE.md .agent/progress/CURRENT_STATE.md \
           AGENT_STATE.md STATE.md docs/STATE.md .agent/IMPLEMENTATION.md; do
    [ -f "$repo/$f" ] || continue
    line=$(grep -m1 -iE '(current|next)[[:space:]]+(task|action|step|phase)[^A-Za-z0-9]{0,4}(T|P|ENV|[0-9])' \
           "$repo/$f" 2>/dev/null | head -1)
    [ -n "$line" ] || line=$(grep -m1 -E '^[[:space:]]*Implement[[:space:]]+\**T[0-9]+' "$repo/$f" 2>/dev/null)
    [ -n "$line" ] || continue
    printf '%s' "$line" | sed 's/\*\*//g; s/^[#[:space:]]*//' | cut -c1-90
    return 0
  done
  # 3. A queue file: report the FIRST task that is not already terminal. Showing
  #    the first heading regardless of status reports work that is long done.
  for f in .agent/progress/QUEUE.md .agent/progress/TASKS.md \
           .agent/progress/TASK_INDEX.md .agent/progress/TASK_QUEUE.md \
           TASKS.md docs/TASKS.md; do
    [ -f "$repo/$f" ] || continue
    line=$(awk '
      /^#+[[:space:]]*[A-Za-z]*-?[0-9]+/ { if (!found && !term) { print; found=1 } ; inhdr=1; term=0; next }
      inhdr && /DONE|SKIPPED|COMPLETE/ { term=1 }
      END { }
    ' "$repo/$f" 2>/dev/null | head -1)
    [ -n "$line" ] || continue
    printf '%s' "$line" | sed 's/\*\*//g; s/^[#[:space:]]*//' | cut -c1-90
    return 0
  done
  # 4. A dirty working tree is itself progress worth reporting.
  if [ -d "$repo/.git" ]; then
    line=$(cd "$repo" && git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    [ "${line:-0}" != "0" ] && { printf '%s file(s) changed, uncommitted' "$line"; return 0; }
  fi
  printf 'unspecified'
}
