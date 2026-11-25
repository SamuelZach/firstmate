#!/usr/bin/env bash
# fm-captain-words-lib.sh - carry the captain's own words unchanged across hops.
#
# Firstmate rewrites the captain's ask when it routes work: a measured fleet
# sample kept the captain's message word for word in 3% of main -> secondmate
# requests and in none of the resulting worker briefs, and three quarters of the
# meaning changes were already present in the first hop. This library owns the
# one wire format that lets the exact words ride every hop instead:
#
#   ### Captain's words (verbatim)
#   > first line exactly as the captain typed it
#   >
#   > third line
#   <!-- fm-captain-words sha256=<hex of the exact words> -->
#
# The words are block-quoted so a captain line that begins with `#` or a fence
# never becomes a brief heading, and the trailing hash lets fm-spawn refuse a
# brief whose quoted words were edited after they were captured. Firstmate's
# reading of the words never goes inside the block: it belongs in the prose that
# follows it, in `## Firstmate spec`, or in a request's `### Firstmate's note`.
#
# On a marked secondmate request the from-firstmate marker and corr token are
# prefixed to the first line, so a heading line that starts with that marker
# and ends with the heading also opens a block.
#
# Rendering is idempotent across hops: rendering a file that already holds
# blocks re-renders the words of those blocks rather than quoting the quote, so
# a secondmate can pass its incoming inbox record straight to fm-brief.sh.
#
# Bash 3.2 safe: no mapfile, no associative arrays, no heredoc inside $(...).

FM_CAPTAIN_WORDS_HEADING="### Captain's words (verbatim)"

fm_captain_words_sha256() { # stdin -> hex
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    sha256sum | awk '{print $1}'
  fi
}

# Print how many captain-words blocks <file> holds (0 when none or no file).
fm_captain_words_count() { # <file>
  [ -f "$1" ] || {
    echo 0
    return 0
  }
  awk -v h="$FM_CAPTAIN_WORDS_HEADING" 'function ish(l, h) { return l == h || (index(l, "[fm-from-firstmate]") == 1 && length(l) > length(h) && substr(l, length(l) - length(h) + 1) == h) } ish($0, h) { n++ } END { print n + 0 }' "$1"
}

# Print the unquoted words of block <index> (1-based, default 1) of <file>,
# without a trailing newline. Returns 1 when the block is missing, 2 when it is
# malformed (a non-quote line before the hash trailer, or no trailer).
fm_captain_words_extract() { # <file> [index]
  local file=$1 want=${2:-1} out rc
  [ -f "$file" ] || return 1
  out=$(awk -v h="$FM_CAPTAIN_WORDS_HEADING" -v want="$want" '
    function ish(l, h) { return l == h || (index(l, "[fm-from-firstmate]") == 1 && length(l) > length(h) && substr(l, length(l) - length(h) + 1) == h) }
    BEGIN { n = 0; inside = 0; done = 0 }
    done { next }
    ish($0, h) { n++; if (n == want) { inside = 1; first = 1 } ; next }
    !inside { next }
    /^<!-- fm-captain-words sha256=[0-9a-f]+ -->$/ { done = 1; inside = 0; next }
    /^>/ {
      line = substr($0, 2)
      if (substr(line, 1, 1) == " ") line = substr(line, 2)
      if (!first) printf "\n"
      printf "%s", line
      first = 0
      next
    }
    { bad = 1; done = 1; inside = 0 }
    END {
      if (n < want) exit 1
      if (bad || !done) exit 2
    }
  ' "$file")
  rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  printf '%s' "$out"
}

# Print the hash recorded in the trailer of block <index> of <file>.
fm_captain_words_recorded_hash() { # <file> [index]
  awk -v h="$FM_CAPTAIN_WORDS_HEADING" -v want="${2:-1}" '
    function ish(l, h) { return l == h || (index(l, "[fm-from-firstmate]") == 1 && length(l) > length(h) && substr(l, length(l) - length(h) + 1) == h) }
    ish($0, h) { n++; next }
    n == want && /^<!-- fm-captain-words sha256=[0-9a-f]+ -->$/ {
      sub(/^<!-- fm-captain-words sha256=/, ""); sub(/ -->$/, ""); print; exit
    }
  ' "$1"
}

# Render one block from raw words given on stdin.
fm_captain_words_render_stdin() {
  local words hash
  words=$(cat)
  # Strip trailing newlines only; leading and inner bytes stay exactly as typed.
  if [ -z "$(printf '%s' "$words" | tr -d '[:space:]')" ]; then
    echo "error: captain's words are empty" >&2
    return 1
  fi
  hash=$(printf '%s' "$words" | fm_captain_words_sha256)
  printf '%s\n' "$FM_CAPTAIN_WORDS_HEADING"
  printf '%s\n' "$words" | awk '{ if ($0 == "") print ">"; else print "> " $0 }'
  printf '<!-- fm-captain-words sha256=%s -->\n' "$hash"
}

# Render the block(s) for <file>. A file that already carries blocks has each
# block's words re-rendered in order (so a hop never quotes a quote and never
# picks up the previous hop's paraphrase); any other file is taken as the raw
# words. Returns nonzero, printing nothing, when an existing block is malformed
# or its words no longer match its hash.
fm_captain_words_render() { # <file>
  local file=$1 count i words rendered=""
  [ -f "$file" ] || {
    echo "error: captain's words file not found: $file" >&2
    return 1
  }
  count=$(fm_captain_words_count "$file")
  if [ "$count" -eq 0 ]; then
    # An inbox record or a marked request is Firstmate's text, not the
    # captain's: quoting it would pass a paraphrase off as the captain's words.
    if grep -q '^schema=fm-task-inbox\.' "$file" || grep -Fq '[fm-from-firstmate]' "$file"; then
      echo "error: $file is a Firstmate message with no quoted captain's words; there are no exact words to carry, so ask for them or leave the block out rather than quoting Firstmate" >&2
      return 1
    fi
    fm_captain_words_render_stdin <"$file"
    return
  fi
  fm_captain_words_verify "$file" || return 1
  i=1
  while [ "$i" -le "$count" ]; do
    words=$(fm_captain_words_extract "$file" "$i") || return 1
    [ -z "$rendered" ] || rendered="$rendered"$'\n'
    rendered="$rendered$(printf '%s' "$words" | fm_captain_words_render_stdin)" || return 1
    i=$((i + 1))
  done
  printf '%s\n' "$rendered"
}

# Return 0 when every block in <file> is well formed and its words still match
# the recorded hash. A file with no blocks passes. On failure, print one error
# line naming the first bad block.
fm_captain_words_verify() { # <file>
  local file=$1 count i words want got rc
  count=$(fm_captain_words_count "$file")
  i=1
  while [ "$i" -le "$count" ]; do
    words=$(fm_captain_words_extract "$file" "$i")
    rc=$?
    if [ "$rc" -ne 0 ]; then
      echo "error: $file: captain's words block $i is malformed (every line must start with '>' and the block must end with its fm-captain-words hash line)" >&2
      return 1
    fi
    want=$(fm_captain_words_recorded_hash "$file" "$i")
    got=$(printf '%s' "$words" | fm_captain_words_sha256)
    if [ "$want" != "$got" ]; then
      echo "error: $file: captain's words block $i was edited after capture; restore the captain's exact words and put any reading of them outside the block" >&2
      return 1
    fi
    i=$((i + 1))
  done
  return 0
}
