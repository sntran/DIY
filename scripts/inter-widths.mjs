// Writes priv/picture/inter_widths.json: the width of each letter of the
// fonts of the NIF of the picture (native/resvg/fonts), in parts of the
// size of the font. Each row is [code point, width]. The width is the
// width of the letter in Inter Regular or in Inter Bold, the larger one.
// DIYWeb.Picture gives each label the width of its text with these
// widths (docs/design.md, "The preview of a link").
//
//   node scripts/inter-widths.mjs
//
// The script reads the tables cmap and hmtx of each OTF file.
import { readFileSync, writeFileSync } from "node:fs"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"

const root = join(dirname(fileURLToPath(import.meta.url)), "..")
const fonts = join(root, "native/resvg/fonts")
const out = join(root, "priv/picture/inter_widths.json")

// The width of each code point of an OTF file.
function widths(file) {
  const b = readFileSync(file)
  const tables = {}
  for (let i = 0; i < b.readUInt16BE(4); i++) {
    const at = 12 + 16 * i
    tables[b.toString("latin1", at, at + 4)] = b.readUInt32BE(at + 8)
  }
  const units = b.readUInt16BE(tables.head + 18)
  const metrics = b.readUInt16BE(tables.hhea + 34)
  const advance = (glyph) => b.readUInt16BE(tables.hmtx + 4 * Math.min(glyph, metrics - 1))
  const glyphs = new Map()
  const cmap = tables.cmap
  for (let i = 0; i < b.readUInt16BE(cmap + 2); i++) {
    const at = cmap + b.readUInt32BE(cmap + 8 + 8 * i)
    const format = b.readUInt16BE(at)
    if (format === 12) {
      for (let g = 0; g < b.readUInt32BE(at + 12); g++) {
        const row = at + 16 + 12 * g
        const [first, last, glyph] = [b.readUInt32BE(row), b.readUInt32BE(row + 4), b.readUInt32BE(row + 8)]
        for (let c = first; c <= last; c++) glyphs.set(c, glyph + c - first)
      }
    } else if (format === 4) {
      const size = b.readUInt16BE(at + 6)
      const ends = at + 14, starts = ends + size + 2, deltas = starts + size, offsets = deltas + size
      for (let s = 0; s < size / 2; s++) {
        const [last, first] = [b.readUInt16BE(ends + 2 * s), b.readUInt16BE(starts + 2 * s)]
        const [delta, offset] = [b.readInt16BE(deltas + 2 * s), b.readUInt16BE(offsets + 2 * s)]
        for (let c = first; c <= last && c !== 0xffff; c++) {
          // With no offset, the glyph is the code point plus the delta.
          // Else the array of glyphs gives an index, and 0 is no glyph.
          const index = offset === 0 ? c : b.readUInt16BE(offsets + 2 * s + offset + 2 * (c - first))
          const glyph = index === 0 ? 0 : (index + delta) & 0xffff
          if (glyph) glyphs.set(c, glyph)
        }
      }
    }
  }
  return new Map([...glyphs].map(([c, glyph]) => [c, advance(glyph) / units]))
}

const regular = widths(join(fonts, "Inter-Regular.otf"))
const bold = widths(join(fonts, "Inter-Bold.otf"))
const rows = [...new Set([...regular.keys(), ...bold.keys()])]
  .filter((c) => c >= 0x20)
  .sort((a, b) => a - b)
  .map((c) => [c, Math.ceil(Math.max(regular.get(c) ?? 0, bold.get(c) ?? 0) * 1000) / 1000])
writeFileSync(out, JSON.stringify(rows) + "\n")
console.log(`${rows.length} letters in ${out}`)
