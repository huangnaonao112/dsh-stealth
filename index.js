/**
 * dsh-stealth — Host half.
 *
 * One authenticated route drives a Win32 helper script that operates on the
 * desktop app's own top-level windows, inside the current user session, with
 * no injection into any other process. The window itself stays visible and
 * usable; only its external traces are hidden:
 *
 *   GET|POST <routePath>?op=state    observe: { running, stealth, visibleWindows }
 *   POST <routePath>?op=toggle       master switch:
 *                                      ON  → WS_EX_TOOLWINDOW on every visible
 *                                            top-level window (taskbar button
 *                                            and Alt-Tab entry disappear), the
 *                                            tray icon is transparent (file
 *                                            swap, handled outside the plugin)
 *                                      OFF → styles restored, everything visible
 *
 * The switch state persists across app restarts: at boot the host re-applies
 * the style once the main window exists. No hotkey listener is spawned — the
 * window stays reachable, so there is nothing to restore blindly.
 *
 * What is deliberately out of scope: removing the process row from Task
 * Manager. That requires injecting into taskmgr.exe, which this plugin will
 * not do.
 *
 * @module dsh-stealth
 */
import { spawn } from "node:child_process";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import path from "node:path";
import os from "node:os";

/** Plugin name, also the bundle row id. */
export const name = "dsh-stealth";

/** Host services: the route fence. */
export const inject = ["connection"];

const SCRIPT = path.join(path.dirname(fileURLToPath(import.meta.url)), "scripts", "stealth.ps1");
const STATE_FILE = path.join(os.homedir(), ".dsh", "dsh-stealth.state");
const PROCESS_NAME = "DeepSeek Harness";
const ROUTE = "/api/dsh-stealth";
/** How long a `state` reading may be served from cache. */
const STATE_TTL_MS = 1500;
/** Wait before the first boot reconcile, so the main window exists. */
const BOOT_DELAY_MS = 10000;
/** Boot reconcile polling budget (~1 minute). */
const BOOT_ATTEMPTS = 40;

function runPs(action) {
  return new Promise((resolve, reject) => {
    const child = spawn("powershell.exe", [
      "-NoProfile",
      "-NonInteractive",
      "-ExecutionPolicy", "Bypass",
      "-File", SCRIPT,
      "-Action", action,
      "-ProcessName", PROCESS_NAME,
      "-StateFile", STATE_FILE
    ], { windowsHide: true });

    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => { stdout += chunk; });
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    child.on("error", reject);
    child.on("close", () => {
      // The script prints exactly one compressed JSON object, but some
      // actions nest objects, so slice from the first "{" to the last "}".
      const start = stdout.indexOf("{");
      const end = stdout.lastIndexOf("}");
      if (start >= 0 && end > start) {
        try {
          resolve(JSON.parse(stdout.slice(start, end + 1)));
          return;
        } catch {}
      }
      const reason = stderr.trim() || ("exit " + child.exitCode);
      reject(new Error("stealth.ps1 " + action + ": " + reason));
    });
  });
}

function jsonResponse(body) {
  return new Response(JSON.stringify(body), {
    status: 200,
    headers: { "content-type": "application/json; charset=utf-8", "Cache-Control": "no-store" }
  });
}

function errorResponse(message) {
  return new Response(JSON.stringify({ ok: false, error: String(message) }), {
    status: 500,
    headers: { "content-type": "application/json; charset=utf-8", "Cache-Control": "no-store" }
  });
}

/** `toolwindow=1` line from the shared state file, or null when absent. */
async function readStealthFlag() {
  try {
    const text = await readFile(STATE_FILE, "utf8");
    const match = /(?:^|\n)toolwindow=(\d)(?:\n|$)/.exec(text);
    return match === null ? null : match[1];
  } catch {
    return null;
  }
}

export function apply(ctx) {
  /** All helper invocations run serialized; the Win32 core is not re-entrant. */
  let chain = Promise.resolve();
  let cache = { at: 0, value: null };

  const serialized = (job) => {
    const run = chain.then(job, job);
    chain = run.then(() => undefined, () => undefined);
    return run;
  };

  const invalidate = () => { cache.at = 0; };

  async function state() {
    const now = Date.now();
    if (cache.value !== null && now - cache.at < STATE_TTL_MS) return cache.value;
    const reading = await runPs("check");
    const flag = await readStealthFlag();
    cache.at = Date.now();
    cache.value = {
      ok: true,
      running: reading.running === true,
      /** The master switch is the state file's own record. */
      stealth: flag === "1",
      visibleWindows: reading.visibleWindows || 0
    };
    return cache.value;
  }

  async function toggle() {
    const result = await runPs("toolwindow-toggle");
    invalidate();
    return result;
  }

  /**
   * Re-apply the taskbar hiding after an app restart when the switch was ON,
   * so the preference survives relaunches. Polls until a window exists, then
   * styles it once.
   */
  const bootTimer = setTimeout(() => {
    serialized(async () => {
      try {
        if ((await readStealthFlag()) !== "1") return;
        for (let attempt = 0; attempt < BOOT_ATTEMPTS; attempt += 1) {
          const reading = await runPs("check");
          if (!reading || reading.running !== true) return;
          if (reading.visibleWindows > 0) {
            await runPs("toolwindow-on");
            return;
          }
        }
      } catch {}
    });
  }, BOOT_DELAY_MS);

  async function serve(request) {
    const op = new URL(request.url).searchParams.get("op") || "state";
    try {
      if (op === "toggle") {
        const result = await serialized(toggle);
        return jsonResponse({ ok: true, stealth: result ? result.on === true : undefined });
      }
      return jsonResponse(await state());
    } catch (error) {
      return errorResponse(error);
    }
  }

  ctx.effect(() => ctx.connection.fetch.register({
    path: ROUTE,
    methods: ["GET", "POST"],
    requestBody: "buffered",
    fetch: (request) => serve(request)
  }), "dsh-stealth: route");

  // The browser half reads the route from the served page so the two can never drift.
  ctx.on("webserver/index-inject", (table) => {
    table.push({ kind: "global", name: "__DSH_STEALTH__", value: { routePath: ROUTE } });
  });

  ctx.effect(() => () => {
    clearTimeout(bootTimer);
  }, "dsh-stealth: boot reconcile cleanup");
}
