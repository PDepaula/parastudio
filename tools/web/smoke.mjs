// paraloop web smoke driver (task 1.7, engine report §7 acceptance: "wasm
// plays N ticks headless, 0 console errors, frame saved").
//
// Self-contained: serves the built web dir, launches a headless Chromium with
// SwiftShader (software WebGL2), and drives the build over the Chrome
// DevTools Protocol — no browser-automation tooling, Node 22+ only (global
// fetch / WebSocket). It is a plain script so the `para web smoke` command of
// task 1.8 can wrap it.
//
// usage:
//   node tools/web/smoke.mjs [--dir tmp/web/hello] [--game hello] [--page index.html]
//                            [--out tmp/web-smoke/hello.png] [--ticks 90]
//                            [--chrome PATH] [--load-timeout ms] [--move-timeout ms]
//                            [--max-texture-units N] [--sound] [--enter] [--click X,Y]
//
// what it checks:
//   1. the wasm module loads (Module._psKeyDown appears — the KEEPALIVE
//      exports of paraloop/input that the web input path goes through)
//   2. N ticks run: hold GLFW ArrowRight (262) — examples/hello moves its
//      sprite on arrow input — and require two screenshots to differ
//      (a build that crashed or never ticked renders identical frames), then
//      keep the game running until N ticks (at 60 Hz) have elapsed.
//      A game whose title screen ignores the arrows needs --enter: an
//      explicit flag (never auto-detected) that taps Enter once, and waits
//      half a second, before the input of this check.
//   2b. with --click X,Y (explicit, off by default): a real mouse click (CDP
//      Input.dispatchMouseEvent: move, press, release of the left button) at
//      viewport pixel X,Y, on the page the ticks above ran on. The web pointer
//      path must be up (Module._psPointer and Module._psButton exported) and
//      the canvas must receive the pointerdown. This proves the browser-to-engine
//      pointer path is wired, not that the game acted on the click: that is
//      proven headlessly (by the game's own tests). The web
//      build has no way to read the player's position today (live status is a
//      ping and no web dev handler is installed), and a frame diff proves
//      nothing in a room that animates on its own.
//   3. zero console errors and zero page exceptions
//   3b. zero WebGL warnings or errors (texture unit out of range, sampler
//      uniform out of range, INVALID_*, ...). The page also sees an emulated
//      device with --max-texture-units N combined texture units (default 32,
//      the most WebGL2 guarantees; iOS and Windows report exactly that):
//      `getParameter(MAX_COMBINED_TEXTURE_IMAGE_UNITS)` answers min(N, real)
//      and an `activeTexture` past N-1 is logged as the same warning a device
//      with N units would, so a game that needs more units than a phone has
//      fails here even though this host's Chromium has 64.
//   4. a final frame is saved to --out, differs from the page with the canvas
//      hidden, and has more than one colour (a canvas cleared to black and
//      never drawn to differs from the hidden page, so the first test alone
//      would pass it)
//   5. with --sound (explicit, off by default), under Chromium's
//      document-user-activation autoplay policy: the Web Audio backend
//      (src/paraloop/web/audio.js, `Module.psAudio`) opened and loaded buffers,
//      starts locked (`suspended`), a REAL key press (CDP Input.dispatchKeyEvent,
//      not a page-side event, which carries no user activation) moves the
//      context to `running`, and the game's sound then plays at least once.
//      The sound is the game's reply to the ArrowRight the driver presses
//      (Module._psKeyDown, check 2), so the game under test must beep on it
//      (examples/hello does)

import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import net from "node:net";
import zlib from "node:zlib";
import { spawn, spawnSync } from "node:child_process";

// ---------------------------------------------------------------- CLI args

const argv = process.argv.slice(2);
function arg(name, fallback) {
  const i = argv.indexOf("--" + name);
  return i >= 0 && argv[i + 1] ? argv[i + 1] : fallback;
}
const game = arg("game", null);
const dir = path.resolve(arg("dir", game ? `tmp/web/${game}` : "tmp/web"));
const page = path.basename(arg("page", "index.html"));
const out = path.resolve(arg("out",
  path.join("tmp/web-smoke", game ? `${game}.png` : "frame.png")));
const ticks = Number(arg("ticks", "90"));
const loadTimeout = Number(arg("load-timeout", "90000"));
const moveTimeout = Number(arg("move-timeout", "15000"));
const maxTextureUnits = Number(arg("max-texture-units", "32"));
const expectSound = argv.includes("--sound");
const pressEnter = argv.includes("--enter");
const clickArg = arg("click", null);
const clickAt = clickArg === null ? null : clickArg.split(",").map(Number);
if (clickAt !== null && (clickAt.length !== 2 || !clickAt.every((n) => Number.isInteger(n) && n >= 0))) {
  console.error(`fail  --click wants X,Y (whole viewport pixels, e.g. 480,300), got "${clickArg}"`);
  process.exit(1);
}
const GLFW = { right: 262, left: 263, down: 264, up: 265, enter: 257 };

if (!fs.existsSync(path.join(dir, page))) {
  console.error(`fail  ${page} not found under ${dir} — build it first: para build --target web (or the recipe in docs/web.md)`);
  process.exit(1);
}

// ---------------------------------------------------------------- static server

const MIME = {
  ".html": "text/html; charset=utf-8",
  ".js": "application/javascript; charset=utf-8",
  ".wasm": "application/wasm",
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".svg": "image/svg+xml",
  ".ttf": "font/ttf",
  ".otf": "font/otf",
  ".woff": "font/woff",
  ".woff2": "font/woff2",
  ".json": "application/json",
  ".webmanifest": "application/manifest+json",
  ".ico": "image/x-icon",
};
const server = http.createServer((req, res) => {
  let p = new URL(req.url, "http://localhost").pathname;
  if (p === "/") p = "/" + page;
  const file = path.join(dir, path.normalize(p).replace(/^([/\\])+/, ""));
  if (!file.startsWith(dir) || !fs.existsSync(file) || !fs.statSync(file).isFile()) {
    res.writeHead(404).end("404 " + p);
    return;
  }
  res.writeHead(200, { "content-type": MIME[path.extname(file)] || "application/octet-stream" });
  fs.createReadStream(file).pipe(res);
});
function freePort() {
  return new Promise((resolve, reject) => {
    net.createServer().once("error", reject)
      .once("listening", function () { const p = this.address().port; this.close(); resolve(p); })
      .listen(0, "127.0.0.1");
  });
}
const filePort = await freePort();
await new Promise((r) => server.listen(filePort, "127.0.0.1", r));
const cdpPort = await freePort();
const pageUrl = `http://127.0.0.1:${filePort}/${page}`;

// ---------------------------------------------------------------- chromium

function findChrome() {
  for (const c of [arg("chrome", ""), process.env.CHROME_BIN,
                   "google-chrome", "chromium", "chromium-browser", "chrome"]) {
    if (!c) continue;
    try { if (spawnSync(c, ["--version"], { timeout: 5000 }).status === 0) return c; } catch {}
  }
  return null;
}
const chrome = findChrome();
if (!chrome) { console.error("fail  no chrome/chromium found — set --chrome or CHROME_BIN"); process.exit(1); }

const profile = fs.mkdtempSync(path.join(os.tmpdir(), "paraloop-smoke-"));
const chromeProc = spawn(chrome, [
  "--headless=new",
  "--disable-gpu",
  "--enable-unsafe-swiftshader",  // software WebGL2 where no GPU (CI) is present
  "--no-first-run", "--no-default-browser-check",
  "--disable-extensions",
  "--disable-dev-shm-usage",
  "--window-size=1280,720",
  `--user-data-dir=${profile}`,
  "--autoplay-policy=document-user-activation-required", // audio stays locked until a real gesture
  `--remote-debugging-port=${cdpPort}`,
  "about:blank",
], { detached: true, stdio: "ignore" });
let chromeKilled = false;
const killChrome = () => {
  if (chromeKilled) return; chromeKilled = true;
  try { process.kill(-chromeProc.pid); } catch {}
};
process.on("exit", killChrome);
process.on("SIGINT", () => { killChrome(); process.exit(130); });

let target = null;
const t0 = Date.now();
while (!target && Date.now() - t0 < 20000) {
  try {
    for (const t of await (await fetch(`http://127.0.0.1:${cdpPort}/json/list`)).json())
      if (t.type === "page") { target = t; break; }
  } catch {}
  if (!target) await new Promise((r) => setTimeout(r, 250));
}
if (!target) { killChrome(); console.error("fail  chromium did not expose a CDP target"); process.exit(1); }

// ---------------------------------------------------------------- CDP session

const ws = new WebSocket(target.webSocketDebuggerUrl);
await new Promise((resolve, reject) => {
  ws.onopen = resolve;
  ws.onerror = () => reject(new Error("cdp websocket error"));
});
let idc = 0;
const pending = new Map();
const consoleErrors = [];
const pageExceptions = [];
const webglMessages = [];
// What Chromium logs for a WebGL call that failed or a draw that is wrong:
// `WebGL: INVALID_ENUM: activeTexture: ...`, `GL_INVALID_VALUE: glUniform1i:
// ...`, `RENDER WARNING: ...`. Its performance hints (GPU stall due to
// ReadPixels) and the software-fallback notice are not correctness problems.
const GL_MESSAGE = /\bWebGL\b|\bGL_[A-Z_]+\b|\bINVALID_[A-Z_]+\b|out of range|context lost|CONTEXT_LOST/i;
const GL_NOISE = /GL Driver Message \(OpenGL, Performance|GPU stall|Automatic fallback to software WebGL/i;
const noteWebgl = (text) => {
  if (GL_MESSAGE.test(text) && !GL_NOISE.test(text)) webglMessages.push(text.trim());
};
ws.onmessage = (m) => {
  const msg = JSON.parse(typeof m.data === "string" ? m.data : m.data.toString());
  if (msg.id && pending.has(msg.id)) {
    const { resolve: r, reject: j } = pending.get(msg.id);
    pending.delete(msg.id);
    msg.error ? j(new Error(msg.error.message)) : r(msg.result);
    return;
  }
  if (msg.method === "Runtime.consoleAPICalled" && ["error", "warning"].includes(msg.params.type)) {
    const text = (msg.params.args || [])
      .map((a) => a.value ?? a.description ?? JSON.stringify(a)).join(" ");
    if (msg.params.type === "error") consoleErrors.push(text);
    noteWebgl(text);
  }
  if (msg.method === "Log.entryAdded" && ["error", "warning"].includes(msg.params.entry?.level)) {
    const text = `${msg.params.entry.text}${msg.params.entry.url ? ` (${msg.params.entry.url})` : ""}`;
    if (msg.params.entry.level === "error") consoleErrors.push(text);
    noteWebgl(text);
  }
  if (msg.method === "Runtime.exceptionThrown")
    pageExceptions.push(
      (msg.params.exceptionDetails?.text || "") +
      " " + (msg.params.exceptionDetails?.exception?.description || ""));
};
const send = (method, params = {}) => new Promise((resolve, reject) => {
  const id = ++idc;
  pending.set(id, { resolve, reject });
  ws.send(JSON.stringify({ id, method, params }));
  setTimeout(() => {
    if (pending.has(id)) { pending.delete(id); reject(new Error("cdp timeout: " + method)); }
  }, 30000);
});
const evalJs = async (expression) => {
  const r = await send("Runtime.evaluate", { expression, returnByValue: true, awaitPromise: true });
  if (r.exceptionDetails) throw new Error("eval: " + JSON.stringify(r.exceptionDetails));
  return r.result?.value;
};
// A real key press: CDP injects it at the browser's input layer, so it is a
// trusted event that grants the page user activation (`Module._psKeyDown` and
// synthetic page-side events do not).
const pressKey = async (key, code, keyCode) => {
  const k = { key, code, windowsVirtualKeyCode: keyCode, nativeVirtualKeyCode: keyCode };
  await send("Input.dispatchKeyEvent", { type: "keyDown", ...k });
  await send("Input.dispatchKeyEvent", { type: "keyUp", ...k });
};
const audioStats = () => evalJs(
  "(typeof Module === 'object' && Module && Module.psAudio) ? Module.psAudio.stats() : null");
const audioDetail = (a) => a === null ? "no Module.psAudio (the web build has no audio backend)"
  : `state ${a.state}, ${a.buffers} buffers, ${a.plays} plays, ${a.dropped} dropped`;
// Distinct colours in a Chrome screenshot (8-bit RGB/RGBA PNG, no
// interlacing), counted up to `cap`; null for any other PNG shape.
function distinctColours(png, cap = 64) {
  let pos = 8, w = 0, h = 0, bpp = 0;
  const idat = [];
  while (pos + 12 <= png.length) {
    const len = png.readUInt32BE(pos), type = png.toString("latin1", pos + 4, pos + 8);
    const data = png.subarray(pos + 8, pos + 8 + len);
    if (type === "IHDR") {
      w = data.readUInt32BE(0); h = data.readUInt32BE(4);
      if (data[8] !== 8 || ![2, 6].includes(data[9]) || data[12] !== 0) return null;
      bpp = data[9] === 6 ? 4 : 3;
    } else if (type === "IDAT") idat.push(data);
    pos += 12 + len;
  }
  if (!w || !h) return null;
  const raw = zlib.inflateSync(Buffer.concat(idat));
  const stride = w * bpp, seen = new Set();
  let prev = Buffer.alloc(stride);
  for (let y = 0; y < h; y++) {
    const at = y * (stride + 1), filter = raw[at];
    const row = Buffer.from(raw.subarray(at + 1, at + 1 + stride));
    for (let x = 0; x < stride; x++) {
      const a = x >= bpp ? row[x - bpp] : 0, b = prev[x], c = x >= bpp ? prev[x - bpp] : 0;
      let p = 0;
      if (filter === 1) p = a;
      else if (filter === 2) p = b;
      else if (filter === 3) p = (a + b) >> 1;
      else if (filter === 4) {
        const pa = Math.abs(b - c), pb = Math.abs(a - c), pc = Math.abs(a + b - 2 * c);
        p = pa <= pb && pa <= pc ? a : pb <= pc ? b : c;
      }
      row[x] = (row[x] + p) & 255;
    }
    for (let x = 0; x < w; x++) {
      seen.add(row.readUIntBE(x * bpp, 3));
      if (seen.size >= cap) return seen.size;
    }
    prev = row;
  }
  return seen.size;
}
const screenshot = async () =>
  Buffer.from((await send("Page.captureScreenshot", { format: "png" })).data, "base64");

await send("Page.enable");
await send("Runtime.enable");
await send("Log.enable");
try { await send("Emulation.setFocusEmulationEnabled", { enabled: true }); } catch {}
try { await send("Page.bringToFront"); } catch {}
// An emulated device with `maxTextureUnits` combined texture units, installed
// before the page's own scripts run (see the header, check 3b).
await send("Page.addScriptToEvaluateOnNewDocument", { source: `(() => {
  const LIMIT = ${maxTextureUnits}, MAX_COMBINED = 0x8B4D, TEXTURE0 = 0x84C0;
  for (const C of [window.WebGLRenderingContext, window.WebGL2RenderingContext]) {
    if (!C) continue;
    const getParameter = C.prototype.getParameter;
    const activeTexture = C.prototype.activeTexture;
    C.prototype.getParameter = function (pname) {
      const v = getParameter.call(this, pname);
      return pname === MAX_COMBINED && typeof v === "number" ? Math.min(v, LIMIT) : v;
    };
    C.prototype.activeTexture = function (texture) {
      if (texture - TEXTURE0 >= LIMIT)
        console.warn("WebGL: INVALID_ENUM: activeTexture: texture unit out of range (unit " +
          (texture - TEXTURE0) + ", device has " + LIMIT + ")");
      return activeTexture.call(this, texture);
    };
  }
})();` });
await send("Page.navigate", { url: pageUrl });

const ok = [];
const fail = [];
function check(name, pass, detail) { (pass ? ok : fail).push({ name, detail }); }

// -- 1. the wasm module loads --------------------------------------------------
let moduleLoaded = false;
const lt0 = Date.now();
while (Date.now() - lt0 < loadTimeout) {
  if (consoleErrors.length > 0 && moduleLoaded === false && Date.now() - lt0 > 3000) break; // it's not coming
  try {
    moduleLoaded = await evalJs(
      "typeof Module === 'object' && Module && typeof Module._psKeyDown === 'function'");
  } catch { if (consoleErrors.length > 0) break; }
  if (moduleLoaded) break;
  await new Promise((r) => setTimeout(r, 200));
}
check("wasm module loads", moduleLoaded,
  moduleLoaded ? "Module._psKeyDown export present"
               : "Module._psKeyDown never appeared within " + loadTimeout + " ms");

if (moduleLoaded) {
  await new Promise((r) => setTimeout(r, 800));  // let a few frames settle

  // -- 5a. sound: the backend is up and locked, a real key press unlocks it ----
  if (expectSound) {
    const locked = await audioStats();
    check("audio backend loads sounds", locked !== null && locked.buffers > 0, audioDetail(locked));
    check("audio starts locked", locked !== null && locked.state === "suspended",
      locked === null ? audioDetail(locked)
        : `context is ${locked.state} before any user gesture; expected suspended ` +
          "(autoplay policy: document-user-activation-required)");
    await pressKey(" ", "Space", 32);
    let unlocked = null;
    const u0 = Date.now();
    while (Date.now() - u0 < 5000) {
      unlocked = await audioStats();
      if (unlocked && unlocked.state === "running") break;
      await new Promise((r) => setTimeout(r, 100));
    }
    check("a real key press unlocks audio", unlocked !== null && unlocked.state === "running",
      `${audioDetail(unlocked)} (${Date.now() - u0} ms after a CDP key press)`);
  }

  // -- 2. N ticks run: hold ArrowRight, require the rendered frame to change --
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  if (pressEnter) {
    await evalJs(`Module._psKeyDown(${GLFW.enter})`);
    await sleep(60);
    await evalJs(`Module._psKeyUp(${GLFW.enter})`);
    await sleep(500);
  }
  const before = await screenshot();
  await evalJs(`Module._psKeyDown(${GLFW.right})`);
  let frame = null;
  const m0 = Date.now();
  while (Date.now() - m0 < moveTimeout) {
    const now = await screenshot();
    if (!now.equals(before)) { frame = now; break; }
    await sleep(250);
  }
  await evalJs(`Module._psKeyUp(${GLFW.right})`);
  const movedMs = Date.now() - m0;
  const ticksMs = Math.round(ticks / 60 * 1000);
  if (frame) await sleep(Math.max(0, ticksMs - movedMs));
  const ranMs = Date.now() - m0;
  check("ticks run", frame !== null,
    frame ? `frame changed after ${movedMs} ms with ArrowRight held; ran ${ranMs} ms (${ticks} ticks ≈ ${ticksMs} ms at 60 Hz)`
          : `frame never changed within ${moveTimeout} ms while ArrowRight was held — no ticks rendered`);

  // -- 2b. a canvas click reaches the engine's pointer path ------------------
  if (clickAt !== null) {
    const exportsUp = await evalJs(
      "typeof Module._psPointer === 'function' && typeof Module._psButton === 'function'");
    await evalJs("window.__clicks = 0; document.getElementById('canvas')" +
      ".addEventListener('pointerdown', () => { window.__clicks++; });");
    const [cx, cy] = clickAt;
    const mouse = { x: cx, y: cy, button: "left", clickCount: 1 };
    await send("Input.dispatchMouseEvent", { type: "mouseMoved", x: cx, y: cy });
    await send("Input.dispatchMouseEvent", { type: "mousePressed", buttons: 1, ...mouse });
    await sleep(100);
    await send("Input.dispatchMouseEvent", { type: "mouseReleased", buttons: 0, ...mouse });
    const seen = await evalJs("window.__clicks");
    check("the canvas click reaches the engine's pointer path", exportsUp && seen > 0,
      !exportsUp ? "Module._psPointer / Module._psButton are not exported (the web pointer path is missing)"
        : seen === 0 ? `the canvas never received a pointerdown for a click at ${cx},${cy}`
        : `click at ${cx},${cy}: the canvas got ${seen} pointerdown and the pointer exports are up (the browser-to-engine path is wired; that the game acts on it is proven by test_click_move.nim, not here)`);
  }

  // -- 5b. sound: the game must have beeped on the ArrowRight held above ----
  if (expectSound) {
    let heard = null;
    const h0 = Date.now();
    while (Date.now() - h0 < 5000) {
      heard = await audioStats();
      if (heard && heard.plays > 0) break;
      await new Promise((r) => setTimeout(r, 100));
    }
    check("a sound plays", heard !== null && heard.plays > 0, audioDetail(heard));
  }

  // -- 4. frame saved ----------------------------------------------------------
  const finalFrame = await screenshot();
  fs.mkdirSync(path.dirname(out), { recursive: true });
  fs.writeFileSync(out, finalFrame);
  // blank reference: the same page with the game canvas hidden
  await evalJs("document.getElementById('canvas').style.visibility = 'hidden'");
  const blank = await screenshot();
  await evalJs("document.getElementById('canvas').style.visibility = ''");
  const rendered = !finalFrame.equals(blank);
  check("frame saved", rendered,
    `${path.relative(process.cwd(), out)} (${finalFrame.length} bytes` +
    (rendered ? ")" : " — identical to the page with the canvas hidden: nothing rendered)"));
  const colours = distinctColours(finalFrame);
  check("frame is not blank", colours === null || colours > 1,
    colours === null ? "not checked (screenshot is not an 8-bit RGB(A) PNG)"
      : colours > 1 ? `${colours >= 64 ? "64+" : colours} distinct colours`
      : "one colour over the whole page: the canvas was cleared and never drawn to");
}

// -- 3. zero console errors / page exceptions ----------------------------------
check("0 console errors", consoleErrors.length === 0,
  consoleErrors.length === 0 ? "none"
    : "console errors:\n    " + consoleErrors.slice(0, 5).join("\n    "));
check("0 page exceptions", pageExceptions.length === 0,
  pageExceptions.length === 0 ? "none" : pageExceptions.slice(0, 5).join(" | "));
check("0 WebGL warnings", webglMessages.length === 0,
  webglMessages.length === 0 ? `none (device emulated with ${maxTextureUnits} texture units)`
    : `${webglMessages.length} WebGL message(s), first:\n    ` +
      webglMessages.slice(0, 5).join("\n    "));

// ---------------------------------------------------------------- report

console.log(`page  ${pageUrl}`);
for (const c of ok) console.log(`ok  ${c.name}${c.detail ? `\n    ${String(c.detail).replace(/\n/g, "\n    ")}` : ""}`);
for (const c of fail) console.log(`fail  ${c.name}${c.detail ? `\n    ${String(c.detail).replace(/\n/g, "\n    ")}` : ""}`);
console.log(fail.length === 0
  ? `pass  ${ok.length}/${ok.length + fail.length} checks`
  : `fail  ${ok.length} ok, ${fail.length} failed`);

ws.close();
server.close();
killChrome();
try { fs.rmSync(profile, { recursive: true, force: true }); } catch {}
process.exit(fail.length === 0 ? 0 : 1);
