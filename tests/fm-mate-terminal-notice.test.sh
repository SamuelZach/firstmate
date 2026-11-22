#!/usr/bin/env bash
# Behavioural tests for the instant second-mate terminal notice in
# .pi/extensions/fm-primary-pi-watch.ts (collectMateTerminalNotices and its
# display-only renderer). The extension is loaded from a fixture repo with stub
# Pi packages, the same way tests/fm-pi-watch-extension.test.sh loads it.
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-mate-notice.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
fails=0; n=0
check() { n=$((n + 1)); if [ "$1" = 0 ]; then echo "ok $n - $2"; else echo "not ok $n - $2"; fails=$((fails + 1)); fi; }
echo "1..9"

repo="$TMP/repo"
mkdir -p "$repo/.pi/extensions/lib" "$repo/bin" "$repo/node_modules/@earendil-works/pi-coding-agent" \
  "$repo/node_modules/@earendil-works/pi-tui" "$repo/node_modules/typebox"
cp "$ROOT/.pi/extensions/fm-primary-pi-watch.ts" "$repo/.pi/extensions/"
for lib in fm-branch-dispatch fm-native-contract fm-async-exec fm-calm-visibility fm-operational-input; do
  cp "$ROOT/.pi/extensions/lib/$lib.ts" "$repo/.pi/extensions/lib/"
done
cp "$ROOT/bin/fm-operational-input.sh" "$repo/bin/"
printf '{"name":"@earendil-works/pi-coding-agent","type":"module","exports":"./index.js"}\n' > "$repo/node_modules/@earendil-works/pi-coding-agent/package.json"
printf 'export function getMarkdownTheme() { return {}; }\nexport class UserMessageComponent { render() { return []; } invalidate() {} }\n' > "$repo/node_modules/@earendil-works/pi-coding-agent/index.js"
printf '{"name":"@earendil-works/pi-tui","type":"module","exports":"./index.js"}\n' > "$repo/node_modules/@earendil-works/pi-tui/package.json"
printf 'export class Box { addChild() {} clear() {} setBgFn() {} }\nexport class Container {}\nexport class Text { constructor(t) { this.t = t; } }\n' > "$repo/node_modules/@earendil-works/pi-tui/index.js"
printf '{"name":"typebox","type":"module","exports":"./index.js"}\n' > "$repo/node_modules/typebox/package.json"
printf 'export const Type = { Object(properties) { return { type: "object", properties, additionalProperties: false }; } };\n' > "$repo/node_modules/typebox/index.js"
PLUGIN="$repo/.pi/extensions/fm-primary-pi-watch.ts"

S="$TMP/home/state"; mkdir -p "$S" "$TMP/home/config"
printf 'kind=secondmate\nwindow=default:w7:pJ\n' > "$S/mate.meta"
printf 'kind=ship\nwindow=default:w1:p1\n' > "$S/worker.meta"
printf 'done [at=1]: old history line\n' > "$S/mate.status"
printf 'done [at=1]: worker line\n' > "$S/worker.status"

run() {  # <js body>; prints its output
  PLUGIN="$PLUGIN" STATE="$S" FM_HOME="$TMP/home" FM_ROOT_OVERRIDE="$repo" node --input-type=module -e "
import { pathToFileURL } from 'node:url';
const m = await import(pathToFileURL(process.env.PLUGIN).href);
const S = process.env.STATE;
const wake = (f) => 'FIRSTMATE_OP: v1 watcher: FIRSTMATE WATCHER WAKE: signal: ' + f.map((x) => S + '/' + x).join(' ') + ' Run bin/fm-wake-drain.sh first';
$1
" 2>&1
}

out=$(run 'console.log(JSON.stringify(m.collectMateTerminalNotices(S, wake(["mate.status"]))));')
[ "$out" = "[]" ] && [ -f "$S/.mate-terminal-notice-cursor" ]
check $? "first sighting records the file end and replays no history ($out)"

printf 'working [key=x] [at=2]: still going\n' >> "$S/mate.status"
printf 'done [key=fmd-x] [corr=abc123] [at=1795387363]: child fmd-x done: PR 57\n' >> "$S/mate.status"
printf 'failed [key=fmd-y] [at=1795387400]: build broke\n' >> "$S/mate.status"
out=$(run 'const r = m.collectMateTerminalNotices(S, wake(["mate.status"])); console.log(JSON.stringify(r.map((x) => [x.mate, x.verb, x.key, x.corr, x.at])));')
[ "$out" = '[["mate","done","fmd-x","abc123",1795387363],["mate","failed","fmd-y","",1795387400]]' ]
check $? "new done/failed lines become notices with verb, key, corr and at; working lines do not ($out)"

out=$(run 'console.log(JSON.stringify(m.collectMateTerminalNotices(S, wake(["mate.status"]))));')
[ "$out" = "[]" ]
check $? "the same wake delivered again shows nothing twice ($out)"

printf 'done [at=3]: half a li' >> "$S/mate.status"
out=$(run 'console.log(JSON.stringify(m.collectMateTerminalNotices(S, wake(["mate.status"])).length));')
printf 'ne\n' >> "$S/mate.status"
out2=$(run 'console.log(JSON.stringify(m.collectMateTerminalNotices(S, wake(["mate.status"])).map((x) => x.line)));')
[ "$out" = "0" ] && [ "$out2" = '["done [at=3]: half a line"]' ]
check $? "a partially written line waits until it is complete ($out / $out2)"

printf 'done [at=4]: worker finished\n' >> "$S/worker.status"
run 'm.collectMateTerminalNotices(S, wake(["worker.status"]));' >/dev/null
printf 'done [at=5]: worker again\n' >> "$S/worker.status"
out=$(run 'console.log(JSON.stringify(m.collectMateTerminalNotices(S, wake(["worker.status"]))));')
[ "$out" = "[]" ]
check $? "a non-secondmate task's status never produces a notice ($out)"

out=$(run 'console.log(JSON.stringify(m.collectMateTerminalNotices(S, "FIRSTMATE WATCHER WAKE: stale: default:w7:pJ (x)")));')
[ "$out" = "[]" ]
check $? "a stale or heartbeat wake names no status file and yields nothing ($out)"

mv "$S/mate.status" "$S/mate.status.old"; printf 'done [at=6]: fresh file\n' > "$S/mate.status"
out=$(run 'console.log(JSON.stringify(m.collectMateTerminalNotices(S, wake(["mate.status"]))));')
printf 'done [at=7]: next\n' >> "$S/mate.status"
out2=$(run 'console.log(JSON.stringify(m.collectMateTerminalNotices(S, wake(["mate.status"])).map((x) => x.line)));')
[ "$out" = "[]" ] && [ "$out2" = '["done [at=7]: next"]' ]
check $? "a replaced status file restarts at its end, then reports new lines ($out / $out2)"

printf '{not json' > "$S/.mate-terminal-notice-cursor"
out=$(run 'console.log(JSON.stringify(m.collectMateTerminalNotices(S, wake(["mate.status"]))));')
[ "$out" = "[]" ]
check $? "a corrupt cursor fails closed to no notice and is rewritten ($out)"

out=$(run '
const renderers = {};
const pi = new Proxy({}, { get: (_t, k) => {
  if (k === "registerEntryRenderer") return (type, fn) => { renderers[type] = fn; };
  if (k === "events") return { on() {}, emit() {} };
  return () => undefined;
} });
try { m.default(pi); } catch (e) { console.log("THROW " + e.message); }
const r = renderers["fm-mate-terminal-notice"];
const theme = { fg: (_c, s) => s };
const good = r && r({ data: { version: 1, mate: "m", verb: "done", line: "done: x" } }, {}, theme);
const ok = good !== undefined && String(good.t).includes("m done: done: x") && r({ data: { nope: 1 } }, {}, theme) === undefined;
console.log(ok ? "REGISTERED" : "MISSING");
' | tail -1)
[ "$out" = "REGISTERED" ]
check $? "the extension registers the notice renderer and rejects malformed entries ($out)"

[ "$fails" -eq 0 ]
