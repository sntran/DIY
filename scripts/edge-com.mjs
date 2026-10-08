// Writes edge.com: the part of app.com that a Worker reads, for the upload
// of Cloudflare Workers (a Worker can be at most 64 MiB). app.com is the
// native program of beam.com (about 25 MB), then a zip with the release.
// The runtime of the npm package (runtime/app-com.js) reads only the
// entries of the release in the zip: lib/, releases/ and .wasm/. edge.com
// is a zip with only these entries, with the same bytes, at new offsets.
// The snapshot of the build is the same for the two files: its key is the
// release (snapshot_key of .wasm/.release.json), not the file.
// Node.js 26, with no packages.
//
//   node scripts/edge-com.mjs [app.com [edge.com]]

import { readFileSync, writeFileSync } from 'node:fs';

const LOCAL = 0x04034b50, CENTRAL = 0x02014b50, END = 0x06054b50;
const inRelease = (name) => name.startsWith('lib/') || name.startsWith('releases/') || name.startsWith('.wasm/');

const fail = (message) => { throw new Error(`edge-com: ${message}`); };

// The zip of the release in app (a Uint8Array), as a new Uint8Array.
export function edge(app) {
  const v = new DataView(app.buffer, app.byteOffset, app.byteLength);
  // The end of central directory record: the last one, with no comment
  // after the file of beam.com.
  let e = app.length - 22;
  while (e >= 0 && v.getUint32(e, true) !== END) e--;
  if (e < 0) fail('no end of central directory: app.com is not a zip');
  const count = v.getUint16(e + 10, true), cdAt = v.getUint32(e + 16, true);
  if (count === 0xffff || cdAt === 0xffffffff) fail('a zip64 file is not supported');

  const kept = [];
  for (let i = cdAt, k = 0; k < count; k++) {
    if (v.getUint32(i, true) !== CENTRAL) fail('a bad central directory');
    const flags = v.getUint16(i + 8, true);
    const nlen = v.getUint16(i + 28, true), xlen = v.getUint16(i + 30, true), clen = v.getUint16(i + 32, true);
    const size = 46 + nlen + xlen + clen;
    const name = new TextDecoder().decode(app.subarray(i + 46, i + 46 + nlen));
    if (inRelease(name)) {
      // A data descriptor would come after the data, with no length in the
      // local header. The zip of beam.com has none.
      if (flags & 8) fail(`${name}: a data descriptor is not supported`);
      kept.push({ central: app.subarray(i, i + size), offset: v.getUint32(i + 42, true), csize: v.getUint32(i + 20, true) });
    }
    i += size;
  }
  if (!kept.length) fail('no entries of the release');

  // Each local header and its data, in the order of the file.
  kept.sort((a, b) => a.offset - b.offset);
  const parts = [];
  let at = 0;
  for (const k of kept) {
    const h = k.offset;
    if (v.getUint32(h, true) !== LOCAL) fail('no local header');
    const local = app.subarray(h, h + 30 + v.getUint16(h + 26, true) + v.getUint16(h + 28, true) + k.csize);
    k.at = at;
    parts.push(local);
    at += local.length;
  }
  const cdStart = at;
  for (const k of kept) {
    const c = Uint8Array.from(k.central);
    new DataView(c.buffer).setUint32(42, k.at, true);
    parts.push(c);
    at += c.length;
  }
  const end = new Uint8Array(22);
  const ev = new DataView(end.buffer);
  ev.setUint32(0, END, true);
  ev.setUint16(8, kept.length, true);
  ev.setUint16(10, kept.length, true);
  ev.setUint32(12, at - cdStart, true);
  ev.setUint32(16, cdStart, true);
  parts.push(end);

  const out = new Uint8Array(at + 22);
  let i = 0;
  for (const p of parts) { out.set(p, i); i += p.length; }
  return out;
}

if (import.meta.main) {
  const [from = 'app.com', to = 'edge.com'] = process.argv.slice(2);
  const app = readFileSync(from);
  const out = edge(app);
  writeFileSync(to, out);
  console.log(`edge-com: ${to}: ${out.length} bytes (${from}: ${app.length} bytes)`);
}
