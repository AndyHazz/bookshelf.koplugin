# Bundled fonts

Bookshelf bundles these open-licensed fonts. Each is redistributed under its own
license (included in this folder). The fonts are licensed independently of the
Bookshelf plugin's own license.

| Font | Weight(s) | License | Source |
|------|-----------|---------|--------|
| Roboto Condensed | Regular, Bold, Italic, Bold Italic | Apache License 2.0 (`Apache-2.0-Roboto.txt`) | https://fonts.google.com/specimen/Roboto+Condensed |
| Inter ExtraBold | ExtraBold (800) | SIL Open Font License 1.1 (`OFL-Inter.txt`) | https://github.com/rsms/inter |
| Caveat | Regular | SIL Open Font License 1.1 (`OFL-Caveat.txt`) | https://github.com/googlefonts/caveat |

**Modification note:** `Inter-ExtraBold.ttf` is derived from the upstream Inter variable
font, instantiated at the ExtraBold (weight 800) / text (opsz 14) point, then subset to
the language scripts a book-title font needs (Latin including Latin Extended, Vietnamese,
Greek and Cyrillic; non-linguistic symbol blocks dropped). Its name table is rewritten to a
standalone family ("Inter ExtraBold") so it registers as its own family rather than
collapsing under "Inter". Inter's OFL declares no Reserved Font Name, so this modified copy
is compliant.
