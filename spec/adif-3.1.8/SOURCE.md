# ADIF 3.1.8 data

`all.json` is the JSON export of the ADIF 3.1.8 specification tables (fields, data types,
enumerations), released 2026-10-12. It comes from the official resources archive described
in section V.C of the specification ("Data Files Exported from ADIF Specification Tables").

- Archive: https://adif.org.uk/318/ADIF_318_resources_2026_10_12.zip (downloaded 2026-10-26)
- Archive SHA-256: `d211e1d41adaf7fc341c73a8a3a56c343534aac57043b7474f7df2d528e56d8c`
- `all.json` SHA-256: `f413cdfa0a779745ebaf546bf416c12a3b44625e340e6d5ab0ce3b1d89fcd37b`
- Specification: https://adif.org/318/ADIF_318.htm

`tests/fixtures/ADIF_318_test_QSOs_2026_10_12.adi` comes from the same archive (section V.D,
"Test QSO Files based on ADIF Specification Tables"); SHA-256
`113369e5c226f090e2caf7db38b3bc6c642054ec4ae8f5b30101a3579a7623b1`.

`ADIF_318.htm` is the specification itself, used for each field's brief description: the
first paragraph of its description cell. The JSON export runs a description and its notes
together ("QSO Submode use enumeration values for interoperability"); the HTML keeps them
apart.

- Downloaded from https://adif.org.uk/318/ADIF_318.htm on 2026-10-26
- SHA-256: `9d130f558125fbbf4d1da93c4fb8d63dda859914ffeb54416627f093afcf7fe6`

`tools/gen_spec_tables.py` turns `all.json`, `ADIF_318.htm` and `../adif-history.json` into
`src/core/adif_spec_tables.cpp`.
