# The fonts of the picture of a shared house

The NIF of `DIY.Picture` (`native/resvg`) has two fonts in its file:
Inter Regular and Inter Bold, from Inter 4.0 (the Debian package
`fonts-inter` 4.0). Each file has only the letters of English, Spanish
and Vietnamese, the digits and some signs, so it is about 85 KB.
`OFL.txt` is the license of the fonts.

To make the files again (fontTools 4.60.1):

```sh
U="U+0020-007E,U+00A0-00FF,U+0102-0103,U+0110-0111,U+0128-0129,U+0168-0169,U+01A0-01A1,U+01AF-01B0,U+0300-0303,U+0309,U+0323,U+1EA0-1EF9,U+2013-2014,U+2018-201D,U+2022,U+2026,U+20AB,U+2192,U+2212,U+00D7"
for w in Regular Bold; do
  pyftsubset /usr/share/fonts/opentype/inter/Inter-$w.otf --unicodes="$U" \
    --layout-features='kern,liga,calt,ccmp,mark,mkmk,tnum' --no-hinting \
    --output-file=native/resvg/fonts/Inter-$w.otf
done
sh scripts/nif.sh
```
