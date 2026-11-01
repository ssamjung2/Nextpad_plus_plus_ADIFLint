# Operating Styles Plan

## Purpose

Add an **Operating Style** control to the Map and Contact Explorer toolbar. The
style describes what the operator is trying to accomplish and adapts the map,
contact list, selected-contact panel, logging workflow, and related windows to
that goal.

The initial styles are:

1. **Social** — ragchewing, casual QSOs, nets, roundtables, club activity, and
   elmering.
2. **Chasing** — DXCC, awards, new entities, band fills, mode fills, parks,
   watched stations, and other explicit goals.
3. **Contest** — maximizing valid contacts and points while reducing exchange
   and duplicate-checking cognitive load.
4. **Portable** — POTA, IOTA, WWFF, SOTA, and other temporary operations with
   limited power, connectivity, screen space, or time.

Operating Styles are a workflow layer above existing History, Live, DX Chase,
POTA, activation, and contest capabilities. They should compose existing
features rather than replace them.

## Human guidance and operating aids

Operating Styles should provide optional, on-screen guidance that helps the
operator inhabit the selected workflow. Guidance is not a script and must never
imply that the operator must ask a question, disclose personal information, or
follow a recommendation. It should reduce friction while leaving the human in
control.

Guidance can appear as a compact **Operating Aids** card, a suggestion row in
New QSO, or an optional next-action strip. It should:

- be dismissible and easy to hide for the session or permanently;
- appear at natural pauses, not while the operator is entering an exchange;
- use progressive disclosure instead of filling the screen with prompts;
- explain why a suggestion is shown when the reason is not obvious;
- offer one-click insertion only when the result is fully editable;
- distinguish suggestions from facts, logged data, and validated exchanges;
- avoid repetition by tracking dismissed and used prompts locally;
- remain useful without network access through local templates and context;
- never infer or expose sensitive personal information without explicit action.

The first implementation should use curated, deterministic prompt libraries and
known local context. It should not require an opaque conversational model or
operator-behavior telemetry.

### Traditional amateur-radio foundation

The initial guidance library should start with the subjects and exchanges
already familiar to amateur operators. This gives the feature a recognizable,
welcoming baseline instead of making it feel like a generic conversation
assistant.

Traditional topics and exchange cues should include:

- callsign, name, and QTH;
- signal report, readability, and propagation conditions;
- rig, transmitter, receiver, antenna, feed line, and power;
- band, frequency, mode, and operating conditions;
- weather, temperature, season, and local conditions;
- first licensed, years operating, and how the operator became interested in
  amateur radio;
- license class, operating privileges, and favorite bands or modes;
- other amateur-radio interests such as DXing, contesting, satellites,
  digital modes, Morse code, emergency communications, field days, and
  portable operating;
- clubs, nets, repeaters, hamfests, conventions, and local amateur events;
- QSL preferences, logging, awards, and follow-up;
- a courteous closing and confirmation of the callsign.

These are starting points, not required questions. The aid should present them
as familiar optional cues and allow the operator to choose a natural variation.
For example:

> “What equipment are you running today?”

> “How are conditions on your side of the contact?”

> “What brought you into amateur radio?”

> “Are you active with a local club or net?”

> “Do you enjoy any particular bands or modes?”

For structured exchanges, the library should also recognize the normal
amateur-radio sequence: callsign, report, name/QTH, station details, an
interest or closing topic, and callsign confirmation. It should support
context-specific variations for nets, contests, Field Day, public-service
events, and activations without presenting a casual QSO as a contest form.

The initial content should be reviewed by experienced operators for
authenticity, regional variation, respectful phrasing, and appropriate
operating etiquette. It should include a neutral **Skip**, **Not applicable**,
or **Change topic** action at every stage.

### Social operating aids

Social mode should help sustain a comfortable, respectful conversation without
turning the QSO into a checklist. Optional topic cards may include:

- equipment, antenna, and station setup;
- current weather and operating conditions;
- age, only as a gentle optional topic and never as an assumption;
- career, education, or current projects;
- hobbies and interests;
- local area, travel, clubs, and events;
- mentoring or “how did you get started?” prompts;
- a free-form “something else” prompt.

The UI can offer a small rotating set of prompts, such as:

> “Want to ask about their antenna or station setup?”

> “You could share what the weather is like at your station.”

> “Ask whether they participate in a local club or net.”

Prompts should account for known local context. A topic already present in
notes should not be suggested again, and used topics can be marked for that
contact. Operators should be able to pin favorite prompts, maintain their own
prompt set, and disable categories such as age or career.

After a social QSO, optional aids can provide a notes reminder, conversation
tags, a promised-follow-up reminder, or a “continue conversation” state for
nets and roundtables. These aids should encourage human connection, not judge
conversation quality or optimize conversation length.

### Chasing operating aids

Chasing guidance should keep attention on the operator’s goal:

- explain why a selected station is valuable;
- show the next missing band, mode, entity, award, or program credit;
- suggest the best next action after a failed, stale, or duplicate spot;
- distinguish already worked from unconfirmed;
- provide concise preparation cues before New QSO.

For example:

> “This is new on 15m but already worked on 20m. Confirm the frequency and
> mode before logging.”

The aid must not conceal lower-ranked opportunities or make an unexplained
decision on the operator’s behalf.

### Contest operating aids

Contest guidance should be terse, stable, and exchange-focused:

- show the next required exchange item;
- identify duplicate and multiplier status;
- provide a short correction cue for an incomplete exchange;
- surface the next serial number or contest-specific field;
- show compact rate or progress feedback at a configurable interval;
- provide recovery guidance after an invalid or interrupted entry.

Examples include “Needs received serial number,” “New multiplier on this band,”
and “Duplicate on 20m; verify the band before logging.” Contest aids must not
animate unnecessarily, interrupt keyboard entry, or replace authoritative
contest validation.

### Portable operating aids

Portable mode should provide short, practical cues for changing conditions:

- quick social exchanges suitable for a short contact;
- smooth operating cues such as “ready to log,” “duplicate check complete,”
  and activation progress;
- low-power, offline, and synchronization status;
- reminders to save locally before moving or closing the window;
- a one-tap minimal-logging path when conditions are difficult;
- optional environmental reminders when relevant local data is available.

Examples include:

> “3 contacts remain for today’s activation.”

> “Saved locally; internet unavailable. You can continue operating.”

> “Quick topic: share your location or ask about their setup.”

Portable prompts should be brief enough to glance at outdoors and must not
depend on continuous connectivity. Battery, network, and environmental data is
assistance, not authoritative safety advice.

### Guidance controls, safety, and privacy

Provide global and per-style controls for:

- Operating Aids: **Off**, **Minimal**, **Standard**, or **More**;
- prompt timing: **At natural pauses**, **After each QSO**, or **Manual**;
- topic categories and portable connectivity/power cues;
- local use of contact history;
- resetting dismissed prompts and editing personal prompts.

Include a quick **Hide aids** action in the active workflow. Store guidance
state per style, with temporary session hiding taking precedence.

Treat names, ages, careers, hobbies, notes, and location details as potentially
sensitive. Never fabricate facts, automatically read a private note aloud, or
place private information on air. Label external information, make insertion
explicit and editable, avoid prompts about sensitive topics, and always offer a
neutral **Skip** action. Keep personal prompt libraries and usage history local.

## Product principles

- **Goal-directed:** show the information needed for the current operating
  intent first.
- **Explainable:** when the application ranks or hides something, explain why.
- **Reversible:** style changes must be inspectable, undoable, and resettable.
- **Personal:** users can refine each style without losing recommended defaults.
- **Safe:** never silently change credentials, logging targets, active contest
  state, or log data.
- **Offline-capable:** Portable mode must remain useful when live services are
  unavailable.
- **Accessible:** preserve keyboard operation, VoiceOver labels, contrast,
  color-blind-safe palettes, and night readability.
- **Low interruption:** avoid stealing focus or changing a user’s active task
  unexpectedly.
- **Human-centered assistance:** guidance should extend the operator’s
  experience without replacing judgment, personality, or consent.

## Toolbar interaction

Add a compact segmented control or popup to the Map toolbar:

```text
Operating: Social | Chasing | Contest | Portable
```

Changing the selection should:

1. Save the current style’s customized state.
2. Apply the selected style’s profile.
3. Preserve the selected station, map center, document, and explicit
   band/mode filters where practical.
4. Show a short status message describing the transition.
5. Offer **What changed?**, **Restore previous layout**, and **Reset this
   style** actions.

Display a subtle customized indicator when the user has overridden recommended
settings. Style switching should not automatically start a contest, activate a
program, change the logging destination, or enable credentials/network access.

## Style profiles

### Social

Optimize for recognition, context, warmth, and low pressure.

- Show recent, local, or regionally relevant activity.
- Prefer callsign, operator name, location/grid, distance, bearing, and contact
  history over award urgency.
- Use a calm, low-density visual treatment with limited spot emphasis.
- Make notes and operator context prominent in New QSO.
- Support logging and retaining the selected station for nets and roundtables.
- Make prior conversation context easy to find.

### Chasing

Optimize for goal visibility, explainable prioritization, and progress.

- Enable useful live spots and rank opportunities by personal need.
- Surface new DXCC, band, mode, award, park, IOTA, watch-list, and confirmation
  opportunities.
- Show spot age, source, frequency, mode, distance, and confidence.
- Explain each recommendation, for example:
  “New DXCC on 20m and new digital-mode credit; spotted 42 seconds ago.”
- Pre-fill New QSO from the selected spot.
- Warn early about duplicates and already-worked targets.
- Provide next-opportunity navigation and post-log advancement.

### Contest

Optimize for recognition over recall, stable spatial layout, minimal scanning,
fast validation, and error recovery.

- Make the contest/New QSO workflow primary and keep the map compact.
- Emphasize duplicate status, new multipliers, exchange requirements, serial
  numbers, point value, and logging validity.
- Use keyboard-first exchange entry and predictable field placement.
- Minimize dialogs and confirmation prompts.
- Provide compact QSO count, rate, multiplier, and score feedback.
- Keep spotting available without allowing spot noise to compete with exchange
  entry.
- Require explicit contest setup; selecting the style alone must not start one.

### Portable

Optimize for simplicity, reliability, visibility, low power, and interruption
recovery.

- Use a compact, high-contrast, optional night-readable layout.
- Prefer cached/offline data and reduce or disable continuous network refresh.
- Show only the activation/site, nearby contacts, essential spots, and progress.
- Make local queue and synchronization state explicit:
  **Saved locally**, **Waiting to sync**, **Synced**, or **Sync failed**.
- Allow essential-field logging first and enrichment later.
- Automatically protect activation fields from omission.
- Make network- and battery-intensive actions explicit.

Portable is a general operating constraint. POTA, IOTA, WWFF, and SOTA remain
activity/program contexts that can be used within it.

## Personalization model

Each style has three layers:

```text
Recommended defaults
        ↓
User overrides
        ↓
Temporary session changes
```

Store per-style state separately, for example:

```text
operatingStyle = chasing
style.social.mapState = ...
style.chasing.mapState = ...
style.contest.mapState = ...
style.portable.mapState = ...
style.chasing.override.spotAge = ...
```

Prefer a typed profile model over scattered setting mutations:

```cpp
enum class OperatingStyle {
    Social,
    Chasing,
    Contest,
    Portable
};
```

The eventual profile should cover map presentation, quick views, layout,
logging, spots, power, and network policy. Provide explicit operations to
capture, apply, reset, and report profile changes.

## Staged implementation plan

### Stage 0 — Research and product definition

- Document operator journeys for all four styles.
- Identify each style’s top tasks, must-show data, must-hide data, and failure
  behavior.
- Decide whether the first release affects only the Map or also rearranges New
  QSO and other windows.
- Define accessibility, outdoor-use, offline, and performance requirements.

**Exit criteria:** each style has measurable acceptance criteria and a defined
primary goal.

### Stage 1 — Profile architecture

- Add the operating-style enum and persisted selection.
- Add profile serialization, validation, and migration.
- Capture and restore per-style map state.
- Add an application coordinator and change report.
- Preserve existing History, Live, DX Chase, and POTA behavior.

Primary integration points:

- [`Map.h`](../src/plugin/Map.h)
- [`Map.mm`](../src/plugin/Map.mm)
- [`MapView.h`](../src/plugin/MapView.h)
- `ADIFLint.mm` for shared window/layout coordination

### Stage 2 — Toolbar and reversible transitions

- Add the style selector to the Map toolbar.
- Add reset, restore-previous-layout, and what-changed actions.
- Add keyboard and accessibility support.
- Preserve selection and map center when possible.
- Add fixture-driven tests for profile application and persistence.

### Stage 3 — Social and Portable

Implement these first to establish personalization and offline behavior:

- Social recent-contact, operator-context, and notes-first workflow.
- Portable offline-first layout, activation progress, local queue, sync state,
  night palette, and reduced refresh policy.
- Add the first Operating Aids card with curated Social and Portable prompts.
- Add dismiss, skip, hide, prompt-density, and category controls.
- Keep prompt insertion explicit, editable, and local.

### Stage 4 — Chasing

- Define a normalized opportunity model.
- Combine DXCC, band, mode, award, park, IOTA, watch-list, and confirmation
  needs.
- Add deterministic, explainable ranking.
- Add next-opportunity navigation and post-log advancement.

Every ranked opportunity must provide a human-readable reason, and the UI must
distinguish a spot from a worked or confirmed contact.

### Stage 5 — Contest

- Define a compact contest layout policy.
- Integrate with contest setup and exchange handling.
- Add duplicate and multiplier emphasis.
- Add keyboard-first exchange workflow and rate/progress feedback.
- Test incomplete and invalid exchanges without network access.

The existing contest implementation is in
[`Contest.mm`](../src/plugin/Contest.mm). Style selection must prepare the UI
without silently starting or changing the active contest.

### Stage 6 — Cross-window orchestration

Generalize the existing logging layout into a style-aware policy:

```text
Social:   Map + New QSO + notes/context
Chasing:  Map + ranked opportunities + New QSO
Contest:  Contest/New QSO dominant + compact map
Portable: compact New QSO + activation progress + minimal map
```

The user must be able to opt out of automatic window arrangement, and the
profile must not steal focus while the operator is typing.

### Stage 7 — Personalization

- Add per-style layer and filter overrides.
- Add Chasing goal weights.
- Add contest display density.
- Add Portable refresh policy.
- Add Social context fields.
- Add personal prompt libraries and per-category guidance preferences.
- Track dismissed prompts locally to avoid repetition.
- Allow “use my current layout as this style’s default.”
- Allow section-level reset.

Use explicit preferences and explainable rules before considering adaptive or
machine-learning behavior. Keep personalization local and do not add operator
behavior telemetry.

### Stage 8 — Validation and hardening

Test large, empty, and missing logs; offline mode; failed feeds; missing home
grid; missing park/IOTA data; incomplete contests; interrupted activations;
multiple documents; small windows; dark/night themes; VoiceOver; keyboard-only
operation; color-blind-safe palettes; prompt dismissal; prompt insertion;
privacy-sensitive notes; and guidance while typing a contest exchange.

Measure style-transition latency, map redraw responsiveness, spot refresh
behavior, and offline logging reliability rather than assuming acceptable
performance.

## Stage 0 definition (2026-10-30)

Drafted from this plan and the Map as it is in 1.7.0. The defaults below shipped with the
toolbar (Stage 2); they are still open to review.

### Decisions

- **The first release changes the Map only.** New QSO, the Log Table and window arrangement
  stay as they are until Stage 6. The Map's own workflows (History, Live, DX Chase, POTA),
  Quick Views and saved views keep working as before; a style sits on top of them.
- **No style is the default.** Until the operator picks one, nothing changes; choosing
  **None** again leaves the Map as it was when the last style was left.
- **A style owns only Map presentation settings** (`map*` keys): the workflow, the workflow's
  own keys (layers, contacts and lines, colour by, list kind, Quick View, sun shading, spot
  program), the palette, text size and range rings. The defaults are checked in tests to
  contain nothing else.
- **A style never touches** Offline Mode, Night Mode, spot sources or accounts, the logging
  target, station profiles, an activation, a contest, or the log. It never changes the Map's
  centre and zoom, the selected station, or the band and mode chosen in the toolbar.
- **Per-style state:** leaving a style saves what it owns as the operator left it; coming back
  restores that. **Reset this style** drops the saved state and applies the defaults again.
  **Restore previous layout** undoes the last change of style, values and selection both.
- **Night Mode wins:** while it is on, the Map uses the Night palette whatever a style says.

### Styles

| | Social | Chasing | Contest | Portable |
|---|---|---|---|---|
| Primary goal | A comfortable QSO with context | The next needed contact | Valid contacts quickly | Operate reliably in the field |
| Top tasks | See who they are and where; past QSOs with them | Find needed stations; know why each matters | Spot activity; see worked and multiplier status | Log; see activation progress; keep working offline |
| Must show | Contacts and lines, distance and bearing | Needed spots, DXCC shading, grey line | Spots with labels, CQ zones | This log's contacts, range rings |
| Quiet or hidden | Spots, award shading | Parks (unless chased), extra layers | Award shading, decoration | Spot feeds, sun shading, extra layers |
| Map workflow | History, Contacts view | DX Chase, Needed on its band | Live, All spots | History, Contacts view |
| Presentation | Standard palette | Standard palette | High contrast | High contrast, larger text |
| Failure behaviour | Works with an empty log or no home grid | Says when feeds fail; never hides that a spot is stale | Map stays compact and still; nothing steals focus | Fully useful offline; no feed starts by itself |

### Acceptance criteria (first release)

1. Choosing a style changes only the keys that style owns, and reports each change.
2. Leaving a style and coming back restores it as it was left, after quitting too.
3. Reset gives the defaults; Restore previous layout gives back exactly what was there.
4. With no style chosen, the Map behaves exactly as in 1.7.0.
5. A style's defaults name only `map*` keys (checked in tests).
6. Switching styles keeps the selected station, centre, zoom, band and mode.
7. Portable starts no spot feed; Contest's map makes no animation of its own.
8. Every control is reachable from the keyboard and labelled for VoiceOver (Stage 2).

## Progress

- **Stage 0:** drafted above; the defaults shipped as proposed (see Defaults below).
- **Stage 1, core:** done in `src/core/adif_styles.{h,cpp}`: the style enum and its ids, each
  style's defaults, the owned keys, saved state per style (`mapStyle<Id><key>`), and the change
  report (snapshot, diff, reversed, customized). `testOperatingStyles` in `tests/adif_tests.cpp`
  covers it.
- **Stage 1, Map:** done (2026-10-31) in `Map.mm`, "Operating styles": choosing a style saves
  the one left, switches the workflow (which keeps its own as before), chooses the Quick View
  the first time and sets the rest; None changes nothing. The selection is `mapOperatingStyle`.
- **Stage 2, toolbar:** done (2026-10-31): the style menu at the left of the Map's toolbar, with
  No Style, the four styles (the chosen one ticked, "(changed)" once its settings differ from
  its defaults), Reset, Restore Previous Layout and What Changed… (a popover, setting by
  setting, before and after). VoiceOver announces each change. What is chosen on the map stays chosen across
  a change of style: the Map finds the same square, entity, park, contact or station in the
  data it makes afresh.
- **Stage 2 is complete (2026-10-31): every acceptance criterion is checked.**
  - 1–3: the host harness chooses each style, opens What Changed, restores exactly what was
    there, keeps a style's changes while another is chosen (saved in ADIFLint.ini), resets,
    restores after a reset, and checks that No Style changes nothing.
  - 4: every other Map check runs with no style chosen.
  - 5: `testOperatingStyles` in the core tests.
  - 6: the centre and zoom, the band chosen and the contact chosen are all unchanged after
    Social to Portable to Contest.
  - 7: Portable has no spots, space weather or aurora; Contest turns the beacons off, the one
    layer that redraws by itself.
  - 8: the style menu comes first in the toolbar's Tab order (before the workflow). VoiceOver
    reads it as a menu button labelled "Operating style" with the style as its value; every
    item is named; What Changed reads each cell as static text.
- **Defaults:** as proposed in the Stage 0 table, with two additions: Portable turns the grid
  overlay off (`mapGrid`), so the contacts aren't drawn over a grid of field names; Contest turns
  the NCDXF beacons off (`mapBeacons`), the one layer that redraws by itself (every 10 seconds),
  for criterion 7.
- **Stage 3 is complete (2026-10-31).**
  - The library is `src/core/adif_aids.{h,cpp}`: 16 curated prompts in the order of a QSO,
    13 topics (age and career off at first, with no Note words for age), levels Off, Minimal,
    Standard and More, and timings (natural pauses, after each QSO, only on Skip). Suggestions
    skip topics the notes already cover (word starts, so "net" doesn't match "internet"),
    dismissed prompts and topics turned off, and give a reason when it isn't plain.
    `testOperatingAids` covers it.
  - New QSO's Operating Aids strip: Social's earlier QSOs and notes with the call, Portable's
    cues (activation progress, ready or missing, the duplicate check, saved or not, waiting to
    sync or synced, offline, lighter spots), suggestions in italics with Note, Skip and Dismiss,
    Hide for the session, and Options (per style, in ADIFLint.ini as `aidsLevel<Style>`,
    `aidsTiming<Style>`, `aidsTopicsOff<Style>`; `aidsDismissed` for all).
  - Portable's lighter network (`spotfeeds::lowPower`): Spothole every 5 minutes, and no DX
    cluster connection or PSKReporter live feed; the feeds restart when the style changes to
    or from Portable.
  - The host harness checks each of these, and the facts and suggestions are kept apart for
    VoiceOver ("Suggestion: …").
  - Not done, for later stages: "Sync failed" (the upload windows don't keep a failure), a
    minimal-logging path, and the personal prompt libraries and pinned prompts (Stage 7).
- **After Stage 3 (2026-10-31), from review:** the styles are a segmented control in each
  style's colour, with a menu of No Style, Reset, Save and Info. **Save** brings forward
  Stage 7's "use my current layout as this style's default" (`saveMine`, `startingPoint` in
  `adif_styles`); **Info** replaces What Changed and holds Restore Previous Layout and Use
  Recommended Defaults.
- **Stage 6, cross-window orchestration (2026-11-01, with the windowing plan's Phase D):** each
  style arranges the Operating Console (its built-in layout, or its own after Save), with the
  opt-out **Arrange Panels**; Restore Previous Layout and Use Recommended Defaults cover the
  panels too; a field being typed in keeps the keyboard.
- **Next:** Stage 4 (Chasing: ranked, explained opportunities).

## Initial backlog

1. Define journeys and acceptance criteria.
2. Add the operating-style enum and persisted selection.
3. Add per-style profile capture and restore.
4. Add the reversible toolbar control.
5. Implement Social defaults.
6. Implement Portable defaults.
7. Add the Operating Aids card and curated Social/Portable prompts.
8. Add reset, hide, density, category, and customization controls.
9. Add profile application and guidance tests.
10. Implement explainable Chasing ranking and aids.
11. Implement Contest layout, exchange integration, and terse aids.
12. Add cross-window orchestration.
13. Run usability, privacy, and accessibility review.

## Build and installation reference

The repository’s documented local installation workflow includes:

```sh
cmake --install build
```

After implementation, use the project’s existing configure/build/test workflow
to validate the smallest affected targets, then run the installation command
above when validating the installed plugin integration. Do not treat
installation as a substitute for tests; style profiles should be covered by
focused automated tests, with broader tests added when cross-window behavior is
introduced.

## MVP boundary

The first release should include:

- A toolbar style selector.
- Four persisted profiles.
- Map layer/filter/layout changes.
- Fully useful Social and Portable profiles.
- Explainable Chasing prioritization.
- A compact Contest-aware layout.
- Optional, curated on-screen guidance for Social and Portable.
- Per-style customization and reset.

It should not initially include opaque adaptive behavior, silent network changes,
automatic contest start, or destructive ADIF changes.
