// dsh-task-watcher-plugin — host-only shell plugin.
// Deploys and manages DshTaskWatcher (standalone Windows PowerShell tray app)
// from this package's assets. The watcher runs detached from the host process:
// restarting DSH does not kill the tray, and the tray talks to DSH over HTTP.
import { execFile } from "node:child_process";
import { existsSync } from "node:fs";
import { copyFile, mkdir, readFile } from "node:fs/promises";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

const name = "task-watcher";
const inject = ["webServer", "systemPrompt"];

const API = "/api/dsh-task-watcher";
const GUIDANCE =
  "本机已安装 dsh-task-watcher 插件（DSH 任务监视器外壳）：它把独立的 Windows 托盘监视程序 DshTaskWatcher 部署到 %LOCALAPPDATA%\\DshTaskWatcher 并拉起（conhost --headless 无终端窗口、脱离宿主进程常驻）。托盘四态图标：灰=DSH 未连接 / 绿=空闲 / 橙=任务运行中 / 红=有待处理；单击托盘看监控窗。管理路由（仅 loopback POST）：/api/dsh-task-watcher/status|start|stop；Web GUI 设置 → 插件 → 任务监视器 有启停开关（只控进程，不改其独立生命周期）。用户提到「任务监视器/托盘监视器/DshTaskWatcher」时即指本插件，请据此协作。";

// Package root (parent of lib/) — assets/ is a sibling of lib/.
const here = (p) => join(fileURLToPath(new URL("../", import.meta.url)), p);

function deployDir() {
  const local = process.env.LOCALAPPDATA;
  if (!local) throw new Error("LOCALAPPDATA not set");
  return join(local, "DshTaskWatcher");
}

// ---- process discovery ----------------------------------------------------
// Match the launch shape "-File <path>DshTaskWatcher.ps1" only: a command line
// that merely mentions the file (Get-Content, text editors, test harnesses)
// must never be killed by stop(). [.] avoids backslash escaping; -ne $PID
// guards self-match (the detector carries the literal pattern text).
const PS_FIND = [
  "Get-CimInstance Win32_Process -Filter \"Name='powershell.exe'\" |",
  "Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match '-File\\s+\\S*DshTaskWatcher[.]ps1' -and $_.CommandLine -notmatch 'SelfTest' } |",
  "ForEach-Object { \"$($_.ProcessId)|$($_.CommandLine)\" }",
].join(" ");

async function findPids() {
  if (process.platform !== "win32") return { pids: [], lines: [] };
  try {
    const { stdout } = await execFileAsync("powershell", ["-NoProfile", "-Command", PS_FIND], { timeout: 15000, windowsHide: true, maxBuffer: 1 << 20 });
    const lines = stdout.split(/\r?\n/).map((s) => s.trim()).filter(Boolean);
    const pids = lines.map((l) => Number.parseInt(l, 10)).filter((n) => Number.isInteger(n) && n > 0);
    return { pids, lines };
  } catch {
    return { pids: [], lines: [] };
  }
}

// Back-compat call sites expect a bare pid array.
async function findPidList() {
  return (await findPids()).pids;
}

async function readDeployedVersion(dir) {
  try {
    const text = await readFile(join(dir, "DshTaskWatcher.ps1"), "utf8");
    const m = text.match(/\$script:Version = '([^']+)'/);
    return m ? m[1] : null;
  } catch {
    return null;
  }
}

// ---- user-stop intent flag ---------------------------------------------------
// The boot convenience auto-starts a deployed-but-not-running watcher; that
// must NOT undo an explicit user stop (web switch or tray exit). The watcher
// writes this flag on graceful exit and deletes it on any real start; the
// plugin's stop() writes it too (covers pre-flag watcher builds).
const STOP_FLAG = () => join(deployDir(), "stopped.flag");

async function readStopFlag() {
  try {
    await readFile(STOP_FLAG(), "utf8");
    return true;
  } catch {
    return false;
  }
}

async function writeStopFlag() {
  try {
    const { writeFile } = await import("node:fs/promises");
    await writeFile(STOP_FLAG(), "user-stopped", "utf8");
  } catch { /* best effort */ }
}

async function clearStopFlag() {
  try {
    const { rm } = await import("node:fs/promises");
    await rm(STOP_FLAG(), { force: true });
  } catch { /* best effort */ }
}

// ---- deploy / start / stop -------------------------------------------------
// Runtime payload copied from assets/. config.json is user-owned: only-if-missing.
const RUNTIME_FILES = [
  "DshTaskWatcher.ps1",
  "gray.ico",
  "green.ico",
  "amber.ico",
  "red.ico",
  "dsh-task-watcher.ico",
  "pin-gray.png",
  "pin-blue.png",
];

async function deploy() {
  const dir = deployDir();
  await mkdir(join(dir, "logs"), { recursive: true });
  const copied = [];
  for (const file of RUNTIME_FILES) {
    const src = here(join("assets", file));
    if (!existsSync(src)) throw new Error(`asset missing: ${file} (resolved: ${src}; import.meta.url=${import.meta.url})`);
    const dst = join(dir, file);
    if (file === "config.json") {
      if (!existsSync(dst)) await copyFile(src, dst);
    } else {
      await copyFile(src, dst);
    }
    copied.push(file);
  }
  const cfg = join(dir, "config.json");
  if (!existsSync(cfg)) await copyFile(here(join("assets", "config.json")), cfg).catch(() => {});
  return { dir, files: copied.length };
}

async function start() {
  const pids = await findPidList();
  if (pids.length > 0) {
    // Already running (e.g. desktop shortcut): latest user intent is "run".
    await clearStopFlag();
    return { alreadyRunning: true, pids };
  }
  if (process.platform !== "win32") throw new Error("watcher is Windows-only");
  const { dir } = await deploy();
  const sysRoot = process.env.SystemRoot ?? "C:\\Windows";
  const ps = join(sysRoot, "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
  const { spawn } = await import("node:child_process");
  const { openSync } = await import("node:fs");
  // Diagnostics: watcher stdout/stderr land in a file (no pipes — the host
  // never blocks on the child; stdio fds are plain file handles).
  const out = openSync(join(dir, "logs", "plugin-start.log"), "a");
  // Launch powershell directly with CREATE_NO_WINDOW (windowsHide): same
  // shape as the long-proven `Start-Process -WindowStyle Hidden` install
  // path. No conhost wrapper needed when there is no shortcut heuristic to
  // dodge; the watcher self-hides its console as a second guard.
  const child = spawn(ps, ["-NoProfile", "-ExecutionPolicy", "RemoteSigned", "-File", join(dir, "DshTaskWatcher.ps1"), "-NoWelcome"], {
    // NOTE: no detached:true — DETACHED_PROCESS and windowsHide's
    // CREATE_NO_WINDOW are mutually hostile CreateProcess flags and the
    // spawn dies silently. On Windows a plain child already outlives its
    // parent; file stdio keeps nothing tied to the host lifetime either.
    stdio: ["ignore", out, out],
    windowsHide: true,
    cwd: dir,
  });
  let spawnError = null;
  child.on("error", (e) => { spawnError = e.message; });
  child.unref();
  const spawnPid = child.pid;
  // Starting clears the user-stop intent (the watcher also deletes the flag
  // itself on boot; this covers pre-flag watcher builds).
  await clearStopFlag();
  // single-instance mutex lives in the watcher itself; give it a moment
  await new Promise((r) => setTimeout(r, 4000));
  const found = await findPids();
  let diag = undefined;
  if (found.pids.length === 0) {
    try {
      const { readFile } = await import("node:fs/promises");
      const text = await readFile(join(dir, "logs", "plugin-start.log"), "utf8");
      const tail = text.split(/\r?\n/).filter(Boolean).slice(-5).join(" | ");
      diag = tail || "(plugin-start.log empty)";
    } catch {
      diag = "(no plugin-start.log)";
    }
  }
  return { started: found.pids.length > 0, pids: found.pids, spawnPid, spawnError, dir, ...(diag ? { diag } : {}), ...(found.pids.length === 0 ? { psProbe: found.lines } : {}) };
}

async function stop() {
  if (process.platform !== "win32") throw new Error("watcher is Windows-only");
  const pids = await findPidList();
  if (pids.length === 0) {
    // Nothing to kill, but record the intent so boot auto-start will not
    // resurrect the tray on the next host start.
    await writeStopFlag();
    return { stopped: true, pids: [] };
  }
  for (const pid of pids) {
    try {
      await execFileAsync("powershell", ["-NoProfile", "-Command", `Stop-Process -Id ${pid} -Force -ErrorAction SilentlyContinue`], { timeout: 15000, windowsHide: true });
    } catch {
      /* already gone */
    }
  }
  await new Promise((r) => setTimeout(r, 800));
  const left = await findPidList();
  // Stop-Process is a hard kill (no graceful Exit-App), so the flag must be
  // written here — the watcher never got the chance to.
  await writeStopFlag();
  return { stopped: left.length === 0, pids: left };
}

async function status() {
  const { pids } = await findPids();
  const dir = deployDir();
  return {
    running: pids.length > 0,
    pids,
    dataDir: dir,
    deployed: existsSync(join(dir, "DshTaskWatcher.ps1")),
    version: await readDeployedVersion(dir),
    platform: process.platform,
    stopIntent: await readStopFlag(),
  };
}

// ---- routes -----------------------------------------------------------------
function isLoopback(req) {
  const addr = req.socket?.remoteAddress ?? "";
  return addr === "127.0.0.1" || addr === "::1" || addr === "::ffff:127.0.0.1";
}

function writeJson(res, code, body) {
  res.writeHead(code, { "Content-Type": "application/json; charset=utf-8" });
  res.end(JSON.stringify(body));
}

const ACTIONS = { status, start, stop };




function makeRoutes() {
  return Object.entries(ACTIONS).map(([key, fn]) => ({
    kind: "exact",
    path: `${API}/${key}`,
    handler: async (req, res) => {
      if (!isLoopback(req)) return writeJson(res, 403, { error: "forbidden: loopback-only" });
      if ((req.method ?? "POST") !== "POST") return writeJson(res, 405, { error: `method not allowed: ${req.method}` });
      try {
        writeJson(res, 200, { result: await fn() });
      } catch (error) {
        writeJson(res, 500, { error: error instanceof Error ? error.message : String(error) });
      }
    },
  }));
}

// ---- apply -------------------------------------------------------------------
// Non-Windows hosts mount as a no-op (the watcher is a WinForms tray app).
function apply(ctx) {
  if (process.platform !== "win32") return;
  const disposers = makeRoutes().map((route) => ctx.webServer.register(route));
  ctx.effect(() => () => {
    for (const dispose of disposers) dispose();
  }, "dsh-task-watcher: routes");
  ctx.systemPrompt.section({
    name: "plugin:dsh-task-watcher",
    order: 220,
    text: GUIDANCE,
  });
  // Boot convenience: if nothing is running and a deployment already exists,
  // bring the tray up with the host. A fresh install (no deployment yet) stays
  // quiet — the user gets the tray on the first explicit start instead of a
  // surprise deploy at boot.
  status()
    .then(async (s) => {
      if (!s.running && s.deployed && !(await readStopFlag())) return start();
      return null;
    })
    .catch(() => {});
}

export { apply, inject, name };
