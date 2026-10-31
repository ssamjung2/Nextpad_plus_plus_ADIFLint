# ADIF Lint Menu Refactoring Proposal

**Document type:** Functional and UX specification\
**Status:** Proposed architecture\
**Scope:** Existing ADIF Lint menu, command responsibilities,
interaction behavior, and future extensibility

------------------------------------------------------------------------

## 1. Executive summary

ADIF Lint has grown beyond a conventional ADIF validator. It combines
ADIF editing and data-quality tools with logging workflows,
contact-history analysis, geographic visualization, portable operating
support, and integrations with external applications and services.

The menu should reflect those responsibilities without exposing every
individual capability at the top level. Its purpose is to act as a
concise command launcher and navigation index---not to become the
primary interface for every feature.

The recommended design has eight functional sections:

1.  Logging & Operating
2.  Validate & Repair
3.  Edit & Transform
4.  Organize & Manage Logs
5.  Explore & Analyze
6.  QSL & Integrations
7.  Preferences & Appearance
8.  Help & About

The design preserves existing functionality, improves terminology and
discoverability, and establishes a structure that can accommodate future
features.

### Core design principles

1.  Organize commands around operator workflows rather than
    implementation modules.
2.  Separate logging, validation, editing, analysis, and external
    integrations.
3.  Keep frequently used commands accessible without excessive submenu
    navigation.
4.  Distinguish document operations from station and operating
    activities.
5.  Make persistent settings and transient actions visually and
    functionally distinct.
6.  Keep the menu extensible as ADIF Lint develops additional
    amateur-radio capabilities.
7.  Respect the capabilities and limitations of the Nextpad++ plugin
    interface and native macOS menu conventions.

------------------------------------------------------------------------

## 2. Proposed menu architecture

The following is the recommended target hierarchy. Indented entries
represent commands within a section; `>` indicates a submenu.

``` text
ADIF Lint
│
├── Logging & Operating
│   ├── New QSO…
│   ├── Spots & Hunting…
│   ├── Start Activation…
│   ├── Logging Layout
│   └── Layout Options >
│
├── Validate & Repair
│   ├── Check Log…
│   ├── Next Problem
│   ├── Previous Problem
│   └── Fix Field Lengths
│
├── Edit & Transform
│   ├── Bulk Edit…
│   ├── Shift QSO Times…
│   └── Reformat Log >
│       ├── One Record per Line
│       └── One Field per Line
│
├── Organize & Manage Logs
│   ├── Sort & Organize…
│   ├── Remove Duplicates…
│   ├── Compare & Merge Logs…
│   ├── Import…
│   └── Export…
│
├── Explore & Analyze
│   ├── Log Table…
│   ├── Log Summary…
│   ├── Worked Before…
│   ├── Map & Contact Explorer…
│   └── Activation Tracker…
│
├── QSL & Integrations
│   ├── QSL Sync…
│   ├── Enrich Log…
│   └── Monitor External Applications…
│
├── Preferences & Appearance
│   ├── Settings…
│   ├── Record Panel [toggle]
│   ├── Check ADI Files While Typing [toggle]
│   ├── Offline Mode [toggle]
│   └── Night Mode [toggle]
│
└── Help & About
    └── About ADIF Lint…
```

### Structural changes from the current menu

-   Split the former **Validate & Edit** section into **Validate &
    Repair** and **Edit & Transform**.
-   Move **Reformat Log** into **Edit & Transform**, because it changes
    document representation rather than the underlying QSO information.
-   Retain **Organize & Manage Logs** for sorting, duplicate removal,
    merging, importing, and exporting.
-   Retain **Explore & Analyze** for contact inspection, statistics,
    history lookup, mapping, and activation progress.
-   Keep **QSL & Integrations** separate from local log operations.
-   Rename **Preferences & Display** to **Preferences & Appearance**.
-   Rename **Help** to **Help & About**, while retaining the existing
    About command.

The proposed hierarchy is a logical specification, not a requirement to
implement every heading as a literal submenu. Native macOS menus are
strongest when they remain concise and predictable. Use section headings
and separators where that is more usable than additional nesting.

------------------------------------------------------------------------

## 3. Detailed menu item specifications

Each command should have a documented purpose, scope, interaction type,
and expected behavior. The descriptions below specify intended
functionality; they do not assert that every proposed capability is
already implemented.

## 3.1 Logging & Operating

This section covers activities most directly associated with making
contacts and operating an amateur radio station.

  -----------------------------------------------------------------------
  Menu item                           Functionality and purpose
  ----------------------------------- -----------------------------------
  **New QSO...**                      Create a new contact record.
                                      Capture callsign, date/time, band,
                                      frequency, mode, signal reports,
                                      operator information, and
                                      applicable ADIF fields. Support the
                                      logging workflow and validation of
                                      newly entered information.

  **Spots & Hunting...**              Find and monitor amateur-radio
                                      activity. Search live spots, filter
                                      by band, mode, callsign, DXCC, and
                                      operating program. Support POTA,
                                      WWFF, and other spot sources. Help
                                      identify stations to contact and
                                      check whether they have already
                                      been worked.

  **Start Activation...**             Initiate a portable operating
                                      session or activation. Select an
                                      applicable program and reference,
                                      such as POTA, WWFF, or SOTA.
                                      Provide an activation-oriented
                                      workflow for tracking QSOs,
                                      operating progress, and session
                                      results.

  **Logging Layout**                  Select or activate a predefined
                                      logging interface arrangement.
                                      Provide convenient access to
                                      different layouts depending on
                                      screen size, operating preferences,
                                      or workflow.

  **Layout Options \>**               Configure the selected logging
                                      layout. Manage visible fields,
                                      field ordering, panel arrangement,
                                      display options, and other
                                      supported layout-specific
                                      preferences.
  -----------------------------------------------------------------------

### Design considerations

**Spots & Hunting** and **Start Activation** should remain separate
because they represent different operating objectives:

-   Hunting: finding and contacting other stations.
-   Activating: operating from a qualifying location and generating
    contacts.

This distinction leaves room for future DX hunting, contest hunting,
satellite activity, and other portable operating programs.

**Logging Layout** and **Layout Options** should also remain distinct if
they have different responsibilities: the first selects a layout; the
second configures it.

## 3.2 Validate & Repair

This section is responsible for the integrity and correctness of ADIF
data.

  -----------------------------------------------------------------------
  Menu item                           Functionality and purpose
  ----------------------------------- -----------------------------------
  **Check Log...**                    Validate the current ADIF document
                                      against supported ADIF
                                      specifications and configured
                                      validation rules. Identify
                                      malformed records, invalid values,
                                      missing required fields, incorrect
                                      field lengths, and other
                                      data-quality problems. Present
                                      findings with severity and
                                      record/field context.

  **Next Problem**                    Navigate to the next identified
                                      validation issue. Move the editor
                                      or associated record interface to
                                      the affected location.

  **Previous Problem**                Navigate backward through
                                      identified validation issues.
                                      Return to the previously identified
                                      problem.

  **Fix Field Lengths**               Correct ADIF field-length
                                      declarations when they do not match
                                      their associated values. Preserve
                                      field content and record integrity
                                      wherever possible.
  -----------------------------------------------------------------------

### Recommended validation behavior

Distinguish among:

-   **Errors:** invalid or structurally incorrect ADIF.
-   **Warnings:** questionable, incomplete, or potentially problematic
    information.
-   **Informational findings:** observations that may be useful but do
    not necessarily indicate a problem.

Recommended improvements:

-   Display a total finding count.
-   Provide severity filtering.
-   Highlight the affected record and field.
-   Preserve navigation between findings.
-   Revalidate after corrections.
-   Avoid silently changing QSO values during repairs.

`Next Problem` and `Previous Problem` should be enabled only when
findings are available to navigate, if Nextpad++ supports contextual
menu enablement.

## 3.3 Edit & Transform

This section provides intentional modification of existing ADIF records
and document formatting.

  -----------------------------------------------------------------------
  Menu item                           Functionality and purpose
  ----------------------------------- -----------------------------------
  **Bulk Edit...**                    Modify selected fields across
                                      multiple QSO records. Support
                                      common operations such as setting
                                      values, replacing values, clearing
                                      fields, and applying changes to
                                      records matching specified
                                      criteria.

  **Shift QSO Times...**              Adjust QSO date/time values by a
                                      specified offset. Useful for
                                      correcting logging clock errors,
                                      timezone discrepancies, or
                                      incorrectly recorded operating
                                      sessions. Preserve date transitions
                                      and chronological consistency.

  **Reformat Log \>**                 Change the textual representation
                                      of ADIF records without
                                      intentionally changing their
                                      underlying QSO information.
  -----------------------------------------------------------------------

### Reformat Log submenu

  -----------------------------------------------------------------------
  Submenu item                        Functionality
  ----------------------------------- -----------------------------------
  **One Record per Line**             Place each complete ADIF record on
                                      its own line. Useful for compact
                                      logs, easier scanning, and certain
                                      editing workflows.

  **One Field per Line**              Place each ADIF field on its own
                                      line, making individual fields
                                      easier to inspect and edit.
  -----------------------------------------------------------------------

If these are mutually exclusive formatting options, use checkmarks to
identify the currently selected format, provided the plugin can reliably
track it.

### Potential Bulk Edit operations

Depending on current implementation and supported ADIF fields, useful
operations could include:

-   Callsign normalization.
-   Band and mode corrections.
-   Operator and station information.
-   MY_DXCC and DXCC field management.
-   Contest and award information.
-   POTA, WWFF, and SOTA reference corrections.
-   Date/time normalization.

These are examples of useful operations, not assumptions that all are
currently implemented.

## 3.4 Organize & Manage Logs

This section deals with the structure, organization, and lifecycle of
ADIF log files.

  -----------------------------------------------------------------------
  Menu item                           Functionality and purpose
  ----------------------------------- -----------------------------------
  **Sort & Organize...**              Sort records by date/time,
                                      callsign, band, mode, DXCC, or
                                      other supported fields. Provide
                                      options for chronological
                                      organization, field-based sorting,
                                      and record ordering.

  **Remove Duplicates...**            Identify and remove duplicate QSO
                                      records. Allow the user to review
                                      matching records, select retention
                                      rules, and confirm removal.

  **Compare & Merge Logs...**         Compare two or more ADIF logs,
                                      identify unique and overlapping
                                      records, and combine them into a
                                      consolidated log. Provide conflict
                                      handling and duplicate-resolution
                                      options.

  **Import...**                       Bring external ADIF records into
                                      the current logging environment.
                                      Support appropriate source
                                      selection, validation, duplicate
                                      detection, and import review.

  **Export...**                       Export the current log or a
                                      filtered subset of records to an
                                      ADIF file. Support appropriate
                                      export options, field selection,
                                      and output validation.
  -----------------------------------------------------------------------

### Important distinctions

These operations are related but should not be collapsed into one
generic command:

-   **Sort & Organize:** changes the order or arrangement of existing
    records.
-   **Remove Duplicates:** removes redundant records.
-   **Compare & Merge:** reconciles information across multiple log
    sources.

Destructive operations should provide a preview and confirmation, and
preserve an opportunity to recover from accidental changes.

## 3.5 Explore & Analyze

This section is central to ADIF Lint's identity as more than a
traditional ADIF editor. It provides tools for understanding a station's
operating history, identifying opportunities, and visualizing contacts.

  -----------------------------------------------------------------------
  Menu item                           Functionality and purpose
  ----------------------------------- -----------------------------------
  **Log Table...**                    Display QSO records in a
                                      structured, interactive table.
                                      Support browsing, filtering,
                                      sorting, searching, and inspecting
                                      individual contacts. Provide an
                                      accessible view of the underlying
                                      log.

  **Log Summary...**                  Generate statistical summaries of
                                      the current log. Include QSO
                                      totals, band and mode
                                      distributions, date ranges, DXCC
                                      counts, callsign statistics, and
                                      other available contact statistics.

  **Worked Before...**                Determine whether a callsign, DXCC
                                      entity, grid square, state, park,
                                      or other supported reference has
                                      previously been worked. Provide
                                      historical contact information,
                                      including date, band, and mode.

  **Map & Contact Explorer...**       Display logged contacts
                                      geographically. Explore contact
                                      distribution, Maidenhead grid
                                      squares, DXCC entities, parks, and
                                      other geographic information.
                                      Provide interactive filtering and
                                      map layers for day/night, greyline,
                                      live spots, and optional
                                      propagation data.

  **Activation Tracker...**           Track progress toward portable
                                      operating awards and activation
                                      goals, including POTA, WWFF, and
                                      SOTA. Display qualifying contacts,
                                      activation progress, worked
                                      references, and relevant award
                                      statistics.
  -----------------------------------------------------------------------

### Map & Contact Explorer

The map should be treated as a flagship ADIF Lint feature. Its
responsibilities can be grouped into four areas.

**Contact visualization**

-   Logged QSO locations.
-   Maidenhead grid squares.
-   DXCC entities.
-   State, province, and regional views.
-   Contact paths and geographic distribution.

**Operating activity**

-   Live DX spots.
-   POTA and WWFF activity.
-   Hunting and activation context.
-   Historical contact exploration.

**Propagation and environment**

-   Day/night terminator.
-   Greyline.
-   MUF(3000).
-   foF2.
-   Other optional propagation overlays.

**Filtering and analysis**

-   Date/time.
-   Band.
-   Mode.
-   Callsign.
-   DXCC.
-   Award/program references.

The map should own these visualization controls instead of exposing
every individual layer as a top-level menu command. The menu opens the
map; the map manages its own visualization experience.

### Worked Before versus Activation Tracker

Keep these functions distinct:

-   **Worked Before** is a general contact-history lookup.
-   **Activation Tracker** is a goal-oriented progress and
    award-tracking interface.

For example, an operator might use Worked Before to determine whether a
particular DX station has been worked on 20 meters, whereas the
Activation Tracker might show whether a POTA activation has reached its
qualifying contact threshold.

## 3.6 QSL & Integrations

This section covers interactions with external services, other
applications, and supplementary information sources.

  -----------------------------------------------------------------------
  Menu item                           Functionality and purpose
  ----------------------------------- -----------------------------------
  **QSL Sync...**                     Synchronize QSO confirmation
                                      information with supported QSL
                                      services. Handle uploads,
                                      confirmation downloads, matching
                                      existing contacts, and updating
                                      confirmation fields such as
                                      LOTW_QSL_RCVD and QSL_RCVD where
                                      applicable.

  **Enrich Log...**                   Supplement existing QSO records
                                      with information from supported
                                      external data sources. Provide
                                      missing or additional contact,
                                      callsign, geographic, award, or
                                      other reference information where
                                      supported. Allow users to review
                                      changes before applying them.

  **Monitor External                  Connect to and monitor supported
  Applications...**                   logging and digital-mode
                                      applications, including WSJT-X and
                                      N1MM. Receive or inspect externally
                                      generated QSO information, monitor
                                      activity, and support the
                                      appropriate integration workflow.
  -----------------------------------------------------------------------

### QSL Sync versus Enrich Log

These should not be treated as interchangeable synchronization features:

-   **QSL Sync** deals with confirmation status and QSL-related
    information.
-   **Enrich Log** deals with adding or improving descriptive
    information associated with existing records.

Make clear which external data sources are active, which require network
access, and which are unavailable in Offline Mode.

## 3.7 Preferences & Appearance

This section controls the persistent behavior and presentation of ADIF
Lint.

  -----------------------------------------------------------------------
  Menu item                           Functionality and purpose
  ----------------------------------- -----------------------------------
  **Settings...**                     Open the central configuration
                                      interface. Manage validation rules,
                                      data sources, network behavior, map
                                      defaults, logging preferences,
                                      integration settings, and other
                                      persistent configuration.

  **Record Panel**                    Show or hide the QSO record panel
                                      within the logging interface. A
                                      checkmark indicates that the panel
                                      is visible.

  **Check ADI Files While Typing**    Enable or disable automatic
                                      validation or checking of `.adi`
                                      files while the user edits them. A
                                      checkmark indicates that automatic
                                      checking is enabled.

  **Offline Mode**                    Restrict operations requiring
                                      external network connectivity.
                                      Disable or suppress
                                      network-dependent requests while
                                      preserving local functionality.

  **Night Mode**                      Toggle the dark visual appearance
                                      of ADIF Lint interfaces, where
                                      supported.
  -----------------------------------------------------------------------

### Suggested Settings categories

  -----------------------------------------------------------------------
  Settings category                   Contents
  ----------------------------------- -----------------------------------
  General                             Startup behavior, default document
                                      behavior, general preferences.

  Validation                          ADIF version, validation rules,
                                      error/warning behavior, automatic
                                      checking.

  Logging                             Default logging fields, record
                                      behavior, logging preferences.

  Layout & Display                    Themes, layout defaults, visible
                                      panels, table appearance.

  Map & Propagation                   Default map layers, contact
                                      display, greyline, day/night, MUF,
                                      foF2.

  Data Sources                        External data providers, refresh
                                      intervals, API configuration.

  Integrations                        WSJT-X, N1MM, other supported
                                      loggers, external application
                                      connections.

  QSL Services                        LoTW, eQSL, QRZ or other supported
                                      confirmation services.

  Network & Privacy                   Offline behavior, network access,
                                      caching, data-sharing preferences.

  Advanced                            Diagnostics, logging,
                                      troubleshooting, specialized
                                      configuration.
  -----------------------------------------------------------------------

These are proposed settings categories. They should only be exposed when
the corresponding configuration capabilities exist.

Consider renaming **Night Mode** to **Dark Appearance** if it controls
the visual theme rather than a time-dependent operating condition.

Consider moving **Record Panel** into a View or Display submenu if the
number of display toggles grows. For now, its top-level visibility is
reasonable.

## 3.8 Help & About

  -----------------------------------------------------------------------
  Menu item                           Functionality and purpose
  ----------------------------------- -----------------------------------
  **About ADIF Lint...**              Display the plugin name, version,
                                      author, GPLv3 licensing
                                      information, project links,
                                      supported ADIF version information,
                                      and available acknowledgments.

  -----------------------------------------------------------------------

A dedicated Help submenu could be considered if documentation and
support features expand. Potential additions include:

-   User Guide.
-   ADIF Specification Reference.
-   Supported Data Sources.
-   Troubleshooting.
-   Report a Bug.
-   Check for Updates.

These are future possibilities, not requirements for the current menu.

------------------------------------------------------------------------

## 4. Functional classification of every command

Classifying commands by operation type helps with implementation
decisions, enablement rules, keyboard shortcuts, and testing.

  -----------------------------------------------------------------------
  Menu item               Operation type          Primary scope
  ----------------------- ----------------------- -----------------------
  New QSO                 Create                  New record

  Spots & Hunting         Discover / Monitor      External activity

  Start Activation        Start / Track           Operating session

  Logging Layout          Select                  UI layout

  Layout Options          Configure               UI layout

  Check Log               Validate                Current document

  Next Problem            Navigate                Validation results

  Previous Problem        Navigate                Validation results

  Fix Field Lengths       Repair                  Current document

  Bulk Edit               Modify                  Selected records

  Shift QSO Times         Modify                  Selected or applicable
                                                  records

  Reformat Log            Transform               Current document

  Sort & Organize         Organize                Current document

  Remove Duplicates       Remove                  Current document

  Compare & Merge Logs    Reconcile               Multiple documents

  Import                  Transfer in             External data

  Export                  Transfer out            Current log

  Log Table               Inspect                 QSO records

  Log Summary             Analyze                 QSO dataset

  Worked Before           Lookup                  Contact history

  Map & Contact Explorer  Visualize               Geographic/contact data

  Activation Tracker      Track progress          Award/program data

  QSL Sync                Synchronize             QSL services

  Enrich Log              Enrich                  QSO records

  Monitor External        Monitor / Integrate     External applications
  Applications                                    

  Settings                Configure               Plugin-wide

  Record Panel            Toggle                  UI visibility

  Check ADI Files While   Toggle                  Validation behavior
  Typing                                          

  Offline Mode            Toggle                  Network behavior

  Night Mode              Toggle                  Appearance

  About ADIF Lint         Inform                  Plugin information
  -----------------------------------------------------------------------

This classification exposes an important distinction: some menu items
operate on the active document, others operate on the plugin's entire
environment, and still others depend on external services. Those scopes
should be reflected in both implementation and user experience.

------------------------------------------------------------------------

## 5. Menu item behavior and interaction conventions

Establish consistent interaction rules throughout the menu.

  -----------------------------------------------------------------------
  Menu presentation       Meaning                 Examples
  ----------------------- ----------------------- -----------------------
  `Command…`              Opens a dialog, window, Check Log..., Bulk
                          or multi-step workflow  Edit...

  `Command >`             Opens a submenu         Reformat Log, Layout
                                                  Options

  `Command`               Performs an immediate   Next Problem, Previous
                          action                  Problem

  `Command ✓`             Persistent enabled      Record Panel, Offline
                          state                   Mode

  Gray section heading    Noninteractive category Validate & Repair
                          label                   
  -----------------------------------------------------------------------

### Document-dependent commands

Commands such as Check Log, Fix Field Lengths, Sort & Organize, and
Export should reflect whether a suitable document or dataset is
available.

### External-service-dependent commands

Spots, QSL Sync, Enrich Log, and Monitor External Applications should
communicate their connection or availability state inside their
respective interfaces.

### Destructive operations

Remove Duplicates, Bulk Edit, and Compare & Merge should provide
suitable previews and confirmation steps when changes are significant.

### Offline behavior

Offline Mode should not disable local operations such as validation, log
organization, contact lookup against local records, or local map
visualization. It should affect external data requests rather than
unnecessarily restricting the entire plugin.

### Persistent settings

Checkmarks should accurately reflect the underlying application state.
They should not merely reflect the last menu selection.

------------------------------------------------------------------------

## 6. Nextpad++ and native macOS implementation considerations

The proposed architecture must be implemented within the capabilities of
the host plugin API. Before introducing more complex menu structures,
verify the actual support available for:

-   Native nested submenus and menu depth.
-   Separators and noninteractive section headings.
-   Checkable menu items and state synchronization.
-   Dynamic command enablement.
-   Keyboard shortcuts and key-equivalent conflicts.
-   Active-document detection and document lifecycle.
-   Window creation, focus, reopening, and state restoration.
-   Menu updates when preferences change elsewhere in the UI.

### Recommended implementation order

1.  **Labels and ordering:** Shorten verbose labels, correct ambiguous
    wording, group related commands with separators, and keep existing
    command identifiers and callbacks unchanged.
2.  **Checkable settings:** Ensure menu checkmarks accurately reflect
    real application state, including changes made elsewhere in the UI.
3.  **Menu nesting:** Consolidate the two reformat commands or group
    related commands only if Nextpad++ supports native submenus cleanly.
4.  **Contextual enablement and shortcuts:** Disable irrelevant commands
    when appropriate and add shortcuts only where host handling permits
    reliable behavior without conflicts.

### macOS menu conventions

-   An ellipsis generally indicates that an action will request
    additional information or open a further interface.
-   Retain ellipses for dialogs and multi-step workflows.
-   Remove ellipses from immediate commands such as Next Problem and
    Previous Problem.
-   Keep naming and punctuation consistent.
-   Avoid adding decorative icons to every menu item. Native menus are
    text-oriented; concise labels, grouping, and state indicators
    provide more value.

Do not assume a capability exists merely because it is desirable. Verify
the host API and existing plugin implementation before making changes
that require new host functionality.

------------------------------------------------------------------------

## 7. Future feature opportunities

The following capabilities could eventually fit naturally into the
proposed architecture. They should not be added to the menu until they
are implemented.

  -----------------------------------------------------------------------
  Potential feature       Proposed location       Purpose
  ----------------------- ----------------------- -----------------------
  Award Progress          Explore & Analyze       Consolidated DXCC, WAS,
                                                  WPX, and other award
                                                  progress.

  Band & Mode Statistics  Explore & Analyze       Analyze contacts by
                                                  band, mode, and date.

  Propagation Explorer    Map & Contact Explorer  Analyze contact paths
                                                  against propagation
                                                  conditions.

  DX Opportunity Finder   Logging & Operating     Identify stations or
                                                  entities worth
                                                  pursuing.

  Contest Analysis        Explore & Analyze       Analyze contest
                                                  participation and QSO
                                                  statistics.

  Activity Sessions       Logging & Operating     Organize contacts into
                                                  individual operating
                                                  sessions.

  Log Health Report       Validate & Repair       Summarize document
                                                  quality and outstanding
                                                  issues.

  Station Profile         Settings                Configure callsign,
                                                  station location,
                                                  grids, and operating
                                                  identity.

  Data Source Status      QSL & Integrations      Display the
                                                  availability and health
                                                  of connected services.

  Backup & Recovery       Organize & Manage Logs  Preserve and recover
                                                  log data.
  -----------------------------------------------------------------------

### Log Health Report

A particularly useful addition would be a Log Health Report. It could
summarize:

-   Structural validity.
-   Missing information.
-   Duplicate contacts.
-   Suspicious timestamps.
-   Other data-quality indicators.

This would provide a high-level overview without requiring users to
navigate individual validation findings.

------------------------------------------------------------------------

## 8. Implementation roadmap

### Phase 1 --- Menu refinement

**Priority: Highest**

Mostly organizational changes with minimal risk to existing
functionality.

-   [ ] Split Validate & Edit into Validate & Repair and Edit &
    Transform.
-   [ ] Move Reformat Log into Edit & Transform.
-   [ ] Keep Organize & Manage Logs focused on file organization and
    transfer.
-   [ ] Standardize command names and ellipses.
-   [ ] Document every command's purpose and behavior.
-   [ ] Preserve existing menu command identifiers where possible.

### Phase 2 --- Interaction improvements

**Priority: Medium**

Improvements to the menu's responsiveness and usability.

-   [ ] Contextual command enablement.
-   [ ] Accurate checkmark synchronization.
-   [ ] Better validation navigation.
-   [ ] Reformat submenu state indication.
-   [ ] Consistent offline-mode behavior.
-   [ ] Appropriate confirmation and preview workflows.

### Phase 3 --- Functional expansion

**Priority: Longer term**

New capabilities that build on the revised architecture.

-   [ ] Log Health Report.
-   [ ] Consolidated Award Progress.
-   [ ] DX Opportunity Finder.
-   [ ] Propagation Explorer.
-   [ ] Operating Sessions.
-   [ ] Contest Analysis.
-   [ ] Data Source Status.

------------------------------------------------------------------------

## 9. Long-term functional architecture

The menu is the user-facing navigation structure. Beneath it, ADIF Lint
should be organized around a smaller set of stable functional domains.

``` text
ADIF Lint
│
├── Operating
│   ├── Logging
│   ├── Hunting
│   └── Activations
│
├── Data Quality
│   ├── Validation
│   ├── Repair
│   └── Editing
│
├── Log Management
│   ├── Organization
│   ├── Import / Export
│   └── Reconciliation
│
├── Intelligence
│   ├── Analysis
│   ├── Awards
│   ├── Contact History
│   └── Mapping
│
├── Integrations
│   ├── QSL Services
│   ├── Data Sources
│   └── External Applications
│
└── Configuration
    ├── Preferences
    ├── Appearance
    ├── Connectivity
    └── Diagnostics
```

These six functional areas provide a stable architectural foundation
while allowing the menu and individual interfaces to evolve
independently.

------------------------------------------------------------------------

## 10. Final recommendations

Adopt the eight-section menu proposed in this document, while treating
the six functional areas in the long-term architecture as the underlying
software organization.

The most important decisions are:

1.  **Keep the main menu relatively flat.** Use clear section headings
    and separators. Introduce submenus only where several related
    commands genuinely benefit from them.
2.  **Use task-oriented names.** Prefer Validate Log, Shift QSO Times,
    Map & Contact Explorer, and Monitor External Applications over vague
    or implementation-specific labels.
3.  **Keep data operations, analysis, and preferences distinct.** Do not
    mix document formatting with appearance settings or automatic
    validation preferences with commands that navigate findings.
4.  **Make the menu a command launcher.** The map, log table, activation
    tracker, and settings interfaces should own their respective
    workflows.
5.  **Preserve existing functionality and command identifiers wherever
    practical.** A menu refactor should not unnecessarily destabilize
    working plugin features.
6.  **Verify host capabilities before implementing advanced menu
    behavior.** Nextpad++ limitations should determine which
    recommendations can be implemented natively and which require an
    alternative.

The largest usability improvement is likely to come from reorganizing
existing commands, clarifying their purpose, and making their
availability reflect application state---not from adding another layer
of UI.

This structure gives ADIF Lint a stable menu today while allowing it to
grow into additional operating styles, award programs, propagation
analysis, and digital-mode integrations without continually
restructuring its navigation.

------------------------------------------------------------------------

## Appendix A --- Scope and implementation notes

This document is a proposed functional and UX specification based on the
menu structure and feature descriptions discussed during review. It is
not a verified inventory of the plugin source code or Nextpad++ API.

Before implementation:

-   Confirm the current behavior of each command.
-   Identify which capabilities are already implemented, partially
    implemented, or planned.
-   Verify ADIF field names and service-specific behavior against the
    relevant specifications.
-   Confirm which menu capabilities are supported by the installed
    Nextpad++ plugin interface.
-   Separate confirmed requirements from future suggestions.
-   Update this document as implementation decisions are made.

**Project:** ADIF Lint\
**License context:** GPLv3\
**Platform context:** Nextpad++ on macOS
