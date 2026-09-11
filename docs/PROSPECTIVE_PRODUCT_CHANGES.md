# Prospective Product and UX Changes

Status: product-direction proposal  
Audit date: 2026-09-11  
Scope: functional workflow, information architecture, and usability. This is not an implementation plan or a commitment to change the project format.

## Executive recommendation

OpenRecord already has the capabilities needed for a strong local-first recording product. The highest-value work is not adding more editing tools. It is making the common path obvious and moving specialist controls out of that path.

The product should optimize for this journey:

```text
Open local library
  -> Record, Import, or Open
  -> Confirm a simple capture setup
  -> Record with visible health feedback
  -> Play and trim the result
  -> Optionally use local analysis and suggestions
  -> Review privacy
  -> Export and immediately open, reveal, or share the result
```

There is intentionally no login or account step. OpenRecord's first screen should explain the local library and offer useful actions, not imitate account onboarding. The no-account, no-cloud-required model is a core benefit and should remain prominent.

The most beneficial changes are:

1. Simplify recording setup to source, audio, camera, and one preset; place telemetry and template details under **Capture Options**.
2. Request only the permissions needed for the selected setup, before the countdown begins.
3. Replace the automatic post-recording First Cut takeover with a recording summary while analysis continues in the background.
4. Reduce the editor's simultaneous concepts: keep one clear **Analyze** entry point, a selection-driven inspector, and one primary **Export** action.
5. Hide batch-selection checkboxes until the user enters batch mode, then add search, sort, duration, and project status to the library.
6. Finish exports with a useful result surface: **Open**, **Reveal in Finder**, **Share**, **Copy Path**, and **Export Again**.
7. Preserve advanced capabilities, but reveal them only when the user's current task or selection makes them relevant.

## Product position to preserve

OpenRecord is a native Apple Silicon screen recorder and non-destructive editor for product demos, tutorials, changelog videos, documentation, and lightweight marketing clips. Its strongest differentiation is local, private interaction evidence that can help produce and verify a recording—not generic nonlinear-editor breadth.

The redesign should preserve these contracts:

- No account, API key, proprietary cloud, hosted share service, or cloud-required analysis.
- Transparent `.openrecord` folders and immutable raw capture.
- Non-destructive, reversible editing with coherent undo and redo.
- Suggestion-only automation that explains proposed changes and requires approval.
- Privacy review before rendered export, with honest best-effort language.
- Sanitized Share Copy as a separate derivative; the editable source is never described as sanitized.
- Project browsing, importing, and editing without capture permissions.
- Preview/export timestamp and layout parity as an engineering contract.
- Advanced command and keyboard access for expert users, even when those commands are not always visible in the main UI.

OpenRecord should not expand toward hosted collaboration, live streaming, stock media, arbitrary effect plug-ins, generated presenters, or general NLE/DAW workflows. Those additions would increase complexity while weakening the local-first position.

## Users and their actual jobs

### First-time recorder

The user wants to understand where files go, choose a screen or window, get the correct permissions, and make a successful recording. They should not need to understand semantic targets, ActionMap, telemetry, project templates, or codec settings before starting.

### Repeat recorder

The user wants the last successful setup remembered, a fast way to confirm source and audio, and confidence that capture is healthy. The global shortcut and menu-bar extra should support this path.

### Editor and publisher

The user wants to remove mistakes, make the recording readable, check privacy, and produce a file. Transcript, Actions, First Cut, styling, and batch export are valuable accelerators, but they should not compete with play, trim, and export.

### Advanced or batch user

The user wants exact timeline operations, reusable templates, multiple export formats, batch jobs, diagnostics, and keyboard commands. These features should remain available in explicit modes, menus, inspectors, and shortcuts.

## Proposed information architecture

### Library

Primary toolbar:

- **Record**
- **Import**
- Search
- **More** menu: Open Project, Batch Export, Library Folder, Permissions, Support

Project rows should show thumbnail, title, duration, modified date, and a small status such as Draft, Needs Review, Exported, Recovered, or Read-only. Batch checkboxes appear only in **Select for Batch Export** mode.

The empty library should offer both **Record Screen** and **Import Movie**, show the library location, and explain that capture permissions are requested only when needed.

### Recorder

Default surface:

- Display/Window source picker
- Simple preset: Screen Only, Tutorial, Presentation, or Camera Demo
- Compact status chips for Microphone, System Audio, Camera, and required permissions
- **Record**

Disclosure surface, labeled **Capture Options**:

- Microphone and system-audio details
- Webcam
- Cursor activity
- Keyboard shortcuts
- Semantic UI interactions and story markers
- Project template
- A visible note that these choices are remembered for the next recording
- **Reset Recording Defaults**

The advanced section should use short descriptions and help buttons instead of six paragraph-length explanations in the main flow.

### Editor

Primary toolbar:

- Back to Library
- Playback controls and output duration
- **Analyze**
- **Privacy**
- **Export**

The **Analyze** surface groups Transcript, Actions, Remove Pauses, and Suggested Edit. Use plain language in the primary UI:

- “Actions” instead of “ActionMap”
- “Suggested Edit” or “Draft” instead of “First Cut”
- Technical names may remain in documentation, diagnostics, and advanced menus

The inspector should become selection-driven:

- When a timeline item is selected, show that item's controls first.
- When nothing is selected, show a compact Add menu and project-level look controls.
- Put canvas, device frame, webcam look, cursor look, and reusable presets under **Look**.
- Remove export configuration from the persistent inspector; show it in the Export workflow.
- Hide controls that cannot affect the current project, such as webcam styling when no webcam track exists.

### Export

The default workflow should be:

1. Choose **Export Video**.
2. Review unresolved privacy findings.
3. Choose a simple output size/quality or a remembered recipe.
4. Export.
5. Show result actions: Open, Reveal in Finder, Share, Copy Path, Export Again.

Advanced output choices—codec, frame rate, ProRes, Fast Export, GIF, audio, and snapshot—belong under **Advanced** or an adjacent format menu. **Sanitized Share Copy** should be next to Export with an explicit explanation that it creates a derivative and leaves the editable source unchanged.

## Prioritized changes

| Priority | Change | User benefit | Scope |
|---|---|---|---|
| P0 | Contextual permission preflight before countdown | Prevents failed or interrupted first recordings and builds privacy trust | Modify existing permission flow |
| P0 | Compact recorder with presets and Capture Options disclosure | Makes the first successful recording much faster | Reorganize existing controls |
| P0 | Selection-driven inspector and simpler editor toolbar | Reduces cognitive load without deleting capability | Reorganize existing editor UI |
| P0 | Clear timeline lanes, selection state, and keyboard/VoiceOver access | Makes core editing understandable and operable | Modify timeline UI and accessibility |
| P0 | Guard library-folder changes while a project is open | Prevents confusing old-library/new-library state | Correctness fix |
| P1 | Recording-complete summary; background Suggested Edit | Gives immediate control after Stop and makes automation optional | Modify post-capture handoff |
| P1 | Explicit library batch mode | Removes permanent checkbox noise from every project | Reorganize existing batch workflow |
| P1 | Library search, sort, duration, and lightweight statuses | Helps users find and assess projects without opening each one | Add derived metadata/UI |
| P1 | Export completion actions and remembered destination | Completes the user's job instead of silently ending progress | Add completion UI |
| P1 | Capture health in HUD and post-stop warnings | Surfaces low disk, track loss, interruption, and mute state when actionable | Expose existing diagnostics |
| P1 | Task-specific errors and recovery actions | Replaces generic OK-only failures with a next step | Modify alerts |
| P1 | Global Support/Diagnostics and shortcut help | Makes recovery and expert features discoverable | Reorganize menus |
| P2 | Recent source selection and mic-level/camera preflight | Speeds repeated capture and prevents bad audio/video | Add capture polish |
| P2 | Favorite/pin and optional project notes | Helps larger libraries without forcing a full media manager | Add only after search/status validation |
| P2 | Short rendered preview of current range | Gives final-compositor confidence before a long export | Add bounded render workflow |

## Detailed recommendations by journey

### 1. Launch and first use

**Include**

- A welcome state inside the empty library, not a blocking onboarding wizard.
- Two equally clear actions: **Record Screen** and **Import Movie**.
- The current library location and a concise local-first explanation.
- A statement that permissions are requested only for selected capture features.

**Modify**

- Change the always-visible global **Capture Permissions** toolbar item into a contextual status/action in the recorder and an item under More or Support.
- Rename the current **Settings** action to **Library Folder…** until a true multi-section Settings window exists.
- When opening an external read-only project, present a clear **Make Editable / Add to Library** callout instead of relying on small status-bar links.

**Remove from the default surface**

- The persistent full library path at the bottom of the sidebar. Show it in the empty state, Library Folder sheet, and tooltip instead.
- Always-visible batch-selection checkboxes and batch-management buttons.

### 2. Capture preparation

**Include**

- A preflight summary: selected source, audio tracks, camera, recording metadata, and required permissions.
- Actionable no-source states: **Open Screen Recording Settings**, **Retry**, and a message when no windows are available.
- A stale-source check immediately before capture in case a selected window has closed.
- A mic level check and webcam preview when those tracks are enabled.
- Simple presets that set sensible combinations without hiding the resulting state.

**Modify**

- Ask for permissions after the user chooses features but before the 3-2-1 countdown.
- Derive required permissions from the actual capture request. Do not request Camera, Microphone, or Accessibility when the setup does not use them.
- Clearly state that capture choices persist to future recordings.
- Group options as Audio, Camera, Editing Metadata, and Advanced Privacy.

**Remove from the default surface**

- Project-template selection and technical telemetry explanations.
- The broad **Request Remaining** action that requests every ungranted permission.

### 3. Active recording and recovery

**Include**

- HUD indicators for elapsed time, microphone state, camera state, and overall capture health.
- Direct low-disk and interrupted-track warnings while the user can still respond.
- Menu-bar state for Recording, Finalizing, Saved with Warnings, and Failed.
- **Restart Take** or **Discard Take** after stopping a mistaken recording.
- A visible story-marker action when semantic capture is enabled.

Do not add Pause until capture and timestamp continuity are proven reliable. A restart-take workflow provides more honest recovery with much lower correctness risk.

**Modify**

- Hide microphone mute controls when no microphone is being captured.
- Distinguish media finalization, local analysis, and Suggested Edit generation instead of presenting all work as “Finishing recording…”.

### 4. Post-recording handoff

The immediate result of Stop should be a recording summary, not an automatic review sheet.

Show:

- Thumbnail and duration
- Tracks captured
- Capture-health or recovery warnings
- **Play**, **Trim**, **Suggested Edit**, and **Export**
- Analysis progress and a **Review when ready** badge

Suggested Edit can start automatically in the background because it is local, cancellable, and does not mutate the document. It should not take over the editor when complete. Preserve **Skip Draft**, **Apply Selected**, and **Apply All**, but state the exact number of changes each action will apply.

### 5. Editing

The common edit loop is Play, Trim/Cut, add a caption or emphasis when needed, check privacy, and Export. It should remain visually dominant.

**Include**

- Visible timeline lane names or a compact legend.
- Strong selected-item styling and a way to focus/expand a lane.
- Accessible timeline items with type, time range, selected state, and keyboard alternatives for moving/resizing.
- A single canonical **Add** entry point for zoom, caption, annotation, redaction, drawing, speed, and cursor treatment.
- Output duration shown consistently, not only when edit decisions exist.

**Modify**

- Consolidate duplicate Add actions currently spread across the timeline, inspector, and menus.
- Keep keyboard commands for expert use, but move specialist commands such as merge/split/lock/suppress into their relevant Actions context rather than the global primary surface.
- Show project-level styling only when no timed item is selected; show selected-item controls first otherwise.
- Collapse low-frequency or precision settings such as animation duration, shadow tuning, cursor blur, and detailed audio cleanup.

**Remove from the persistent inspector**

- Export buttons and encoding configuration.
- Empty sections that only explain why they cannot currently do anything.
- Multiple simultaneous Add pathways for the same item type.

### 6. Analyze and review

Transcript, Actions, Suggested Edit, pause removal, and Privacy Firewall are related but distinct. A single Analyze entry point can make them discoverable without putting five expert concepts in the toolbar.

**Transcript**

- Keep transcription, search, seek, correction, non-destructive removal, and caption generation.
- Collapse pause-removal analysis under **Remove Pauses**.
- Explain unavailable microphone/system sources instead of showing unexplained disabled choices.
- Show explicit empty search results and selected counts.

**Actions**

- Use the user-facing name **Actions**.
- Treat building/rebuilding as **Analyze Recording**.
- Move Merge, Split, Suppress, Lock, and conversion actions into selection-aware controls or a context menu.
- Hide raw bundle identifiers by default.

**Suggested Edit**

- Rename **Keep Current Edit** to **Skip Draft**.
- Show selected/actionable counts and Select All/Clear All.
- Make **Apply All** say how many changes it will apply.
- Keep evidence, confidence, reversibility, and one-step undo.

**Privacy**

- Keep the best-effort warning and mandatory review before rendered video export.
- Add batch Accept/Reject and a focused preview/seek action.
- Avoid three repeated full-width actions on every finding when a compact row and context actions suffice.
- Keep Sanitized Share Copy clearly separate from the editable source.

### 7. Export and completion

**Include**

- A simple default Video recipe and remembered last destination.
- A visible estimate and clear cancel behavior.
- Completion state with output path and Open, Reveal, Share, Copy Path, and Export Again.
- Failure state with Retry, Choose Another Location, Copy Diagnostics, and Reveal Partial Output when safe.
- Optional short **Render Preview** for the selected range.

**Modify**

- Use one primary Export button; remove duplicated export entry points from the inspector.
- Put codec, frame rate, ProRes, Fast Export, GIF, audio, and snapshot under Advanced or Format.
- Integrate the planned v4.3 Release Factory as saved/versioned publish recipes, not another permanent toolbar cluster.

### 8. Settings, commands, and support

If Settings remains a one-purpose sheet, name it **Library Folder…**. If it becomes a true Settings window, keep it small:

- General: show main window at launch
- Recording Defaults: audio, camera, cursor, keyboard
- Privacy: semantic interaction capture and explanations
- Storage: library folder and Reveal in Finder
- Support: permission status, Copy Diagnostics, keyboard shortcuts

Changing the library folder must save/close the active editor first, or the control must be disabled while a project is open. Explain that existing projects remain in their current folder and only the active library location changes.

Move **Copy Diagnostics** to Help/Support and make it available after capture/export failures. Keep the privacy-safe content contract. Add a Keyboard Shortcuts reference for recording, story markers, timeline editing, and export.

## Add, modify, remove, and defer summary

| Decision | Features |
|---|---|
| Add now | Contextual preflight, no-source recovery, capture summary, HUD health, export result actions, empty-library welcome, timeline labels/accessibility |
| Modify now | Recorder disclosure, editor toolbar, selection-driven inspector, First Cut naming/launch behavior, permission sheet, library-folder flow, task-specific errors |
| Remove from primary UI | Permanent batch checkboxes, persistent library path, duplicated Add/Export actions, irrelevant inspector sections, advanced commands when no project is open |
| Preserve in advanced UI | Templates, telemetry controls, Action correction, batch export, codec/frame-rate choices, GIF/audio/snapshot, detailed styling/audio controls, command shortcuts |
| Defer | Tags/collections beyond favorites, custom shortcut editor, true Pause, Render Preview, Patch Takes, multi-source editing |
| Do not add | Login/accounts, hosted share links, cloud-required processing, collaboration, stock media, general NLE/DAW scope |

## Delivery sequence

### Phase A: simplify and protect the core path

1. Contextual permission preflight and actionable source empty states.
2. Compact Capture Options with explicit remembered defaults.
3. Guard library-folder switching.
4. Simplify the editor toolbar and make the inspector selection-driven.
5. Remove duplicated Add and Export controls from persistent surfaces.

Success condition: a first-time user can understand and begin a basic recording without learning any analysis terminology or granting unused permissions.

### Phase B: complete the recording-to-file journey

1. Recording summary and background Suggested Edit.
2. HUD health and finalization/menu-bar states.
3. Timeline labels, selected state, and accessibility/keyboard parity.
4. Task-specific failures and export completion actions.
5. Simplified export with Advanced disclosure.

Success condition: a user can record, trim, privacy-check, export, and reveal the output without searching menus or interpreting technical status.

### Phase C: improve repeat and advanced workflows

1. Library search, sort, duration, and status.
2. Explicit batch mode.
3. Analyze hub and focused Transcript/Actions/Suggested Edit experiences.
4. Settings/Support and shortcut reference.
5. Connect v4.3 publish recipes and documentation outputs to the simplified Export flow.

Success condition: repeat and advanced users gain speed without restoring clutter to the default experience.

## Acceptance measures

Product decisions should be validated against task outcomes rather than visual preference alone.

- A new user can reach a valid countdown from launch with one source choice, one preset choice at most, and one Record action.
- No optional permission is requested unless an enabled capture feature requires it.
- No capture-permission wall blocks Import, Open Project, library browsing, or editing.
- The empty library presents Record and Import without requiring toolbar discovery.
- A user can identify source, microphone, system audio, webcam, and permission readiness before recording.
- Capture-health warnings are visible during recording or immediately after Stop, not only in diagnostics.
- Suggested Edit never takes over the editor without an explicit user action.
- The editor has one primary Add path and one primary Export path.
- Every timeline item can be identified and selected with VoiceOver and manipulated through a keyboard-accessible alternative.
- A successful export always ends with a visible output location and at least Open and Reveal actions.
- Advanced capture, editing, analysis, and export capabilities remain reachable within one deliberate disclosure or menu.

Useful usability metrics for testing include time to first recording, permission-related failed starts, time from Stop to first playback, time from opening a project to Export, export-location recovery, and the number of users who accidentally enter batch or advanced analysis workflows.

## Risks and guardrails

- Do not confuse hiding an advanced control with removing the capability. Preserve expert access and shortcuts.
- Do not make presets opaque. Always show the actual enabled tracks and metadata after a preset is selected.
- Do not delay project safety on analysis. Finalize and surface the usable display recording first.
- Do not represent local detectors as complete or the source bundle as sanitized.
- Avoid adding new project-schema fields for library status until derived metadata has been tried first. Search, duration, health, track badges, read-only status, and export history may be derived or stored outside the immutable capture contract.
- Treat library-folder switching as data-safety work, not cosmetic settings work.
- Keep v4.3 Release Factory within the Publish/Export hierarchy so the planned feature does not recreate toolbar and inspector overload.

## Evidence from the current implementation

This proposal is grounded in the current v4.2 implementation and plans:

- Product scope and local-first contract: [`../README.md`](../README.md), [`V4_PLAN.md`](V4_PLAN.md), and [`../STATUS.md`](../STATUS.md).
- App shell, sheets, generic alerts, and empty detail: [`../Sources/OpenRecordApp/ContentView.swift`](../Sources/OpenRecordApp/ContentView.swift).
- Library rows, batch controls, toolbar, and library-folder sheet: [`../Sources/OpenRecordApp/LibraryView.swift`](../Sources/OpenRecordApp/LibraryView.swift).
- Recorder source grid and flat capture options: [`../Sources/OpenRecordApp/RecorderView.swift`](../Sources/OpenRecordApp/RecorderView.swift).
- Permission status and broad Request Remaining action: [`../Sources/OpenRecordApp/PermissionsView.swift`](../Sources/OpenRecordApp/PermissionsView.swift).
- Editor toolbar and status/progress surfaces: [`../Sources/OpenRecordApp/EditorView.swift`](../Sources/OpenRecordApp/EditorView.swift).
- Dense inspector and duplicated export controls: [`../Sources/OpenRecordApp/InspectorPanel.swift`](../Sources/OpenRecordApp/InspectorPanel.swift).
- Timeline controls and lanes: [`../Sources/OpenRecordApp/TimelineView.swift`](../Sources/OpenRecordApp/TimelineView.swift).
- Transcript, Actions, and review workflows: [`../Sources/OpenRecordApp/TranscriptPanel.swift`](../Sources/OpenRecordApp/TranscriptPanel.swift), [`../Sources/OpenRecordApp/ActionMapPanel.swift`](../Sources/OpenRecordApp/ActionMapPanel.swift), and [`../Sources/OpenRecordApp/V42ReviewPanels.swift`](../Sources/OpenRecordApp/V42ReviewPanels.swift).
- Capture lifecycle, persistence of recording defaults, finalization, and project opening: [`../Sources/OpenRecordApp/AppModel.swift`](../Sources/OpenRecordApp/AppModel.swift).
- Next planned product checkpoint: v4.3 Release Factory and Open Tutorial Package in [`V4_PLAN.md`](V4_PLAN.md) and [`../STATUS.md`](../STATUS.md).

