# ADIF 3 versions

`adif-history.json` records which ADIF 3 versions have each field, data type, enumeration,
enumeration value and band edge, as bit masks over `versions` (bit 0 is 3.0.2), with the
data types fields had in older versions. ADIF Lint checks a log against the version chosen in
Settings (3.1.8 unless you choose another).

It is built by `tools/adif_history.py` from the specification pages, read by
`tools/adif_spec_html.py`. ADIF publishes its tables as files only from 3.1.5 on, so the pages
are the source for every version alike. The reader is tested against those files: what it
reads from the 3.1.6, 3.1.7 and 3.1.8 pages equals their JSON exports, and from 3.1.5 its XML
export (bar two "replaced by" notes the 3.1.5 export left out). ADIF 3.0.0 and 3.0.1 were never
published; adif.org lists 3.0.2 onward.

The pages, downloaded on 2026-10-26 (SHA-256):

| Version | Page | SHA-256 |
|---|---|---|
| 3.0.2 | https://adif.org.uk/302/ADIF%20302.htm | `96ce84f466ff72a4e1f8697b21a0617487b6e8fde3557e93ca7ebae8ec068b6e` |
| 3.0.3 | https://adif.org.uk/303/ADIF%20303.htm | `4d76c728af195752e60c21d00e49888e6f08e04d86d4423c15cc51826c94fab2` |
| 3.0.4 | https://adif.org.uk/304/ADIF_304.htm | `4a4f97d0dd32f46a29072511916fd0fb20f3d912c265cb90690677a1da33e5fd` |
| 3.0.5 | https://adif.org.uk/305/ADIF_305.htm | `2cca6e6b15eb2fb42bba895c9a384daeceec88508ff69be091cadd823ed7a88a` |
| 3.0.6 | https://adif.org.uk/306/ADIF_306.htm | `f52d0127a3cf003846e1293a583394256b4c354833b2c0c783c9195f70531efa` |
| 3.0.7 | https://adif.org.uk/307/ADIF_307.htm | `5afd82316363614c28dc9ce2255442597978ec3343a47e62828c68d8fb3ba7f0` |
| 3.0.8 | https://adif.org.uk/308/ADIF_308.htm | `363596c2b7d34885e501c2d735ac04a7020c6fb5d5605308356316a0106c0eeb` |
| 3.0.9 | https://adif.org.uk/309/ADIF_309.htm | `fff818a8ac2075ae46fd94fd6b205ccc8a232c3d3504e4174b22c5004c9ab59e` |
| 3.1.0 | https://adif.org.uk/310/ADIF_310.htm | `0ae7979299e29282483652475bf2df1b9e9392f788d51df89bfe5708a7f4aa6a` |
| 3.1.1 | https://adif.org.uk/311/ADIF_311.htm | `61bf57ee54d7d26d068ccf85fce9485962ccb3457772a9f1b1ff77c5c7cdcd8c` |
| 3.1.2 | https://adif.org.uk/312/ADIF_312.htm | `33996c7dc6bd5c9d5f1a38730551919b3f021dff2807aadae0d84a0c368e0485` |
| 3.1.3 | https://adif.org.uk/313/ADIF_313.htm | `be12ee40a54720d12337d0725cc55b1b80d383df87d4c0ef7419626342175c00` |
| 3.1.4 | https://adif.org.uk/314/ADIF_314.htm | `aec24e955726fe987f1a6e7a6ff31fd790280c9dfa8c9fe9c8e16e0d75e536a2` |
| 3.1.5 | https://adif.org.uk/315/ADIF_315.htm | `6f53617af839cb98689559189d33c029b7e987aabb86d80f0f3e1640e3237790` |
| 3.1.6 | https://adif.org.uk/316/ADIF_316.htm | `c33ee99cc555076be9d280614e3dca55db1e577946be18ce272b3277859f6437` |
| 3.1.7 | https://adif.org.uk/317/ADIF_317.htm | `b766703277e952e6b548ccdc73e32ff16e10f84c060be616cf110449eddc5c97` |
| 3.1.8 | https://adif.org.uk/318/ADIF_318.htm | `9d130f558125fbbf4d1da93c4fb8d63dda859914ffeb54416627f093afcf7fe6` |

The exports the reader was compared with (same day): https://adif.org.uk/315/ADIF_315_resources_2024_11_28.zip
(`3fff0fe8…`), https://adif.org.uk/316/ADIF_316_resources_2025_09_15.zip (`8036c8a4…`),
https://adif.org.uk/317/ADIF_317_resources_2026_03_22.zip (`1a70caf3…`, as in the 3.1.7 data) and
https://adif.org.uk/318/ADIF_318_resources_2026_10_12.zip (`d211e1d4…`).

What is recorded, and what isn't:

- Fields, data types, enumerations and their values by version, with each version's
  import-only items (3.0.2 to 3.0.5 call them "deprecated"). A value is told apart by its
  value, its scope (a submode's mode, a subdivision's or region's DXCC entity) and its validity
  dates, so a subdivision renamed with a new date range is two values.
- A field's data type where an older version gave another (CQZ was a Number until 3.0.5).
  Older pages don't mark a field's enumeration or range in their tables, so those follow 3.1.8.
- Band edges by version (30m was 10.0 to 10.15 MHz until 3.0.4).
- Descriptions, notes and validity dates follow 3.1.8.

To rebuild it: download the pages above into a folder, check them against the hashes, then run
`python3 -I tools/adif_history.py FOLDER spec/adif-history.json` and
`python3 -I tools/gen_spec_tables.py`. Each `--compare` in `tools/adif_spec_html.py` checks a page
against an export.
