#!/usr/bin/env node
// paraloop -- web postbuild (task 1.7).
//
// Finishes a wasm build in --dir (default tmp/web): one directory holds one
// game, `<base>.js` + `<base>.wasm` from build.sh.
//   1. renders `index.html` from src/paraloop/web/shell_minimal.html --
//      substituting the title and theme markers and the script tag -- and
//      stamps the build id into it as `<meta name="paraloop-build">` and as
//      small visible text (`#buildinfo`), with a "Send feedback" link beside
//      it when --feedback-url is given;
//   2. writes the PWA manifest (src/paraloop/web/webshell/manifest.webmanifest) and copies the
//      icons next to the build;
//   3. writes `build.json` (id, commit, mode, defines, title), which
//      `para web pack` reads.
//
// The build id is `<short commit>[-dirty]-<release|debug>[-<define>...]`: no
// timestamp, so a rebuild of the same commit stamps the same bytes. The
// commit comes from `git` (or `nogit` outside a checkout).
//
// Title/theme sources, in order: CLI flag, environment (PARALOOP_WEB_TITLE /
// PARALOOP_WEB_THEME), default. Node 22+, zero npm deps.
//
// --feedback-url URL (http or https; empty means none) adds the link, opening
// URL with the build id appended as a `build` query parameter, so a report
// says which build it is about. Without it the page carries no link at all.
//
//   node tools/web/postbuild.mjs --dir tmp/web/hello --title "My Game" --theme "#29331f" \
//        [--mode release|debug] [--define NAME[=VALUE]]... [--feedback-url https://forms.example/x]

import fs from "node:fs";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";

function opt(name, def = undefined) {
  const i = process.argv.indexOf(`--${name}`);
  return i >= 0 && i + 1 < process.argv.length ? process.argv[i + 1] : def;
}

function opts(name) {
  const out = [];
  process.argv.forEach((a, i) => {
    if (a === `--${name}` && i + 1 < process.argv.length) out.push(process.argv[i + 1]);
  });
  return out;
}

const dir = path.resolve(opt("dir", "tmp/web"));
const shellDir = fileURLToPath(new URL("../../src/paraloop/web", import.meta.url));
const repoRoot = fileURLToPath(new URL("../..", import.meta.url));
const mode = opt("mode", "release");
const defines = opts("define").sort();
const title = opt("title") ?? process.env.PARALOOP_WEB_TITLE ?? "paraloop";
const theme = opt("theme") ?? process.env.PARALOOP_WEB_THEME ?? "#29331f";
const feedbackUrl = opt("feedback-url", "").trim();
let touched = [];
let failed = false;

const say = (m) => console.log(m);
const fail = (m) => { failed = true; say(`FAIL ${m}`); };

if (!["release", "debug"].includes(mode)) { say(`FAIL --mode must be release or debug, got "${mode}"`); process.exit(1); }

function git(...args) {
  try {
    return execFileSync("git", args, { cwd: repoRoot, encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim();
  } catch { return null; }
}
const commit = git("rev-parse", "--short=7", "HEAD");
const dirty = commit !== null && git("status", "--porcelain", "--untracked-files=no") !== "";
const buildId =
  [commit ?? "nogit", ...(dirty ? ["dirty"] : []), mode, ...defines.map((d) => d.replace(/[=:]/g, "_"))].join("-");

if (!fs.existsSync(dir)) fail(`output dir not found: ${dir}`);

// The feedback link's href: the form URL with `build=<id>` appended (before
// any #fragment), only for a plain http(s) URL -- never a javascript: one.
let feedbackHref = null;
if (process.argv.includes("--feedback-url") && opt("feedback-url") === undefined) {
  fail("--feedback-url needs a URL");
} else if (feedbackUrl !== "") {
  let ok = false;
  try { ok = ["http:", "https:"].includes(new URL(feedbackUrl).protocol); } catch { /* not a URL */ }
  if (!ok) {
    fail("--feedback-url must be an http(s) URL");
  } else {
    const [head, ...frag] = feedbackUrl.split("#");
    feedbackHref = `${head}${head.includes("?") ? "&" : "?"}build=${encodeURIComponent(buildId)}` +
      (frag.length ? `#${frag.join("#")}` : "");
  }
}

function render(template, dst, fn, what) {
  try {
    const src = fs.readFileSync(path.join(shellDir, template), "utf8");
    const out = fn(src);
    fs.mkdirSync(path.dirname(dst), { recursive: true });
    fs.writeFileSync(dst, out);
    touched.push(path.relative(dir, dst));
  } catch (e) { fail(`${what}: ${e.message}`); }
}

// 0. emcc may name the js without an extension (nim -o:dir/base); normalize.
const all = fs.existsSync(dir) ? fs.readdirSync(dir) : [];
for (const f of all) {
  const p = path.join(dir, f);
  if (!f.includes(".") && !f.startsWith(".") && fs.statSync(p).isFile()) {
    fs.renameSync(p, `${p}.js`);
    say(`normalize ${f} -> ${f}.js`);
  }
}

// 1. the host page (the template's script marker takes the js name).
let jss = [];
if (fs.existsSync(dir)) {
  jss = fs.readdirSync(dir)
    .filter((f) => f.endsWith(".js") && !f.startsWith(".") && !f.includes(".map"))
    .map((f) => path.basename(f, ".js"))
    .sort();
}
const htmlText = (v) => v.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);
const jsonText = (v) => JSON.stringify(v).slice(1, -1);
const base = jss[0];
if (jss.length !== 1) {
  if (!failed) fail(`expected exactly one <game>.js in ${dir} (one game per output dir), found ${jss.length}: ${jss.join(", ") || "none"}`);
} else {
  render("shell_minimal.html", path.join(dir, "index.html"), (s) =>
    s.replaceAll("__PARALOOP_TITLE__", () => htmlText(title))
     .replaceAll("__PARALOOP_THEME__", () => htmlText(theme))
     .replaceAll("{{PARALOOP_SCRIPT}}", () => `<script src="${base}.js"></script>`)
     .replaceAll("{{PARALOOP_BUILDINFO}}", () =>
       `<div id="buildinfo"><span id="buildid">${htmlText(buildId)}</span>` +
       (feedbackHref === null ? "" :
         `<a id="feedback" href="${htmlText(feedbackHref)}" target="_blank" rel="noopener noreferrer">Send feedback</a>`) +
       `</div>`)
     .replace("</head>", () => `<meta name="paraloop-build" content="${htmlText(buildId)}">\n</head>`),
    "index.html");
}

// 2. manifest + icons.
render("webshell/manifest.webmanifest", path.join(dir, "manifest.webmanifest"), (s) =>
  s.replaceAll("__PARALOOP_TITLE__", () => jsonText(title))
   .replaceAll("__PARALOOP_THEME__", () => jsonText(theme)),
  "manifest.webmanifest");
for (const icon of ["icon-192.png", "icon-512.png"]) {
  try {
    fs.copyFileSync(path.join(shellDir, "webshell", icon), path.join(dir, icon));
    touched.push(icon);
  } catch (e) { fail(`icon ${icon}: ${e.message}`); }
}

if (base !== undefined && !failed) {
  const info = { game: base, id: buildId, commit, dirty, mode, defines, title };
  try {
    fs.writeFileSync(path.join(dir, "build.json"), JSON.stringify(info, null, 2) + "\n");
    touched.push("build.json");
  } catch (e) { fail(`build.json: ${e.message}`); }
}

say(`build ${buildId}`);
say(failed ? "postbuild failed"
  : touched.length ? `postbuild ok (updated: ${touched.join(", ")})` : "postbuild ok (nothing to update)");
if (failed) process.exit(1);
