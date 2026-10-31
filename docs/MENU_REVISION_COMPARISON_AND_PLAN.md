# Menu Revision: Current State, Proposal Comparison, and Plan

## Purpose

This document compares the current ADIF Lint menu and workspace with the recommendations in `ADIF_Lint_Menu_Refactoring_Proposal.md`, then records a revision plan that preserves the product decisions made during implementation.

The proposal is a UX and functional specification, not a verified inventory of implemented features. Its suggestions are treated as recommendations until confirmed against the source and the Nextpad++ plugin API.

## Current state

The menu is assembled in `src/plugin/ADIFLint.mm`. The multi-frame logging workspace is implemented in `src/plugin/Workspace.mm`.

The current menu has these groups and entry points:

- **Logging & Operating:** Map & Explorer, Start Logging, Start Activation, and Logging Layout Options.
- **Validate & Edit:** Check Log, Next Problem, Previous Problem, Fix Field Lengths, Bulk Edit, and Shift QSO Times.
- **Organize & Manage Logs:** Sort & Organize, Remove Duplicates, Compare and Merge Logs, Import, Export, and a nested Reformat Log submenu.
- **Explore & Analyze:** Log Table, Log Summary, Worked Before, and Activation Tracker.
- **QSL & Integrations:** QSL Sync, Enrich Log, and Monitor External Applications.
- **Preferences & Display:** Settings and the Record Panel, automatic checking, offline, and appearance toggles.
- **Help:** About ADIF Lint.

The logging workspace combines frames for QSO entry, the log table, activations and spots, a contact map, QSO details, and the interactive map. Start Logging restores the logging arrangement. Start Activation opens the workspace before presenting activation setup. The contact map can use a known country location when the contact has no grid square.

## Comparison with the proposal

| Area | Proposal recommendation | Current state | Revision direction |
|---|---|---|---|
| Logging and operating | Separate New QSO, Spots & Hunting, Start Activation, and Logging Layout commands | The menu offers Map & Explorer, Start Logging, Start Activation, and Logging Layout Options. QSO entry and spots are available within the multi-frame workspace. | Keep the newer workspace-based entry points. Describe Start Activation as opening the workspace before setup. Do not restore standalone New QSO or Spots commands without a new product decision. |
| Map | Place Map & Contact Explorer under Explore & Analyze | Map & Explorer is in the top Logging & Operating group. | Keep Map & Explorer at the top, following the user’s later direction. This supersedes the proposal’s placement. |
| Validation and editing | Split Validate & Edit into Validate & Repair and Edit & Transform | Validation, repair, bulk edit, and time shift currently share Validate & Edit. | Split the group. Move bulk editing, time shifting, and reformatting to Edit & Transform. |
| Log management | Group sorting, duplicate removal, merge, import, and export | These commands are already together under Organize & Manage Logs; Reformat Log is nested there too. | Keep the group and move Reformat Log to Edit & Transform. Consider standardizing “Compare and Merge Logs” to “Compare & Merge Logs.” |
| Analysis | Keep Log Table, Summary, Worked Before, Map, and Activation Tracker together | Explore & Analyze contains Log Table, Summary, Worked Before, and Activation Tracker. Map & Explorer is top-level. | Preserve the group; keep Map & Explorer top-level as requested. |
| Integrations | Group QSL and external data integrations | QSL & Integrations already groups QSL Sync, Enrich Log, and Monitor External Applications. | Keep the group. Clarify online or offline availability inside the relevant workflows where applicable. |
| Preferences and help | Use Preferences & Appearance and Help & About | Current labels are Preferences & Display and Help. | Consider renaming the headings to make their scope clearer. |

## Product decisions to preserve

- **Map & Explorer** remains a top-level command in Logging & Operating.
- **Start Logging** restores the logging workspace arrangement.
- **Start Activation** opens the workspace first, then activation setup.
- The workspace includes QSO entry, logs, activations and spots, the contact map, and QSO information/details.
- The static contact map uses a known country location when no grid square is available.
- “Logging Layout Options” refers to arranging workspace frames. It is distinct from the Map & Explorer menu command.

## Recommended menu revision

Keep the current top-level operating commands and group labels, with these changes:

1. Rename **Validate & Edit** to **Validate & Repair**.
2. Add **Edit & Transform** for Bulk Edit, Shift QSO Times, and Reformat Log.
3. Move Reformat Log out of Organize & Manage Logs.
4. Keep Organize & Manage Logs focused on sorting, duplicate handling, comparing/merging, importing, and exporting logs.
5. Consider renaming **Preferences & Display** to **Preferences & Appearance** and **Help** to **Help & About**.
6. Keep **Map & Explorer**, **Start Logging**, **Start Activation**, and **Logging Layout Options** in Logging & Operating.

This preserves the current command organization where it already matches the proposal while making validation, modification, and document formatting easier to distinguish.

## Interaction improvements to evaluate

The proposal suggests several behavior improvements. Existing behavior should be verified before treating these as gaps:

- Contextually enable document-dependent commands when the host supports reliable menu updates.
- Ensure menu checkmarks stay synchronized when settings change outside the menu.
- Keep validation finding navigation consistent with the current findings.
- Show the selected Reformat Log mode with a checkmark if the application can track it reliably.
- Provide previews and appropriate confirmation for destructive operations.
- Ensure Offline Mode suppresses network requests while leaving local validation, organization, lookup, and map workflows available where possible.

The Check Log workflow already presents findings and supports navigation. Several settings are already represented by checkable menu items. Confirm the precise behavior and host API constraints during implementation rather than assuming the proposal describes missing functionality.

## Future features (not part of this menu revision)

The proposal lists the following as future opportunities. Do not add menu entries until the corresponding features exist:

- Log Health Report
- Consolidated Award Progress
- DX Opportunity Finder
- Propagation Explorer
- Operating Sessions
- Contest Analysis
- Data Source Status
- Backup & Recovery

Some related capabilities may already exist in narrower forms. Any future menu item should represent a working user-facing workflow, not a placeholder for a roadmap idea.

## Implementation plan

### Phase 1: Align terminology and grouping

- Split Validate & Edit into Validate & Repair and Edit & Transform.
- Move Bulk Edit, Shift QSO Times, and Reformat Log into Edit & Transform.
- Keep organize, duplicate, merge, import, and export commands grouped.
- Preserve current command callbacks and IDs where possible.
- Keep Map & Explorer at the top and retain Start Logging and Start Activation behavior.

### Phase 2: Review menu state and workflows

- Verify checkmark synchronization for persistent settings.
- Review document-dependent command enablement against the host API.
- Verify validation navigation and Reformat Log state indication.
- Review previews, confirmation, and recovery behavior for changes to log data.
- Confirm Offline Mode behavior across local and network-dependent workflows.

### Phase 3: Keep documentation in sync

- Update the menu assembly and localized menu labels.
- Update the README and user guide to reflect the final menu labels and grouping.
- Update this plan with decisions or deferred items after implementation.
- Verify the menu structure and workspace behavior in the host application.

## Naming note

The proposal uses **Logging Layout** as a menu command. The current product uses **Start Logging** to restore that workspace and **Logging Layout Options** to arrange its frames. Keep these names unless the workspace itself is deliberately renamed; do not conflate workspace layout controls with the Map & Explorer launcher.

## Status (2026-10-30)

**Phase 1 is done.**

- **Validate & Repair** (flat, as before): Check Log, Next Problem, Previous Problem, Fix Field Lengths.
- **Edit & Transform** (a submenu, like the groups after it): Bulk Edit, Shift QSO Times, then the Reformat Log submenu.
- **Organize & Manage Logs** keeps sorting, duplicates, compare and merge, import and export.
- **Preferences & Appearance** and **Help & About** replace Preferences & Display and Help.
- Section identifiers are unchanged apart from the new `org.nextpad.adiflint.section.edit`; command IDs and callbacks are unchanged.
- The five translations have the new headings; the README, user guide and CHANGELOG list the new groups.
- Menu names change U+00A0 to a plain space, as AppKit does in a menu title. Before, the French Reformat names (`Reformater : …`) were not found in the menu and the sections were not built at all in French.

**Deferred:** "Compare and Merge Logs" keeps its name. It is a command name, also the window's title and the Import entry for WSJT-X logs, and shortcuts are assigned to commands, so renaming it is a separate decision.

**Phase 2, so far:** the four checkable items (Record Panel, Check ADI Files While Typing, Offline Mode, Night Mode) follow their settings when changed in Settings or elsewhere. Still to review: greying out commands that need a document (host API), Reformat Log's mode tick, previews for changes to log data, and Offline Mode across network workflows.

### Second pass: entry points by intent (2026-10-30)

The proposal's Logging & Operating entry points are back, with each way of operating one command away:

- **Logging & Operating:** Start Logging, Start Activation…, **Start Contest…** (new: the logging layout, then the Contest window, as Start Activation does for activations), **New QSO…** (back on the menu), Logging Layout Options.
- **Map & Spots** (new section): Map & Explorer…, **Live Map…** (new: the Map in its Live workflow, or DX Chase or POTA when it is in one), **Spots & Hunting…** (back on the menu).
- Map & Explorer stays at the top level, as decided earlier, rather than in Explore & Analyze as the proposal has it. Explore & Analyze keeps Log Table, Log Summary, Worked Before and Activation Tracker.
- Monitor External Applications stays in QSL & Integrations, as the proposal has it: it logs other programs' QSOs.
- The new commands come after the others in the host's command table, so existing commands keep their places and their shortcuts.
