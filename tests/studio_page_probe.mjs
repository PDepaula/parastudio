// Drives the studio page in a headless Chromium over the DevTools Protocol and prints, as one JSON
// line, what a person would actually see: computed layout and colours, the theme the page picks and
// remembers, Pip's states, how a message is drawn, the favicon as the browser loads it, and every
// address the page asked for or refused to load.
// usage: node tests/studio_page_probe.mjs URL CHROME
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";

const [url, chrome] = process.argv.slice(2);
const profile = fs.mkdtempSync(path.join(os.tmpdir(), "studio-probe-"));
const proc = spawn(chrome, ["--headless=new", "--disable-gpu", "--no-first-run", "--no-sandbox",
  "--disable-dev-shm-usage", `--user-data-dir=${profile}`, "--remote-debugging-port=0", "about:blank"],
  { detached: true, stdio: "ignore" });
const done = (code) => { try { process.kill(-proc.pid); } catch {} try { fs.rmSync(profile, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 }); } catch {} process.exit(code); };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

let port = 0;
for (let i = 0; i < 80 && !port; i++) {
  try { port = Number(fs.readFileSync(path.join(profile, "DevToolsActivePort"), "utf8").split("\n")[0]); } catch {}
  if (!port) await sleep(250);
}
if (!port) { console.error("no DevTools port"); done(1); }
let target = null;
for (let i = 0; i < 40 && !target; i++) {
  try { target = (await (await fetch(`http://127.0.0.1:${port}/json/list`)).json()).find((t) => t.type === "page"); } catch {}
  if (!target) await sleep(250);
}
if (!target) { console.error("no page target"); done(1); }

const ws = new WebSocket(target.webSocketDebuggerUrl);
await new Promise((res, rej) => { ws.onopen = res; ws.onerror = () => rej(new Error("cdp websocket error")); });
let nextId = 0;
const pending = new Map();
ws.onmessage = (m) => { const d = JSON.parse(m.data); if (d.id && pending.has(d.id)) { pending.get(d.id)(d); pending.delete(d.id); } };
const send = (method, params = {}) => new Promise((res) => { const id = ++nextId; pending.set(id, res); ws.send(JSON.stringify({ id, method, params })); });
const events = [];
ws.addEventListener("message", (m) => { const d = JSON.parse(m.data); if (d.method) events.push(d); });
const evaluate = async (expression) => {
  const r = await send("Runtime.evaluate", { expression, returnByValue: true, awaitPromise: true });
  if (r.result.exceptionDetails) throw new Error(JSON.stringify(r.result.exceptionDetails));
  return r.result.result.value;
};


const shown = `(el) => {
  if (!el) return false;
  const r = el.getBoundingClientRect();
  return getComputedStyle(el).display !== "none" && r.width > 0 && r.height > 0 && r.right <= innerWidth + 1;
}`;

async function visit(width, { scheme = "light", reduce = false, keepCookies = false } = {}) {
  if (!keepCookies) await send("Network.clearBrowserCookies");
  await send("Emulation.setDeviceMetricsOverride", { width, height: 900, deviceScaleFactor: 1, mobile: false });
  await send("Emulation.setEmulatedMedia", { features: [
    { name: "prefers-color-scheme", value: scheme },
    { name: "prefers-reduced-motion", value: reduce ? "reduce" : "no-preference" }] });
  await send("Page.navigate", { url });
  for (let i = 0; i < 80; i++) {
    await sleep(250);
    try {
      if (await evaluate(`document.readyState === "complete" && document.getElementById("chat-cost").textContent !== ""`)) return;
    } catch {}
  }
  throw new Error(`page did not load at ${width}px`);
}

const layout = (() => `(() => {
  const shown = ${shown};
  const text = (id) => document.getElementById(id).textContent;
  const el = (id) => document.getElementById(id);
  closeMenus(); // the startup checks open by themselves when something is not ready
  const out = { calmText: text("chat-calm"), calmShown: shown(el("chat-calm")),
                costText: text("chat-cost"), costShown: shown(el("chat-cost")),
                chipsShown: shown(el("chat-hello")),
                // anything on show under the message box, past the box itself and the empty status lines
                underBox: [...document.querySelector(".cwrap").children].filter((c) => c.id !== "chat-form" && shown(c)).map((c) => c.id || c.className),
                sideBox: document.querySelector(".pipcard .face").getBoundingClientRect().width,
                helloBox: document.querySelector(".hello .pip-tile").getBoundingClientRect().width };
  showPop("ready-pop", "ready-btn");
  out.calmInReady = shown(el("chat-calm")); out.costInReady = shown(el("chat-cost"));
  el("help-btn").click();
  out.costInHelp = shown(el("help-cost")) && text("help-cost") === out.costText;
  out.aboutInHelp = el("agent-about").children.length;
  closeMenus();
  const log = document.getElementById("chat-log");
  document.getElementById("app").classList.remove("is-empty");
  renderEvent({ kind: "you", text: "make it faster" });
  renderEvent({ kind: "say", text: "On it, <b>director</b>." });
  const you = log.querySelector(".msg.you .bub"), prod = log.querySelector(".msg.prod .bub");
  const tile = log.querySelector(".msg.prod > .pip-tile");
  const look = (b) => { const c = getComputedStyle(b); return { background: c.backgroundColor, radius: c.borderTopLeftRadius }; };
  out.you = look(you); out.prod = look(prod);
  out.youRight = you.getBoundingClientRect().left > prod.getBoundingClientRect().left;
  out.prodTextIsText = prod.querySelector("b") === null && prod.textContent.includes("<b>director</b>");
  out.avatarShown = (${shown})(tile);
  out.avatarBox = tile.getBoundingClientRect().width;
  out.avatarDrawn = !!tile.querySelector("svg");
  return out;
})()`)();

const themeProbe = `(() => {
  const root = document.documentElement;
  const css = getComputedStyle(root);
  return { theme: root.dataset.theme || "", bg: getComputedStyle(document.body).backgroundColor,
           accent: css.getPropertyValue("--accent").trim().toLowerCase(),
           label: document.getElementById("theme-label").textContent, cookie: document.cookie };
})()`;
const warnProbe = `(() => {
  renderEvent({ kind: "refused", text: "not allowed" });
  const el = document.querySelector("#chat-log .line.refused");
  return getComputedStyle(el).color;
})()`;
const clickTheme = `(() => { document.getElementById("theme-btn").click(); })()`;

const pipProbe = (state) => `(() => {
  chatRunning = ${state === "thinking"}; talkUntil = 0;
  if (${state === "talking"}) pipSpeaks(); else updatePip();
  const pip = document.querySelector(".pip[data-state]");
  const vis = (sel) => getComputedStyle(pip.querySelector(sel)).display;
  const out = { state: pip.dataset.state, bird: getComputedStyle(pip.querySelector(".bird")).animationName,
                dots: vis(".think-dots"), arcs: vis(".talk-arcs"),
                jaw: getComputedStyle(pip.querySelector(".lower")).animationName };
  chatRunning = false; talkUntil = 0; updatePip();
  return out;
})()`;

const faviconProbe = `(async () => {
  const href = document.querySelector("link[rel~=icon]").href;
  const img = new Image();
  img.src = href;
  await img.decode();
  return { scheme: href.slice(0, href.indexOf(",")), width: img.naturalWidth, height: img.naturalHeight };
})()`;

const drawerProbe = (step) => `(async () => {
  const sb = document.querySelector(".sb");
  const wait = (ms) => new Promise((r) => setTimeout(r, ms));
  if (${JSON.stringify(step)} === "open") { document.getElementById("menu-btn").click(); await wait(500); }
  if (${JSON.stringify(step)} === "close") { document.getElementById("sb-close").click(); await wait(500); }
  const probe = sb.querySelector(".row") || sb.querySelector("button");
  probe.focus();
  return { visibility: getComputedStyle(sb).visibility, left: sb.getBoundingClientRect().left,
           canFocusInside: sb.contains(document.activeElement), active: document.activeElement.id };
})()`;

const fontProbe = `(async () => {
  await document.fonts.ready;
  const text = await document.fonts.load("17px Nunito"), headings = await document.fonts.load("600 20px Fredoka");
  return { text: text.length > 0, headings: headings.length > 0 };
})()`;

const results = {};
try {
  await send("Page.enable"); await send("Network.enable"); await send("Log.enable"); await send("Runtime.enable");

  results.layout = {};
  for (const w of [1280, 600]) { await visit(w); results.layout[w] = await evaluate(layout); }

  await visit(600);
  results.drawer = { closed: await evaluate(drawerProbe("closed")), open: await evaluate(drawerProbe("open")), reclosed: await evaluate(drawerProbe("close")) };
  await visit(1280);
  results.drawerWide = await evaluate(drawerProbe("closed"));

  await visit(1280, { scheme: "dark" });
  results.pip = {};
  for (const s of ["idle", "thinking", "talking"]) results.pip[s] = await evaluate(pipProbe(s));
  results.favicon = await evaluate(faviconProbe);
  results.fonts = await evaluate(fontProbe);
  results.warnDark = await evaluate(warnProbe);
  await visit(1280, { scheme: "dark", reduce: true });
  results.pipReduced = {};
  for (const s of ["idle", "thinking", "talking"]) results.pipReduced[s] = await evaluate(pipProbe(s));

  results.theme = {};
  await visit(1280, { scheme: "dark" });   results.theme.followsDark = await evaluate(themeProbe);
  await visit(1280, { scheme: "light" });  results.theme.followsLight = await evaluate(themeProbe);
  results.warnLight = await evaluate(warnProbe);
  results.theme.picks = [];
  for (let i = 0; i < 3; i++) { await evaluate(clickTheme); results.theme.picks.push(await evaluate(themeProbe)); }
  await visit(1280, { scheme: "light" });  await evaluate(clickTheme);   // light: the pick is "light" again, now make it dark
  await evaluate(clickTheme);
  await visit(1280, { scheme: "light", keepCookies: true });
  results.theme.remembered = await evaluate(themeProbe);

  const urls = events.filter((e) => e.method === "Network.requestWillBeSent").map((e) => e.params.request.url);
  const bad = events.filter((e) => (e.method === "Log.entryAdded" && (e.params.entry.level === "error" || e.params.entry.source === "security"))
                                  || e.method === "Runtime.exceptionThrown"
                                  || (e.method === "Runtime.consoleAPICalled" && e.params.type === "error"))
    .map((e) => JSON.stringify(e.params).slice(0, 300));
  results.requests = urls.map((u) => u.slice(0, 200)); // a data: font is tens of KB; the start says what it is
  results.problems = bad;
  console.log(JSON.stringify(results));
  done(0);
} catch (e) { console.error(String(e)); done(1); }
