# ADIF 3.1.7 data

`all.json` is the JSON export of the ADIF 3.1.7 specification tables (fields, data types,
enumerations), released 2026-03-22. It comes from the official resources archive described
in section V.C of the specification ("Data Files Exported from ADIF Specification Tables").

- Archive: https://adif.org.uk/317/resources (downloaded 2026-10-06)
- Archive SHA-256: `1a70caf3a152c67c23ce9c4681f24b8e5f814862d8153d9a72e741375358e6d9`
- `all.json` SHA-256: `358f4b086bd68c06c89ea3d45dffd4fd5a4dd38618545e5f8cb84a758ccad52b`
- Specification: https://www.adif.org/317/ADIF_317.htm

`tests/fixtures/ADIF_317_test_QSOs_2026_03_22.adi` comes from the same archive (section V.D,
"Test QSO Files based on ADIF Specification Tables").

`ADIF_317.htm` is the specification itself, used for each field's brief description: the
first paragraph of its description cell. The JSON export runs a description and its notes
together ("QSO Submode use enumeration values for interoperability"); the HTML keeps them
apart.

- Downloaded from https://www.adif.org/317/ADIF_317.htm on 2026-10-06
- SHA-256: `b766703277e952e6b548ccdc73e32ff16e10f84c060be616cf110449eddc5c97`

`tools/gen_spec_tables.py` turns `all.json` and `ADIF_317.htm` into `src/core/adif_spec_317.cpp`.
