# ADX XML Schemas

The ADX schemas published with each ADIF version since 3.0.3, unmodified: for each version an
export schema (`adxNNN.xsd`, which disallows deprecated features) and a generic schema
(`adxNNNgeneric.xsd`, for importing when the ADIF version isn't known in advance, which allows
them). ADIF 3.0.2 and earlier publish none. Specification §IV.B.5 and §V.A point to them; each
schema's annotation documents its scope and the checks XML Schema 1.0 can't express.

- Downloaded from `https://www.adif.org/NNN/adxNNN.xsd` and `https://www.adif.org/NNN/adxNNNgeneric.xsd`
  on 2026-11-01 (NNN the version as three digits: 303 to 318, 16 versions).
- Licence: each schema's annotation marks it CC0 1.0 Universal (by Graham Smith).

| File | SHA-256 |
|---|---|
| adx303.xsd | `732e0ef6e0ce47577c1c7eabb8c4c8ea5993a8e709802376a0a3d8bece853ca8` |
| adx303generic.xsd | `158180d1dd509b066181dd8a5a4443456aca3dc70560e9cb7b6fd7f432a11a01` |
| adx304.xsd | `01241a9780bc931a7434ff1bb2646909cdfbbd6994bb27f8401912ff7621faf9` |
| adx304generic.xsd | `8ac1cbe84db9f13f87b9ceb100ea0d9205f06d1dc943fdf611f9807286e2d071` |
| adx305.xsd | `18311cfc6a0d41964fb0156d76d59112ca0119becbd155bf30c450bab49a2393` |
| adx305generic.xsd | `28286d28f77df14800c57256a451db3b30119e03139cf65e5031870a1954579b` |
| adx306.xsd | `c9ec2659e0cfabbbea89abdc94b50e1fe9d73f6efec4239819a98addaf2919dc` |
| adx306generic.xsd | `583a9b308da449960369a46c336554b9fcc93b16567ecd66a726ff4bf9123393` |
| adx307.xsd | `4091c937e98d1bad69253c7122cecb5ef0b39f8cc4ea810041c741e26cf91d56` |
| adx307generic.xsd | `d2b3d440da1fac8859dae2b6d6fc4eede56d94b38fd16cde54d8029d1d3e35a7` |
| adx308.xsd | `1bf6251e5602735bcce05cb74c94a6205311a310d787659b7693c05e23f233ab` |
| adx308generic.xsd | `31daf816518401049dbb0e595207ba557ecd4e178aaa4a720ab5e05953a12158` |
| adx309.xsd | `6823c66f74318a34be9b7730881c5cc2c093e77656b6f54aa956b727db775460` |
| adx309generic.xsd | `4a5d165d7c8545f126f584ad68d17aaa57fc4aaa3ac6e7265f9447eeb0209f5d` |
| adx310.xsd | `28ef475a00615e31ac7583ee35e3eacdccc94fb43a5a08057db6c5bcd7c2bde7` |
| adx310generic.xsd | `1dafe89156078f9c0a40f5c3641f6d0284c23eb154e19cc9755c9e46198a7c60` |
| adx311.xsd | `45e54e83afdda15a73fb532ddd573366071a6d1bcc5eb6b943985c9cd114c7df` |
| adx311generic.xsd | `d0be39ef11c4df72faeef468efedac42bc078ec0229accd1888597fed020e7d8` |
| adx312.xsd | `69f7c845bd4ba2a5f90505d0974dffade9dda3d1b435f412fb045108f545b43a` |
| adx312generic.xsd | `9b777c403a3d9787a803a6bcab5fa8dc165f4210146025454f01fc295c651a61` |
| adx313.xsd | `833c5d8ec1956ae80b4a9db8a5d81b5ce85992b1bd93e5b01cddccd9f3365aef` |
| adx313generic.xsd | `7d96fb5fcc54bf1cdd065081900b45dd183d86d08d2b37debd37aa1d345df8ef` |
| adx314.xsd | `90bd0f99e73418e6f2a89e631b4d0350b10471b53067453993e404df02694b78` |
| adx314generic.xsd | `4ff7b8620f304dabecc923467510b3476f11b9bc34c6fcc4376f96ff05f9e91d` |
| adx315.xsd | `6dd681dfc6d8547b8d20502f457fa9153db8da6f896166ec7d98400bf8fc30be` |
| adx315generic.xsd | `92a89145d872625ec2aef8b564005c3bf49e4c3f04368153a070f29fc4301580` |
| adx316.xsd | `b478e0cfec4d7fb81a95465d58c3306dc3985709d1f6fa572f989dfa111b4e03` |
| adx316generic.xsd | `53cc34023fe35985e56ddd1883bae7025058d5b7023f029f26d72bc523782278` |
| adx317.xsd | `ce7a86832f7be4a232d2c1ae7432925feb2be8506cba24345b7e3ad994a87331` |
| adx317generic.xsd | `be7842c5f50226aa7231ecccd95946d333d37ceb418f05e827b49b4e5cfb17c9` |
| adx318.xsd | `306f9bc6ddceb3fb8a8a3b437f8ae15d593f326ebba348345c7b3011851d812c` |
| adx318generic.xsd | `80965585ee6b0b36533f67e8262c68aa3b1dc3f53e50d8287b614da5392c7470` |

`tests/fixtures/ADIF_318_test_QSOs_2026_10_12.adx` comes from the 3.1.8 resources archive
(`spec/adif-3.1.8/SOURCE.md`, section V.D of the specification): 6,202 QSOs, every field and
value; SHA-256 `81f0ab15f246e483b930543f1a3efd65aa3b1a880e772e76a2f7402fb38e3eeb`.

## The one change made when they are built in

The schemas for 3.1.5 to 3.1.8 (export and generic alike) each have one pattern that isn't XML
Schema 1.0: CNTY_ALT's (`Secondary_Administrative_Subdivision_Enumeration_Alt`) uses a
look-ahead, `[ \-](?=[a-zA-Z])`, for "a space or dash provided that it is followed by a letter".
Look-ahead isn't part of XML Schema 1.0's regular expressions (XML Schema Part 2, Appendix F),
so a conforming processor such as libxml2 refuses the whole schema ("failed to compile"); the
schemas' annotation points to .NET's regular expressions, which have it.

`tools/gen_adx_schemas.py` embeds the files here into `src/core/adif_adx_schemas.cpp` and
replaces that one type with two restriction steps that mean the same thing in XML Schema 1.0.
Pattern facets on different derivation steps must all match (XML Schema Part 2, §4.3.4.3), so:

```xml
<xs:simpleType name="Secondary_Administrative_Subdivision_Enumeration_Alt_Shape">
  <xs:restriction base="xs:string">  <!-- letters, single spaces or dashes between letters -->
    <xs:pattern value="[nN][zZ]_[rR][eE][gG][iI][oO][nN][sS]:[a-zA-Z]([ \-]?[a-zA-Z])*/[a-zA-Z]([ \-]?[a-zA-Z])*" />
  </xs:restriction>
</xs:simpleType>
<xs:simpleType name="Secondary_Administrative_Subdivision_Enumeration_Alt">
  <xs:restriction base="Secondary_Administrative_Subdivision_Enumeration_Alt_Shape">  <!-- 5-17 and 4-21 characters -->
    <xs:pattern value="[nN][zZ]_[rR][eE][gG][iI][oO][nN][sS]:[^/]{5,17}/[^/]{4,21}" />
  </xs:restriction>
</xs:simpleType>
```

The generator stops if the original pattern isn't found exactly once in each of those eight
files, or is found anywhere else, so a new release can't slip past it. Equivalence was checked
exhaustively on 2026-11-01: both patterns tell characters apart only as letters, a space or dash,
`/` and anything else, and the `/` splits the value into region and district, so comparing every
region of letters and spaces up to 19 characters and every district up to 23 (past both bounds),
plus a dash, a digit, a second slash and the prefix's case, covers it: 17,825,799 values, no
difference. With the change, libxml2 2.9.13 compiles all 32 schemas, and the official ADX test
file validates against both 3.1.8 schemas.
