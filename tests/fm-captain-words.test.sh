#!/usr/bin/env bash
# The captain's exact words survive every hop: captured message -> fm-send
# marked request to a secondmate -> the secondmate's fm-brief for its crewmate.
#
# A measured fleet sample kept the captain's message word for word in 3% of
# main -> secondmate requests and in none of the resulting worker briefs, so
# bin/fm-captain-words-lib.sh gives the words one hashed verbatim wire format.
# These tests pin that format, its two-hop idempotence, the refusal to pass a
# Firstmate paraphrase off as the captain's words, and fm-spawn's edit gate.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-captain-words-lib.sh
. "$ROOT/bin/fm-captain-words-lib.sh"
# shellcheck source=bin/fm-marker-lib.sh
. "$ROOT/bin/fm-marker-lib.sh"
# shellcheck source=bin/fm-brief-heading-lib.sh
. "$ROOT/bin/fm-brief-heading-lib.sh"
# shellcheck source=bin/fm-dod-lib.sh
. "$ROOT/bin/fm-dod-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-captain-words)

WORDS='are PR 65/68 live?

# not a heading, the captain typed a hash
leave it as a branch, then merge'

words_file() { # <name> -> path holding $WORDS
  printf '%s\n' "$WORDS" >"$TMP_ROOT/$1"
  printf '%s\n' "$TMP_ROOT/$1"
}

test_render_quotes_exact_words_and_verifies() {
  local f out
  f=$(words_file w1)
  out="$TMP_ROOT/w1.block"
  fm_captain_words_render "$f" >"$out" || fail "render refused plain captain words"
  grep -qx "### Captain's words (verbatim)" "$out" || fail "block heading missing"
  grep -q '^> # not a heading' "$out" || fail "a captain line starting with # must stay quoted"
  grep -qx '>' "$out" || fail "an empty captain line must be a bare quote marker"
  fm_captain_words_verify "$out" || fail "a fresh block must verify"
  assert_equals "$WORDS" "$(fm_captain_words_extract "$out")" "extract must return the exact words"
  pass "render: exact words quoted, hashed, and recovered byte for byte"
}

test_edited_or_malformed_block_is_refused() {
  local f out
  f=$(words_file w2)
  out="$TMP_ROOT/w2.block"
  fm_captain_words_render "$f" >"$out"
  sed 's/live?/live, so make them live/' "$out" >"$out.edited"
  if fm_captain_words_verify "$out.edited" 2>/dev/null; then
    fail "an edited quote must fail verification"
  fi
  awk 'NR == 2 { print "stray paraphrase line" } { print }' "$out" >"$out.bad"
  if fm_captain_words_verify "$out.bad" 2>/dev/null; then
    fail "a non-quote line inside the block must fail verification"
  fi
  pass "verify: an edited or malformed quote is refused"
}

test_firstmate_message_without_quote_is_not_the_captains() {
  local rec="$TMP_ROOT/noquote.msg"
  printf 'schema=fm-task-inbox.v1\nat=x\n--\n%scorr=ab12 He wants a geofence.\n' "$FM_FROMFIRST_MARK" >"$rec"
  if fm_captain_words_render "$rec" >/dev/null 2>&1; then
    fail "an inbox record with no quote must not be rendered as the captain's words"
  fi
  pass "render: a Firstmate message with no quote is refused, never passed off as the captain's"
}

make_tmux_stub() { # <dir> -> fakebin
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat >"$fb/tmux" <<'SH'
case "${1:-}" in
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) printf '%s\n' fm-domain; exit 0 ;;
esac
exit 0
SH
  printf 'exit 0\n' >"$fb/sleep"
  chmod +x "$fb/tmux" "$fb/sleep"
  printf '%s\n' "$fb"
}

test_two_hops_keep_the_words_unchanged() {
  local dir fb home f rec brief rc hop1 hop2
  dir="$TMP_ROOT/hops"
  mkdir -p "$dir"
  fb=$(make_tmux_stub "$dir")
  home="$dir/main"
  mkdir -p "$home/state" "$home/data" "$home/config"
  fm_write_secondmate_meta "$home/state/domain.meta" "$home" "sess:fm-domain"
  f=$(words_file w3)

  # Hop 1: Firstmate -> secondmate, with its own reading as the note.
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_SETTLE=0 \
    "$ROOT/bin/fm-send.sh" domain --captain-words-file "$f" "Check deploy state of both PRs." 2>/dev/null
  rc=$?
  expect_code 0 "$rc" "marked send with captain words should succeed"
  rec="$home/state/domain.inbox/001.msg"
  [ -f "$rec" ] || fail "no inbox record written"
  assert_grep "### Firstmate's note" "$rec" "Firstmate's text must be labelled as its note"
  assert_grep 'Check deploy state of both PRs.' "$rec" "Firstmate's note text lost"
  fm_captain_words_verify "$rec" || fail "hop 1 record must carry a verifiable quote"
  hop1=$(fm_captain_words_extract "$rec")
  assert_equals "$WORDS" "$hop1" "hop 1 changed the captain's words"

  # Hop 2: the secondmate briefs its crewmate straight from the record.
  env FM_HOME="$home" "$ROOT/bin/fm-brief.sh" t1 repo --mode direct-PR --captain-words-file "$rec" >/dev/null ||
    fail "fm-brief refused a record carrying a quote"
  brief="$home/data/t1/brief.md"
  hop2=$(fm_captain_words_extract "$brief")
  assert_equals "$WORDS" "$hop2" "hop 2 changed the captain's words"
  if grep -q 'Check deploy state' "$brief"; then
    fail "Firstmate's note must not be carried into the brief's quote"
  fi
  pass "two hops: the captain's words reach the worker's brief byte for byte, Firstmate's note stays outside"
}

test_brief_seed_keeps_task_placeholder_and_spawn_gate() {
  local home f brief
  home="$TMP_ROOT/brief"
  mkdir -p "$home/data" "$home/state" "$home/config"
  f=$(words_file w4)
  env FM_HOME="$home" "$ROOT/bin/fm-brief.sh" t2 repo --scout --captain-words-file "$f" >/dev/null ||
    fail "scout brief with captain words should scaffold"
  brief="$home/data/t2/brief.md"
  fm_brief_task_placeholders_present "$brief" || fail "the seeded quote must not count as the {TASK} fill"
  sed -i.bak 's/^{TASK}$/Context: both PRs are in the desktop app./; s/^{FIRSTMATE_SPEC}$/Report deploy state only./' "$brief"
  if fm_brief_task_placeholders_present "$brief"; then fail "filled brief still reports placeholders"; fi
  if fm_brief_intent_address_line "$brief" >/dev/null; then fail "the quote must not trip the address-line gate"; fi
  if env FM_HOME="$home" "$ROOT/bin/fm-brief.sh" t3 --secondmate --no-projects --captain-words-file "$f" >/dev/null 2>&1; then
    fail "a secondmate charter must refuse --captain-words-file"
  fi
  # shellcheck disable=SC2016 # a literal source line, not an expansion
  grep -q 'fm_captain_words_verify "$BRIEF"' "$ROOT/bin/fm-spawn.sh" || fail "fm-spawn must verify quoted captain words"
  pass "fm-brief: the quote seeds Captain's intent, {TASK} still must be filled, and fm-spawn verifies it"
}

test_capture_cli_lists_and_bundles() {
  local home dir out b
  home="$TMP_ROOT/cli"
  dir="$home/state/captain-words"
  mkdir -p "$dir"
  printf 'make it lined up' >"$dir/1764000000000-00.txt"
  printf 'and keep the four defaults' >"$dir/1764000100000-00.txt"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-captain-words.sh" list)
  assert_contains "$out" "  1  " "list should number the newest message 1"
  assert_equals "$dir/1764000100000-00.txt" "$(FM_HOME="$home" "$ROOT/bin/fm-captain-words.sh" path)" "path 1 should be the newest"
  assert_equals 'make it lined up' "$(FM_HOME="$home" "$ROOT/bin/fm-captain-words.sh" show 2)" "show must print exact words"
  b=$(FM_HOME="$home" "$ROOT/bin/fm-captain-words.sh" bundle 1 2)
  assert_equals 'make it lined up

and keep the four defaults' "$(cat "$b")" "bundle should join oldest first with one blank line"
  if FM_HOME="$home" "$ROOT/bin/fm-captain-words.sh" path 9 >/dev/null 2>&1; then
    fail "a missing message number must fail"
  fi
  pass "fm-captain-words.sh: list, path, show and bundle pick the captured words"
}

test_capture_extension_records_only_captain_input() {
  command -v node >/dev/null 2>&1 || {
    pass "capture extension: node unavailable, skipped"
    return 0
  }
  local dir="$TMP_ROOT/ext" out
  mkdir -p "$dir"
  out=$(node --experimental-strip-types --no-warnings - "$ROOT" "$dir" 2>&1 <<'JS'
const [root, dir] = process.argv.slice(2);
const mod = await import(`${root}/.pi/extensions/fm-captain-words-capture.ts`);
const handlers = {};
const pi = { on: (name, fn) => { handlers[name] = fn; } };
let t = 1764000000000;
mod.registerCaptainWordsCapture(pi, { dir: `${dir}/cw`, accepts: () => true, now: () => t++ });
const ctx = {};
handlers.input({ source: "interactive", text: "are PR 65/68 live?\n" }, ctx);
handlers.input({ source: "extension", text: "injected" }, ctx);
handlers.input({ source: "rpc", text: "[fm-from-firstmate]⁣corr=1 hi" }, ctx);
handlers.input({ source: "rpc", text: "   " }, ctx);
const { readdirSync, readFileSync } = await import("node:fs");
const files = readdirSync(`${dir}/cw`).filter((f) => f.endsWith(".txt"));
console.log(files.length, JSON.stringify(readFileSync(`${dir}/cw/${files[0]}`, "utf8")));
JS
)
  case "$out" in
    *"Cannot find package"* | *"ERR_MODULE_NOT_FOUND"* | *"strip-types"*"not"*)
      pass "capture extension: Pi types unavailable on this host, skipped"
      return 0
      ;;
  esac
  assert_equals '1 "are PR 65/68 live?\n"' "$out" "only the captain's typed message should be captured, byte for byte"
  pass "capture extension: records the captain's typed input exactly and ignores injected input"
}

fm_test_run \
  test_render_quotes_exact_words_and_verifies \
  test_edited_or_malformed_block_is_refused \
  test_firstmate_message_without_quote_is_not_the_captains \
  test_two_hops_keep_the_words_unchanged \
  test_brief_seed_keeps_task_placeholder_and_spawn_gate \
  test_capture_cli_lists_and_bundles \
  test_capture_extension_records_only_captain_input
