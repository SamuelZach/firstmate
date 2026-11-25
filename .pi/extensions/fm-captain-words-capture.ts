// Captain's-words capture for a Pi primary. Records each message the captain
// types into the primary session, byte for byte, under state/captain-words/ so
// Firstmate can hand the exact words on (bin/fm-captain-words.sh, then
// fm-send/fm-brief --captain-words-file) instead of retyping or paraphrasing
// them. No model routing, no fleet mutation, no authority over other sessions:
// it only writes files, and a write failure never disturbs the session.
import { mkdirSync, readdirSync, unlinkSync, writeFileSync, renameSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { primarySessionContext } from "./fm-primary-read-repetition.ts";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "../..");

// Keep enough history to cover a busy day of asks without growing unbounded.
export const CAPTAIN_WORDS_KEEP = 200;

export function isOperationalInput(text: string): boolean {
  // Same reserved namespace as the read-repetition guard: machine-injected
  // input is never the captain's words.
  return text.startsWith("⁣FIRSTMATE_OP: ") ||
    text.startsWith("[fm-from-firstmate]⁣") || text.startsWith("⁣Supervisor escalate (");
}

export function recordCaptainWords(dir: string, text: string, now: number, keep = CAPTAIN_WORDS_KEEP): string {
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  // Millisecond stamp plus a counter keeps names unique and sortable.
  let name = "";
  for (let n = 0; ; n++) {
    name = `${String(now).padStart(13, "0")}-${String(n).padStart(2, "0")}.txt`;
    try {
      writeFileSync(join(dir, `.${name}.tmp`), text, { flag: "wx", mode: 0o600 });
      break;
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "EEXIST" || n > 98) throw error;
    }
  }
  renameSync(join(dir, `.${name}.tmp`), join(dir, name));
  const files = readdirSync(dir).filter((f) => /^\d{13}-\d{2}\.txt$/.test(f)).sort();
  for (const old of files.slice(0, Math.max(0, files.length - keep))) {
    try { unlinkSync(join(dir, old)); } catch { /* best effort */ }
  }
  return join(dir, name);
}

export function registerCaptainWordsCapture(pi: ExtensionAPI, options: {
  dir: string; accepts: (ctx: ExtensionContext) => boolean; now?: () => number;
}): void {
  pi.on("input", (event, ctx) => {
    if (event.source !== "interactive" && event.source !== "rpc") return;
    const text = event.text ?? "";
    if (!text.trim() || isOperationalInput(text)) return;
    try {
      if (!options.accepts(ctx)) return;
      recordCaptainWords(options.dir, text, (options.now ?? Date.now)());
    } catch { /* capture is best effort and never blocks the captain */ }
  });
}

export default function (pi: ExtensionAPI): void {
  if (process.env.FM_CAPTAIN_WORDS_CAPTURE === "0") return;
  const home = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
  const state = process.env.FM_STATE_OVERRIDE || join(home, "state");
  registerCaptainWordsCapture(pi, {
    dir: join(state, "captain-words"),
    accepts: (ctx) => primarySessionContext(ctx, {
      root, home, state,
      agentDir: process.env.PI_CODING_AGENT_DIR || join(homedir(), ".pi", "agent"),
      pid: process.pid, env: process.env,
    }),
  });
}
