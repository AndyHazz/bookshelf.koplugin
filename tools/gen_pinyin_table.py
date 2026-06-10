#!/usr/bin/env python3
"""Generate the SYL/DATA tables in lib/bookshelf_pinyin.lua from Unihan.

Input: Unihan_Readings.txt from the Unicode Unihan database
(https://www.unicode.org/Public/UCD/latest/ucd/Unihan.zip), passed as the
first argument. Output: bookshelf_pinyin_data.inc next to this script --
paste its contents over the SYL/DATA block in lib/bookshelf_pinyin.lua
(between the module header and the runtime code).

Encoding: for each codepoint in U+4E00..U+9FFF (CJK Unified Ideographs URO),
store a 2-character base64-alphabet index into a toneless-syllable array.
Index 0 = no reading. Runtime does string.byte math on the packed string, so
no 21k-entry Lua table is ever materialised.
"""
import os
import re
import sys
import unicodedata

LO, HI = 0x4E00, 0x9FFF
ALPHA = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

def strip_tones(s: str) -> str:
    # NFD-decompose, drop combining marks, u-umlaut becomes plain u for
    # sort purposes (lü ties with lu, codepoint tie-break separates them).
    out = []
    for ch in unicodedata.normalize("NFD", s):
        if unicodedata.combining(ch):
            continue
        out.append(ch)
    return "".join(out).lower()

readings = {}
pat = re.compile(r"^U\+([0-9A-F]+)\tkMandarin\t(\S+)")
with open(sys.argv[1], encoding="utf-8") as f:
    for line in f:
        m = pat.match(line)
        if not m:
            continue
        cp = int(m.group(1), 16)
        if not (LO <= cp <= HI):
            continue
        # field can be "zhōng zhòng" style multi-value; first = preferred
        syl = strip_tones(m.group(2).split()[0])
        if not syl.isascii() or not syl.isalpha():
            continue
        readings[cp] = syl

syls = sorted(set(readings.values()))
assert len(syls) < 64 * 64 - 1, f"too many syllables: {len(syls)}"
idx_of = {s: i + 1 for i, s in enumerate(syls)}  # 0 reserved = no reading

packed = []
covered = 0
for cp in range(LO, HI + 1):
    i = idx_of.get(readings.get(cp), 0)
    if i:
        covered += 1
    packed.append(ALPHA[i // 64] + ALPHA[i % 64])
packed = "".join(packed)

print(f"codepoints: {HI - LO + 1}, with reading: {covered}, syllables: {len(syls)}")
print(f"packed bytes: {len(packed)}")

# Emit Lua: syllable array + packed string in 80-col chunks.
chunks = [packed[i:i + 100] for i in range(0, len(packed), 100)]
syl_lines = []
line = "    "
for s in syls:
    piece = f'"{s}",'
    if len(line) + len(piece) > 78:
        syl_lines.append(line)
        line = "    "
    line += piece
syl_lines.append(line)

out_path = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                        "bookshelf_pinyin_data.inc")
with open(out_path, "w", encoding="utf-8") as f:
    f.write("local SYL = {\n" + "\n".join(syl_lines) + "\n}\n\n")
    f.write('local DATA = table.concat({\n')
    for c in chunks:
        f.write(f'"{c}",\n')
    f.write("})\n")
print(f"wrote {out_path}")
