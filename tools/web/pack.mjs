#!/usr/bin/env node
// paraloop -- web pack (web build tooling).
//
// Zips a finished web build (build.sh + postbuild.mjs) into exactly what a
// static host needs: `index.html`, `<game>.js`, `<game>.wasm`,
// `manifest.webmanifest` and the two icons. Anything else in --dir (build.json,
// a stale file from another build) is left out and named in the output.
//
// The zip is reproducible: entries sorted by name, a fixed 1980-01-01 time
// stamp, no extra fields, deflate level 9. Packing the same build twice gives
// the same bytes, and so does a rebuild of the same commit (the build itself
// carries no timestamp).
//
//   node tools/web/pack.mjs --dir tmp/web/mygame --out tmp/web/mygame-<id>.zip
//
// Prints `file  <name>  <bytes>` per entry and a final `zip  <path>  <bytes>
// sha256 <hex>` line. Exit 1 when a required file is missing. Node 22+, zero
// npm deps.

import fs from "node:fs";
import path from "node:path";
import zlib from "node:zlib";
import crypto from "node:crypto";

function opt(name, def = undefined) {
  const i = process.argv.indexOf(`--${name}`);
  return i >= 0 && i + 1 < process.argv.length ? process.argv[i + 1] : def;
}

const die = (m) => { console.error(`FAIL ${m}`); process.exit(1); };

const dir = path.resolve(opt("dir", "tmp/web"));
const out = opt("out");
if (!out) die("--out PATH is required");
if (!fs.existsSync(dir)) die(`build dir not found: ${dir}`);

let game;
try {
  game = JSON.parse(fs.readFileSync(path.join(dir, "build.json"), "utf8")).game;
} catch (e) { die(`build.json unreadable in ${dir} (${e.message}) -- run postbuild first`); }
if (typeof game !== "string" || !/^[A-Za-z0-9_.-]+$/.test(game)) die(`build.json has no usable game name`);

const wanted = ["index.html", `${game}.js`, `${game}.wasm`, "manifest.webmanifest", "icon-192.png", "icon-512.png"];
const missing = wanted.filter((f) => !fs.existsSync(path.join(dir, f)));
if (missing.length) die(`missing from ${dir}: ${missing.join(", ")}`);
const html = fs.readFileSync(path.join(dir, "index.html"), "utf8");
if (!html.includes(`<script src="${game}.js"></script>`)) die(`index.html does not load ${game}.js`);

// ---------------------------------------------------------------- zip writer

const CRC = new Uint32Array(256).map((_, n) => {
  let c = n;
  for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
  return c >>> 0;
});
const crc32 = (buf) => {
  let c = 0xffffffff;
  for (const b of buf) c = CRC[(c ^ b) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
};

const DOS_TIME = 0, DOS_DATE = (0 << 9) | (1 << 5) | 1; // 1980-01-01 00:00:00
const parts = [], central = [];
let offset = 0;
for (const name of [...wanted].sort()) {
  const raw = fs.readFileSync(path.join(dir, name));
  const packed = zlib.deflateRawSync(raw, { level: 9 });
  const nameBuf = Buffer.from(name, "utf8");
  const crc = crc32(raw);

  const local = Buffer.alloc(30);
  local.writeUInt32LE(0x04034b50, 0);
  local.writeUInt16LE(20, 4);            // version needed
  local.writeUInt16LE(0x0800, 6);        // flags: names are UTF-8
  local.writeUInt16LE(8, 8);             // deflate
  local.writeUInt16LE(DOS_TIME, 10);
  local.writeUInt16LE(DOS_DATE, 12);
  local.writeUInt32LE(crc, 14);
  local.writeUInt32LE(packed.length, 18);
  local.writeUInt32LE(raw.length, 22);
  local.writeUInt16LE(nameBuf.length, 26);
  parts.push(local, nameBuf, packed);

  const cen = Buffer.alloc(46);
  cen.writeUInt32LE(0x02014b50, 0);
  cen.writeUInt16LE(0x031e, 4);          // made by: unix, 3.0
  cen.writeUInt16LE(20, 6);
  cen.writeUInt16LE(0x0800, 8);
  cen.writeUInt16LE(8, 10);
  cen.writeUInt16LE(DOS_TIME, 12);
  cen.writeUInt16LE(DOS_DATE, 14);
  cen.writeUInt32LE(crc, 16);
  cen.writeUInt32LE(packed.length, 20);
  cen.writeUInt32LE(raw.length, 24);
  cen.writeUInt16LE(nameBuf.length, 28);
  cen.writeUInt32LE(((0o100644 << 16) >>> 0), 38); // external attrs: -rw-r--r--
  cen.writeUInt32LE(offset, 42);
  central.push(cen, nameBuf);

  offset += local.length + nameBuf.length + packed.length;
  console.log(`file  ${name}  ${raw.length}`);
}
const centralBuf = Buffer.concat(central);
const end = Buffer.alloc(22);
end.writeUInt32LE(0x06054b50, 0);
end.writeUInt16LE(wanted.length, 8);
end.writeUInt16LE(wanted.length, 10);
end.writeUInt32LE(centralBuf.length, 12);
end.writeUInt32LE(offset, 16);
const zip = Buffer.concat([...parts, centralBuf, end]);

fs.mkdirSync(path.dirname(path.resolve(out)), { recursive: true });
fs.writeFileSync(out, zip);

const left = fs.readdirSync(dir).filter((f) => !wanted.includes(f) && fs.statSync(path.join(dir, f)).isFile());
if (left.length) console.log(`left out  ${left.join(", ")}`);
console.log(`zip  ${out}  ${zip.length}  sha256 ${crypto.createHash("sha256").update(zip).digest("hex")}`);
