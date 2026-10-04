#!/usr/bin/env sh
# autodev installer — installs the autodev-* commands for the current user.
#
#   curl -fsSL https://raw.githubusercontent.com/USER/autodev/main/install.sh | sh
#
# Or from a checkout:  ./install.sh
#
# Design notes:
#  - POSIX sh, so it runs on dash/busybox as well as bash.
#  - No sudo and no root: everything lands under $HOME. A system-wide install
#    is possible but never assumed.
#  - Idempotent: re-running upgrades in place.
#  - Never overwrites your jobs, prompts or slots.conf — only the programs.

set -eu

VERSION="1.0.0"
REPO_URL="${AUTODEV_REPO:-https://github.com/USER/autodev}"
RAW_URL="${AUTODEV_RAW:-https://raw.githubusercontent.com/USER/autodev/main}"

PREFIX="${AUTODEV_PREFIX:-$HOME/.local}"
BINDIR="$PREFIX/bin"
LIBDIR="$PREFIX/lib/autodev"
CONFDIR="${AUTODEV_CONFIG:-$HOME/.config/autodev}"

say()   { printf '%s\n' "$*"; }
warn()  { printf 'warning: %s\n' "$*" >&2; }
die()   { printf 'error: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
autodev installer $VERSION

  curl -fsSL $RAW_URL/install.sh | sh          # install
  ./install.sh --uninstall                     # remove programs (keeps config)
  ./install.sh --prefix /usr/local             # system-wide (needs write access)
  ./install.sh --no-config                     # skip creating config dirs

Options:
  --prefix DIR     install root (default: \$HOME/.local)
  --bindir DIR     command dir   (default: PREFIX/bin)
  --uninstall      remove installed files, keep your config
  --no-config      do not create ~/.config/autodev
  -h, --help       this message
EOF
}

UNINSTALL=0
MAKE_CONFIG=1
while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) PREFIX="${2:?--prefix needs a value}"; BINDIR="$PREFIX/bin"; LIBDIR="$PREFIX/lib/autodev"; shift 2 ;;
    --bindir) BINDIR="${2:?--bindir needs a value}"; shift 2 ;;
    --uninstall) UNINSTALL=1; shift ;;
    --no-config) MAKE_CONFIG=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

COMMANDS="autodev-add autodev-daemon autodev-pause autodev-resume autodev-scheduler autodev-status autodev-stop autodev-queue-done"

# ---------------------------------------------------------------- uninstall
if [ "$UNINSTALL" -eq 1 ]; then
  for c in $COMMANDS; do rm -f "$BINDIR/$c"; done
  rm -f "$LIBDIR/common.sh"
  rmdir "$LIBDIR" 2>/dev/null || true
  say "autodev removed from $BINDIR and $LIBDIR"
  say "Your jobs/prompts in $CONFDIR were kept. Delete that too for a clean slate."
  exit 0
fi


# ---------------------------------------------------------------- source dir
# Prefer a real checkout (running ./install.sh, or a cloned repo); otherwise
# fetch each file from the raw URL. Fetching one file at a time is what makes
# this work from a `curl | sh` pipe, where no checkout exists on disk.
SRC=""
self_dir=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd || echo "")
if [ -n "$self_dir" ] && [ -f "$self_dir/lib/common.sh" ]; then
  SRC="$self_dir"
fi

fetch() {  # fetch <relative-path> <dest>
  if [ -n "$SRC" ]; then
    cp "$SRC/$1" "$2"
  else
    if command -v curl >/dev/null 2>&1; then
      curl -fsSL "$RAW_URL/$1" -o "$2" || die "download failed: $RAW_URL/$1"
    elif command -v wget >/dev/null 2>&1; then
      wget -qO "$2" "$RAW_URL/$1" || die "download failed: $RAW_URL/$1"
    else
      die "need curl or wget (or run ./install.sh from a checkout)"
    fi
  fi
}

# ---------------------------------------------------------------- install
say "autodev $VERSION installer"
if [ -n "$SRC" ]; then say "source: checkout at $SRC"; else say "source: $RAW_URL"; fi

mkdir -p "$BINDIR" "$LIBDIR" || die "cannot create $BINDIR / $LIBDIR (try --prefix elsewhere)"

tmp=$(mktemp -d 2>/dev/null || mktemp -d -t autodev) || die "mktemp failed"
trap 'rm -rf "$tmp"' EXIT INT TERM

say "installing shared library -> $LIBDIR"
fetch "lib/common.sh" "$tmp/common.sh"
# Refuse to install a truncated download: every command sources this file, so a
# partial fetch would break later with a baffling syntax error.
[ -s "$tmp/common.sh" ] || die "lib/common.sh is empty — download failed"
grep -q 'ad_load_job' "$tmp/common.sh" || die "lib/common.sh looks wrong (no ad_load_job) — download failed"
cp "$tmp/common.sh" "$LIBDIR/common.sh"
chmod 0644 "$LIBDIR/common.sh"

for c in $COMMANDS; do
  case "$c" in autodev-resume) continue ;; esac   # symlink, created below
  fetch "bin/$c" "$tmp/$c"
  [ -s "$tmp/$c" ] || die "bin/$c is empty — download failed"
  head -1 "$tmp/$c" | grep -q '^#!' || die "bin/$c has no shebang — download failed"
  cp "$tmp/$c" "$BINDIR/$c"
  chmod 0755 "$BINDIR/$c"
done

# resume is the same program as pause; it picks its action from $0.
ln -sf "autodev-pause" "$BINDIR/autodev-resume"

if [ "$MAKE_CONFIG" -eq 1 ]; then
  mkdir -p "$CONFDIR/jobs" "$CONFDIR/prompts"
  [ -f "$CONFDIR/slots.conf" ] || printf '# Priority order for autodev-scheduler. Highest first, one job per line.\n# Add jobs with: autodev-add /path/to/repo\n' > "$CONFDIR/slots.conf"
  if [ -n "$SRC" ] && [ -f "$SRC/README.md" ] && [ ! -f "$CONFDIR/README.md" ]; then
    cp "$SRC/README.md" "$CONFDIR/README.md"
  fi
fi

# ---------------------------------------------------------------- PATH hint
path_hint=""
case ":$PATH:" in
  *":$BINDIR:"*) ;;
  *) path_hint="$BINDIR" ;;
esac

# ---------------------------------------------------------------- verify
say ""
say "installed:"
for c in $COMMANDS; do
  [ -e "$BINDIR/$c" ] && say "  $BINDIR/$c"
done

if ! command -v cline >/dev/null 2>&1; then
  warn "cline not found on PATH. autodev needs it to run agents."
  warn "install cline, then run: autodev-daemon start <job>"
fi

say ""
if [ -n "$path_hint" ]; then
  say "NOTE: $BINDIR is not on your PATH. Add it with:"
  say ""
  say "    echo 'export PATH=\"$BINDIR:\$PATH\"' >> ~/.bashrc && source ~/.bashrc"
  say ""
fi

say "next steps:"
say "  autodev-add /path/to/your/project    # register any project"
say "  autodev-daemon start <job>           # run it"
say "  autodev-status                       # see everything"
say "  autodev-scheduler start              # auto-fill idle slots"
