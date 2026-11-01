# Windowing and UI Architecture

Status: **accepted direction** (2026-10-31), every decision made (see the end).
Nothing here is built yet beyond what "Where we are" describes.

## Purpose

ADIF Lint is growing into a set of purpose-built panels (New QSO, Log Table, Map, Activations &
Spots, Contact Map, QSO Details, and more to come) that people arrange to suit how they operate.
Some content will move between homes: the Map's Settings and Style Options cards, for example,
may become Settings sections or panels of their own. Operating styles and layouts should be
nothing more than **which panels show, where, and how they are set up**.

This document defines one model for that: the kinds of surface, a panel registry, a saved
arrangement, commands whose state every control reads from one place, styles as profiles over
arrangements, and theming that every panel gets from its host. It ends with a phased plan that
keeps the plugin working at each step.

## Principles

Each is drawn from Apple's Human Interface Guidelines (HIG) and AppKit documentation, or from
the multi-panel frameworks that solved the same problem (VS Code, JetBrains IDEs, Qt, Eclipse).
Sources are listed at the end; all were read on 2026-10-31.

1. **Every panel has a stable id.** VS Code views, Qt dock widgets (`objectName`) and JetBrains
   tool windows are all addressed by id; layouts and commands refer to the id, never to a
   window object.
2. **The arrangement is data.** Which panels show, where, at what size, is one serializable,
   versioned value (Qt's `saveState(version)`; JetBrains "Save Current Layout as New"; Eclipse
   perspectives, "the initial set and layout of views"). Presets are stored arrangements.
3. **Showing and hiding are commands.** A command has one implementation; menus, toolbar
   buttons, shortcuts and frame headers all invoke it (VS Code "View: Toggle …"; Qt
   `toggleViewAction()`).
4. **Controls reflect state; they don't hold it.** AppKit validates menu items and toolbar items
   against their target (`validateMenuItem:`, `NSUserInterfaceValidations`, `NSToolbarItem
   validate`); VS Code binds UI to context keys (`view.<id>.visible`). A button never decides
   what is open.
5. **Every toolbar item is also a menu command** (HIG Toolbars), and each show/hide command's
   title "reflects the current state" (HIG Menu bar): **Show Log Table** / **Hide Log Table**.
6. **Hidden panes are easy to bring back.** "Provide multiple ways to reveal hidden panes": a
   toolbar button and a menu command with a shortcut (HIG Split views). Sidebars: "Avoid hiding
   the sidebar by default" (HIG Sidebars).
7. **Use the right kind of surface.** Panels float and carry supplementary controls, and should
   avoid "controls that require typing"; a split-view pane "may be a better choice" for an
   inspector (HIG Panels). Avoid opening new windows as default behaviour (HIG Windows).
8. **Theme once, at the host.** Appearance, Night Mode, contrast and the style colours come from
   shared definitions applied by whatever hosts a panel, not by each panel's own code.

## Where we are (2026-10-31)

Pieces of this model exist, but each grew separately:

| Concern | Today | Problem |
|---|---|---|
| Panel identity | `ADIFDockItem` enum (6 items), openers registered in `ADIFLint.mm`, `kPanels` table in `Map.mm`, item names in `Workspace.mm` | Four lists to keep in step for each new panel |
| Hosting | `ADIF_DOCKABLE_WINDOW` macro: a window answers show/close/visible for its console frame | Works; the host is implicit, and only windows can be hosted |
| Layout | 9 presets as hard-coded split trees with shares; split sizes in `NSSplitView Subview Frames adif.layoutN…`; frames chosen per preset | Presets are code, not data; no user-saved layouts; Map panes saved separately (`mapSidebar`, `mapList`, `mapSelected`) |
| Show/hide | Map pane buttons, the new panel buttons, the console's Frames menu, the frame header's popup, menu commands, Focus Map | Five mechanisms; each control keeps its own state (the stale New QSO button found today) |
| State sync | `ADIFPanelShownNotification`, `ADIFOperatingStyleChangedNotification`, offline and night notifications, window-close observers | Added one at a time |
| Styles | Map settings only (`adif_styles`); Start Logging / Activation / Contest choose a console preset in their own code | A style can't say which panels it wants |
| Theming | Night Mode as a filter each window opts into (`ADIFNightTrack`, 8 windows); `kADIFMargin` (11 uses); small fonts set by hand (~75 places); colours per call site | Easy to miss a window; no shared type ramp or semantic colours |

There are about 30 surfaces: 6 dockable panels; 20 tool windows (Bulk Edit, Sort, Contest,
Monitor, Log Summary, QSL Sync…); the Map; Settings; the Record panel; Enrich; the upload,
import and export windows; popovers and alerts.

## The model

### 1. Kinds of surface

Every surface is one of these kinds, each with its own rules:

| Kind | What it is | Hosts | Examples |
|---|---|---|---|
| **Operating panel** | Something you keep open while operating | A console frame, or its own window | New QSO, Log Table, Map, Activations & Spots, Contact Map, QSO Details, Contest, Activation Tracker, Monitor (future panels go here) |
| **Pane** | A part of one panel that can be hidden | Inside its panel (sidebar, inspector, list) | The Map's sidebar, list, selected panel |
| **Task window** | Does one job, then closes (HIG "auxiliary window … presents a specific task") | Its own window | Bulk Edit, Sort, Remove Duplicates, imports and exports, uploads |
| **Settings** | Preferences that persist across the app | The Settings window, by section | Station, accounts, spot sources, Map data; and (moving) the Map's Settings card |
| **Inspector** | Settings of the thing in view | A pane of its panel, or an operating panel of its own | The Map's Style Options (moving) |
| **Transient** | Quick choices next to a control | Popover or menu | Info, Watch List, Save View |
| **Alert / sheet** | Needs an answer | Modal, attached to its window | About, confirmations |

Rules that follow (HIG):
- Typing-heavy panels (New QSO, Log Table) are operating panels in a frame or a normal window,
  not floating `NSPanel`s that hide when the app is inactive. **New QSO becomes a normal
  window** (decided 2026-10-31).
- Settings that apply app-wide belong in Settings; settings of what is in view belong in an
  inspector; a quick one-off choice belongs in a popover.
- Task windows are never docked and never part of a layout.

### 2. Panel registry

One table describes every operating panel and pane:

```text
PanelSpec
  id            "newqso", "logtable", "map", "spots", "contactmap", "qsodetails", "map.sidebar"…
  kind          operating panel | pane
  title         "New QSO"            (translated; menu titles "Show New QSO" / "Hide New QSO")
  symbol        "square.and.pencil"  (toolbar and menu image)
  hosts         console frame, window; or the panel it belongs to (panes)
  size          least and ideal, for frames and windows
  make          creates its content: an NSViewController, independent of where it is shown
  shortcut      optional
```

The content is a view controller that never knows its host. A **host** puts it in a window, a
console frame or (for panes) a slot of its panel, and applies the theme. Today's
`ADIF_DOCKABLE_WINDOW` becomes the window host and the console frame host; the Map's sidebar,
list and selected panel become panes with the same commands.

Adding a panel is then one registry entry and one view controller. Moving content (the Map's
Style Options into an inspector panel, say) means giving it its own entry and controller; its
callers don't change.

### 3. Arrangement

One versioned value describes what shows where:

```text
Arrangement (version 1)
  console     a split tree: rows and columns with shares; each leaf a stack: one or more panel
              ids shown as tabs, and which is in front
  windows     panels in their own windows, with their frames
  panes       each panel's panes shown or hidden (the Map's sidebar, list, selected panel)
  sizes       divider positions by node
```

- **Stacks (tabs)**: a frame can hold several panels as tabs: the Map with its Map Style
  panel, say, or Settings sections beside a panel. A panel moves between stacks by dragging
  its tab (or its frame header, as today's swap). A stack of one shows no tab bar.
- It lives in the core (`src/core/adif_layout`) as plain data with parse, write, validate and
  migrate, so it is unit-tested without AppKit, like `adif_styles`.
- The plugin restores it itself, from one setting. NSWindowRestoration may not suit a plugin the
  host loads after launch, and frame autosaves write into the host's own defaults (the
  researcher's inference, to test in Nextpad++). Like Qt's `restoreState`, a version it doesn't
  know restores nothing and the defaults show instead.
- **Presets are named arrangements**: the nine console layouts become data. People can **Save
  Layout As…**, update and delete their own, and **Reset** a built-in one (JetBrains Window |
  Layouts; Eclipse's reset perspective). The current one is ticked.
- Migration reads today's settings (`layoutPreset`, the `adif.layout2`/`adif.layout3` split
  sizes, `mapSidebar`/`mapList`/`mapSelected`) into the first arrangement, once.

### 4. Commands and state

A **panel controller** is the one source of truth:

```text
show(id)  hide(id)  toggle(id)  focus(id)
apply(arrangement)  current() → arrangement
saveLayout(name)  layouts()  applyLayout(name)
→ posts one notification, "arrangement changed", with what changed
```

Every control is bound to it, not to the panels:
- **Menu** (Plugins → ADIF Lint): a **Panels** submenu with **Show/Hide <Panel>** for each, and
  a **Layouts** submenu with the presets, a tick on the current one, Save Layout As… and Reset.
  Titles and ticks come from `validateMenuItem:` asking the controller. Nextpad++ owns the
  app's View and Window menus; the plugin's menu is where its commands can live.
- **Map toolbar**: the panel buttons call `toggle(id)` and take their state from the controller
  on its notification, as they do now, without keeping their own.
- **Console**: the Frames menu, the frame header's popup and drag-to-swap all call the
  controller.
- **Shortcuts**: assigned to the commands (Nextpad++'s Shortcut Mapper, as today).

One flow, in one direction: a command changes the controller's state; the controller tells the
hosts and posts its notification; controls redraw from the state. No control reads another
control, so none can go stale.

### 5. Operating styles as profiles

A style is a **profile**: Map settings (today's `adif_styles`), Operating Aids settings, its
colour, and optionally an **arrangement**:

```text
Profile
  map        the owned map* keys (as now)
  aids       level, timing, topics
  accent     its colour
  layout     a named arrangement, or none ("keep my layout")
```

- **Choosing a style arranges the panels by default** (decided 2026-10-31). A setting,
  **Styles arrange the panels**, on at first, turns it off; each style can also keep your
  layout instead of its own.
- Choosing a style applies its profile through the controller, as one change: Info shows it,
  Restore Previous Layout undoes it, Save keeps it (including the arrangement), Reset restores
  it. This is the plan's Stage 6 ("cross-window orchestration"), with the opt-out it requires:
  a setting **Styles arrange the panels** (on or off), and per style "keep my layout".
- **Start Logging**, **Start Activation** and **Start Contest** become a profile plus their own
  set-up (an activation's references; the contest's exchange), not code paths of their own.
- A style never moves focus while you type, never starts a contest or an activation, and never
  changes the log (the plan's existing rules).

### 6. Theming

A small set of **tokens**, defined once (`src/plugin/Theme.{h,mm}`), used by every panel:

| Token group | Examples |
|---|---|
| Spacing | margin, gutter between groups, between rows; the console's frame padding |
| Type | title, heading, body, small, monospaced digits (the clocks, frequencies) |
| Semantic colours | accent (per style), status (fine, note, warning, error), suggestion, link, faint |
| Surfaces | panel, card, frame header; separators |

- The **appearance** (system light or dark, Increase Contrast, Night Mode's red) is applied by
  the host to every window, frame, popover and sheet it hosts. No panel opts in on its own.
- The Map's palettes stay in the core (`adif_palette`) and draw from the same semantic colours.
- A token change is one edit; a new panel is themed by being hosted.

### 7. Toolbars and menus (HIG)

- The Map's toolbar keeps to **three groups** (HIG: "a maximum of three"): styles, workflows,
  and the panel buttons. HIG puts the **sidebar** toggle at the leading edge and **inspector**
  buttons at the trailing edge. So the plan moves the Map's sidebar button to the far left and
  keeps the selected-panel (inspector) button at the far right, with the panel buttons between.
- Every toolbar button has its menu command (Panels submenu); every show/hide title says what
  it will do.
- On macOS 11–13 there's no `toggleInspector:` (macOS 14), so the plugin's own commands toggle
  panes. `NSToolbarItemGroup` with `selectAny` (10.15) fits a set of independent toggles if the
  Map later moves to an `NSToolbar`.

### 8. Moving content

| Content | Today | Proposed home | Why |
|---|---|---|---|
| Map → Settings card | A card in the Map's selected panel | Settings window sections (Map data, spot sources, park data) | App-wide preferences |
| Map → Style Options | A card in the selected panel | A **Map Style** panel (decided 2026-10-31), stackable with the Map as a tab | Settings of what's in view |
| Spots → Sources and Filters popover | Popover from the Map's sidebar | Stays a popover; its settings also in Settings | Quick choice next to its control |
| Operating Aids | A strip in New QSO | Stays in New QSO, and available as a panel of its own | Some will want it beside the map |

Each move is a registry entry and a view controller; the controller doesn't change hosts' code.

### 9. Focus and events

- Opening a panel doesn't take focus from a field being typed in (the plan's rule); **Show**
  brings it into view, **focus(id)** moves the keyboard there on request.
- Return and Escape belong to the frame with the focus (as the console does now).
- The controller's notification is coalesced: a style applying many changes posts once.

## macOS notes (baseline macOS 11)

| Need | API | Available |
|---|---|---|
| Sidebar pane with collapse | `NSSplitViewItem sidebarWithViewController:` | 10.11 |
| Inspector pane | `NSSplitViewItem inspectorWithViewController:` | 11.0 (its default behaviours 14.0) |
| `toggleSidebar:` | NSSplitViewController | 10.11 |
| `toggleInspector:` | NSSplitViewController | **14.0**: use the plugin's own command |
| Tracking separators in an NSToolbar | `NSTrackingSeparatorToolbarItem` | 11.0 |
| Independent toggles group | `NSToolbarItemGroup.selectionMode = selectAny` | 10.15 |
| Menu and toolbar validation | `validateMenuItem:`, `NSUserInterfaceValidations`, `NSToolbarItem validate` | long-standing |

The console keeps its own split tree (it nests rows and columns that `NSSplitViewController`
alone doesn't express); panes inside a panel may use `NSSplitViewItem` where it fits.

## Testing

- **Core** (`adif_layout`): arrangements round-trip; an unknown version restores nothing;
  migration from today's settings; presets valid (every id known, shares sum to 1).
- **One invariant in the harness**: for each panel, after each command (from the menu, the
  toolbar, the frame header, Frames, a style, a layout), the controller, the window or frame,
  the button and the menu title all agree. One loop replaces today's per-button checks.
- **Every preset at its least size**: nothing cut off or overlapping (as today, generalized).
- **Theming**: each panel snapshotted in light, dark, Night Mode and Increase Contrast; the
  language layout check, as now.

## Progress

- **Phase A** (2026-10-31): `src/core/adif_layout` with `testLayouts`.
- **Phase B, first part** (2026-10-31): the registry and controller (`src/plugin/Panels`), the
  Panels menu with Show/Hide titles, the Map's panel buttons through it, New QSO a normal window.
- **Phase B, second part** (2026-10-31): the Operating Console is built from the arrangement
  (`consoleLayout`, with `consoleLayoutPreset`; the settings before it migrated once): a split
  view per row or column, a frame per stack, tabs in the header when a stack holds more than
  one panel. Dropping a frame on another's header makes it a tab there (`moveToTab`); on its
  body the two swap. Divider drags are saved as shares; the old per-split autosaved sizes are
  no longer read, so sizes start afresh once. The tree is rebuilt only when its shape changes.
  Choosing a layout always applies it, the ticked one too.
- **Phase B, complete** (2026-10-31): each frame's actions menu (Add Tab, Move to Its Own
  Frame, Close), so every drag has a command for the keyboard and VoiceOver; the console's
  frame menus, panel names and openers come from the registry (`setOpener` and the console's
  own names retired), and QSO Details is worked out as it opens however it is opened.
- **Phase C** (2026-10-31): your own layouts (`adif::layout::Named`; kept as `consoleLayouts`,
  read entry by entry so one broken entry loses only itself): Save Layout As... (a sheet on the
  console; the frame sizes recorded as shares; a name you have used is replaced) and Delete
  Layout, in Console Layout Options after the built-in layouts. The Map's panes are kept in the
  arrangement (`workspace::paneShown`/`setPane`); `mapSidebar`, `mapList` and `mapSelected` are
  moved in once and cleared. A built-in layout keeps the panes as they are; yours brings its own.
- **Phase D** (2026-11-01): styles arrange the panels. Each style has a built-in layout (presets
  `social`, `chasing`, `contest`, `portable`) and, after Save, its own (`consoleStyleLayout<Style>`).
  Choosing a style or Reset applies it through the console (opening it when closed), unless
  **Arrange Panels** (`stylesArrangePanels`) is off; Restore Previous Layout re-applies the
  console's arrangement from before (when it was open); Use Recommended Defaults forgets the
  style's own. The field being typed in keeps the keyboard. Start Logging, Start Activation and
  Start Contest are profiles (`openProfile`: a layout and their own set-up); Start Contest now
  uses the Contest layout. The Map's list is hidden beside the spots' table as beside the Log
  Table, and the Map's least height includes its list where it shows.
- **Phase E** (2026-11-01): `src/plugin/Theme.{h,mm}`: spacing (`kMargin`, `kSpacing`; the
  older `kADIFMargin` and `kADIFSpacing` are these), type (`small`, `body`, `digits`: the 91
  hand-set small and monospaced-digit fonts now use them), colours (`styleAccent`, `fine`,
  `warning`, `error`, `faint`) and hosting. A window that docks is hosted when it shows
  (`orderWindow:relativeTo:` in `ADIF_DOCKABLE_WINDOW`), with no call of its own; docked, it takes
  the console's look (`theme::rehost` on dock and undock). That fixed a double Night Mode tint
  on every docked panel. Popovers are hosted through `theme::hostPopover` (two were missed
  before). Not yet: the semantic colours at the older call sites, which keep the system colours
  they name.
  Next (Phase F): content moves (Map Settings to Settings, the Map Style panel).

## Plan

Each phase leaves the plugin working and tested.

| Phase | Builds | Retires |
|---|---|---|
| A. Model | `adif_layout`: panel ids, arrangement, presets as data, parse/write, migration; tests | — |
| B. Controller | Registry and controller; hosts over `ADIF_DOCKABLE_WINDOW`; Map toolbar, Frames menu, frame headers and a Panels submenu bound to it | `kPanels`, openers, item names, the per-panel notifications |
| C. Layouts | Layouts submenu: presets as data, Save Layout As…, Reset; the Map's panes in the arrangement | Hard-coded presets; separate pane settings |
| D. Profiles | Styles carry an optional layout (with the opt-out); Start Logging / Activation / Contest as profiles | Their own layout code |
| E. Theme | Tokens; hosts apply appearance and Night Mode; panels use tokens | `ADIFNightTrack` per window, ad hoc fonts and margins |
| F. Content | Map Settings to Settings; Style Options to an inspector; new panels through the registry | The cards' bespoke hosting |

## Decisions

Made 2026-10-31:

1. **Styles arrange the panels by default**, with a setting to turn it off and "keep my layout"
   per style.
2. **New QSO is a normal window** when it isn't in the console.
3. **Tabs (stacked panels) are in scope now**: a console frame can hold several panels as tabs,
   first for the Map Style panel and Settings sections. Phase A's arrangement includes stacks;
   Phase B's console frame host shows a tab bar when a stack holds more than one panel.
4. **A Map Style panel** replaces the Style Options card.

5. **Toolbar order follows Apple's**: the sidebar button at the far left, the panel buttons at
   the right, the list and selected-panel (inspector) buttons at the far right.

## Sources

Read 2026-10-31 (Apple pages from Apple's own documentation; quotes summarized by the research
tool, so spot-check exact wording):

- Apple HIG: [Windows](https://developer.apple.com/design/human-interface-guidelines/windows),
  [Panels](https://developer.apple.com/design/human-interface-guidelines/panels),
  [Split views](https://developer.apple.com/design/human-interface-guidelines/split-views),
  [Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars),
  [Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars),
  [The menu bar](https://developer.apple.com/design/human-interface-guidelines/the-menu-bar),
  [Menus](https://developer.apple.com/design/human-interface-guidelines/menus).
- AppKit: [NSSplitViewController](https://developer.apple.com/documentation/appkit/nssplitviewcontroller),
  [NSSplitViewItem](https://developer.apple.com/documentation/appkit/nssplitviewitem),
  [NSTrackingSeparatorToolbarItem](https://developer.apple.com/documentation/appkit/nstrackingseparatortoolbaritem),
  [NSToolbarItem identifiers](https://developer.apple.com/documentation/appkit/nstoolbaritem/identifier),
  [NSToolbarItemGroup selection mode](https://developer.apple.com/documentation/appkit/nstoolbaritemgroup/selectionmode-swift.enum),
  [NSToolbarItem validate](https://developer.apple.com/documentation/appkit/nstoolbaritem/validate()),
  [NSUserInterfaceValidations](https://developer.apple.com/documentation/appkit/nsuserinterfacevalidations),
  [validateMenuItem](https://developer.apple.com/documentation/appkit/nsmenuitemvalidation/validatemenuitem(_:)),
  [NSSplitView autosaveName](https://developer.apple.com/documentation/appkit/nssplitview/autosavename-swift.property),
  [NSWindowRestoration](https://developer.apple.com/documentation/appkit/nswindowrestoration),
  [hidesOnDeactivate](https://developer.apple.com/documentation/appkit/nswindow/hidesondeactivate);
  [UI Validation guide](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/UIValidation/Articles/ValidatingObjects.html)
  (archived, 2007: concepts only).
- Qt 6: [QMainWindow](https://doc.qt.io/qt-6/qmainwindow.html) (`saveState`, `restoreState`),
  [QDockWidget](https://doc.qt.io/qt-6/qdockwidget.html) (`toggleViewAction`).
- VS Code: [Custom layout](https://code.visualstudio.com/docs/configure/custom-layout),
  [UX guidelines](https://code.visualstudio.com/api/ux-guidelines/overview),
  [When-clause contexts](https://code.visualstudio.com/api/references/when-clause-contexts).
- JetBrains: [Tool windows](https://www.jetbrains.com/help/idea/tool-windows.html),
  [Tool window layouts](https://www.jetbrains.com/help/idea/tool-window-layouts.html).
- Eclipse: [Perspectives](https://help.eclipse.org/latest/topic/org.eclipse.platform.doc.user/concepts/concepts-4.htm).

The local library had no material on these (no HIG, AppKit, Qt dock widget or IDE layout
entries).
