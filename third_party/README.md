# Third-party files

These files are vendored unchanged and are only `#include`d. Nothing from the host
application is linked into the plugin.

| File | Source | Version | License |
|---|---|---|---|
| `nextpad/NppPluginInterfaceMac.h` | [nextpad-plus-plus-macos](https://github.com/nextpad-plus-plus/nextpad-plus-plus-macos) `src/` | commit `d50c226` (2026-10-06) | GPL-3.0 |
| `scintilla/include/Scintilla.h`, `Sci_Position.h` | the same repository, `scintilla/include/` | Scintilla 5.6.0 | `scintilla/License.txt` |

The plugin was tested against the installed Nextpad++ 1.1.2. If a later Nextpad++
changes the plugin header, copy the new header here and rebuild.
