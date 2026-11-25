#!/usr/bin/env bash
# Find the captain's exact words so Firstmate can hand them on unchanged.
#
# The Pi primary records every message the captain types into
# state/captain-words/ (.pi/extensions/fm-captain-words-capture.ts). Use this
# script to pick the message(s) a request or brief stems from, then pass the
# printed path to `fm-send.sh --captain-words-file` or
# `fm-brief.sh --captain-words-file`, which quote the words verbatim
# (bin/fm-captain-words-lib.sh owns the block format).
#
# Usage:
#   fm-captain-words.sh list [count]     newest first: number, UTC time, opening words
#   fm-captain-words.sh path [number]    path of message <number> (1 = newest, default 1)
#   fm-captain-words.sh show [number]    print message <number> exactly
#   fm-captain-words.sh bundle <number>...
#       write the chosen messages, oldest first and separated by one blank
#       line, to one file and print its path - for an ask the captain spread
#       over several messages
#
# Never retype the captain's words into a file by hand: a copy you typed is
# your retelling, which is exactly what this path exists to avoid. When no
# capture exists (another harness, capture off), say so in Firstmate's note
# instead of quoting.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DIR="$STATE/captain-words"

usage() { sed -n '12,21p' "$0" | sed 's/^# \{0,1\}//'; }

# Newest-first list of capture files, one path per line.
captures() {
  [ -d "$DIR" ] || return 0
  find "$DIR" -maxdepth 1 -type f -name '[0-9]*-[0-9][0-9].txt' 2>/dev/null | LC_ALL=C sort -r
}

nth() { # <number>
  local n=$1 p
  case "$n" in '' | *[!0-9]* | 0)
    echo "error: message number must be a positive integer: $n" >&2
    return 1
    ;;
  esac
  p=$(captures | sed -n "${n}p")
  [ -n "$p" ] || {
    echo "error: no captured captain message number $n in $DIR" >&2
    return 1
  }
  printf '%s\n' "$p"
}

stamp() { # <path> -> UTC time from the millisecond file name
  local base ms
  base=$(basename "$1")
  ms=${base%%-*}
  ms=$((10#$ms / 1000))
  date -u -d "@$ms" '+%Y-%m-%d %H:%M:%SZ' 2>/dev/null || date -u -r "$ms" '+%Y-%m-%d %H:%M:%SZ'
}

cmd=${1:-list}
[ $# -eq 0 ] || shift
case "$cmd" in
list)
  count=${1:-10}
  i=0
  captures | while IFS= read -r p; do
    i=$((i + 1))
    [ "$i" -le "$count" ] || break
    printf '%3d  %s  %s\n' "$i" "$(stamp "$p")" "$(tr '\n' ' ' <"$p" | cut -c1-90)"
  done
  ;;
path) nth "${1:-1}" ;;
show)
  p=$(nth "${1:-1}")
  cat "$p"
  ;;
bundle)
  [ $# -ge 1 ] || {
    echo "error: bundle needs at least one message number" >&2
    exit 1
  }
  paths=
  for n in "$@"; do
    p=$(nth "$n")
    paths="$paths$p"$'\n'
  done
  mkdir -p "$DIR/bundles"
  out="$DIR/bundles/$(date -u +%Y%m%dT%H%M%SZ)-$$.txt"
  first=1
  : >"$out"
  # Oldest first, the order the captain typed them.
  printf '%s' "$paths" | LC_ALL=C sort | while IFS= read -r p; do
    [ -n "$p" ] || continue
    if [ "$first" -eq 0 ]; then printf '\n\n' >>"$out"; fi
    cat "$p" >>"$out"
    first=0
  done
  printf '%s\n' "$out"
  ;;
-h | --help | help) usage ;;
*)
  echo "error: unknown command: $cmd" >&2
  usage >&2
  exit 1
  ;;
esac
