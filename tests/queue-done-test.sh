#!/usr/bin/env bash
# tests/queue-done-test.sh — regression tests for autodev-queue-done.
#
#   ./tests/queue-done-test.sh
#
# These exist because a real drain-check bug shipped once already: paired mode
# treated ANY occurrence of a terminal token as "this task is finished", so a
# task that merely *mentioned* an earlier task as DONE was counted as complete.
# That undercounts work — and, in the worst case, reports a queue as fully
# drained while tasks remain, which makes the supervisor exit permanently and
# abandon the project.

set -u
DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
QD="$DIR/bin/autodev-queue-done"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
check() {  # check <desc> <expected-exit> <expected-grep-or-empty> <cmd...>
  local desc="$1" want="$2" pat="$3"; shift 3
  local out rc
  out=$("$@" 2>&1); rc=$?
  if [ "$rc" != "$want" ]; then
    printf 'FAIL  %s\n        exit=%s want=%s\n        out: %s\n' "$desc" "$rc" "$want" "$out"; fail=$((fail+1)); return
  fi
  if [ -n "$pat" ] && ! printf '%s' "$out" | grep -q "$pat"; then
    printf 'FAIL  %s\n        output did not match: %s\n        out: %s\n' "$desc" "$pat" "$out"; fail=$((fail+1)); return
  fi
  printf 'pass  %s\n' "$desc"; pass=$((pass+1))
}

# ---------------------------------------------------------------- the bug
cat > "$TMP/bug.md" <<'EOF'
### T001 — first
**Status:** DONE (2026-10-04)

### T002 — mentions a finished task
**Status:** TODO (next actionable) — T001 is DONE.

### T003 — third
**Status:** DONE (2026-10-04)
EOF
# T002 is NOT done, so 1 task remains. The old code reported 0 (fully drained).
check "paired: prose reference to a DONE task does not mark it complete" \
      1 "1 task" "$QD" paired "$TMP/bug.md" '^### T[0-9]+' DONE

# A queue whose only remaining task is the LAST one, and whose block mentions
# DONE, must NOT report drained. This is the abandon-the-project scenario.
cat > "$TMP/lastbug.md" <<'EOF'
### T001 — done
**Status:** DONE (2026-10-04)

### T002 — final task referencing the first
**Status:** TODO — T001 is DONE, so this is next.
EOF
check "paired: last task referencing DONE does not falsely drain the queue" \
      1 "1 task" "$QD" paired "$TMP/lastbug.md" '^### T[0-9]+' DONE

# ---------------------------------------------------------------- real shapes
cat > "$TMP/all_done.md" <<'EOF'
### T001 — a
**Status:** DONE (2026-10-04)

### T002 — b
**Status:** DONE (2026-10-05)
EOF
check "paired: genuinely drained queue reports 0" \
      0 "queue drained" "$QD" paired "$TMP/all_done.md" '^### T[0-9]+' DONE

cat > "$TMP/spacey.md" <<'EOF'
### T001 — a
**Status**: DONE (2026-10-04)

### T002 — b
**Status**: BLOCKED — waiting on T001
EOF
check "paired: '**Status**:' variant parsed; BLOCKED still counts as remaining" \
      1 "1 task" "$QD" paired "$TMP/spacey.md" '^### T[0-9]+' DONE

cat > "$TMP/skiptok.md" <<'EOF'
### T001 — a
**Status:** SKIPPED by decision

### T002 — b
**Status:** DONE
EOF
check "paired: multiple terminal tokens honoured" \
      0 "queue drained" "$QD" paired "$TMP/skiptok.md" '^### T[0-9]+' DONE SKIPPED

# No Status: line at all — fall back to a token at the start of a line.
cat > "$TMP/nostatus.md" <<'EOF'
### T001 — a
DONE (2026-10-04)

### T002 — b
See T001, which is DONE.
EOF
check "paired: without a Status line, a leading token counts" \
      1 "1 task" "$QD" paired "$TMP/nostatus.md" '^### T[0-9]+' DONE

# ---------------------------------------------------------------- other modes
cat > "$TMP/cb.md" <<'EOF'
- [x] one
- [ ] two
- [ ] three
EOF
check "checkbox: counts unchecked boxes" 1 "2 task" "$QD" checkbox "$TMP/cb.md"

cat > "$TMP/tbl.md" <<'EOF'
| ID | Status | Task |
|---|---|---|
| T-001 | DONE | a |
| T-002 | TODO | b |
| T-003 | IN_PROGRESS | c |
EOF
check "table: counts non-terminal statuses" 1 "2 task" "$QD" table "$TMP/tbl.md" TODO IN_PROGRESS

# ---------------------------------------------------------------- error paths
check "missing file is fail-safe (exit 2, not drained)" \
      2 "cannot read" "$QD" paired "$TMP/nope.md" '^### T[0-9]+' DONE
check "unknown mode is fail-safe (exit 2)" \
      2 "unknown mode" "$QD" bogus "$TMP/all_done.md"

# ---------------------------------------------------------------- result
printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
