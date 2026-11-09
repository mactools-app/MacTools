# Actions and automation

MacTools uses one action system for Unified Search, global shortcuts, workflows, Run Links, and Action Grid. Plugins declare actions; the host validates and executes them consistently across these surfaces.

## Choose a surface

| Task | Surface |
| --- | --- |
| Find and run an action | Unified Search |
| Assign a global key binding | Settings → Actions & Shortcuts |
| Run several actions in order | Settings → Automation |
| Run a workflow when an event occurs | Automation rules |
| Open an action from another app or script | [Run Links](url-scheme.md#run-links) |
| Arrange actions in a compact launcher | Action Grid; each folder holds up to nine entries |
| Discover eligible actions from a local agent | [Command-line interface](cli/agent-usage.md) |

Unavailable actions remain in saved shortcuts, workflows, presets, and Action Grid. Re-enabling or reinstalling a compatible provider can restore them without recreating the configuration.

## Workflows

A workflow is an ordered list of action references. It can be created, renamed, duplicated, reordered, enabled, disabled, run, stopped, or deleted.

- **Preview Before Running** is enabled by default for manual runs. It shows steps, availability, waits, and confirmation requirements. Workflows do not provide automatic rollback.
- Changing a step's action opens the shared picker and replaces its parameters with a valid reference. Step names, waits, and failure policy are under **Advanced Options**.
- **Set Built-In Display Brightness** saves a whole percentage from 0% to 100%. Add it to a scheduled workflow for a MacBook. The step reports failure if the built-in display is ineligible or its native brightness cannot be verified.
- Text and numeric edits are saved after a short debounce. Structural edits, such as moving or deleting a step, are saved immediately.
- Manual runs ignore rule-specific conditions. Deleting a workflow cancels active runs and removes its attached rules.

Enabled workflows publish stable `automation/workflow.<uuid>` actions. After validation and confirmation, Unified Search and Action Grid hand the run to Automation and close. The menu-bar running indicator, run history, and Stop control track progress. Ordinary actions keep their invoking surface open until they finish; nested workflow steps always await their child action.

## Automatic rules

Each rule has one trigger, optional conditions, and a workflow:

| Part | Supported choices |
| --- | --- |
| When | Schedule, calendar, application, power, display, or network event |
| If | Frontmost app, power or battery state, connected display, time range, or network state |
| Run | An enabled reusable workflow |

Trigger delivery is debounced and serialized per rule. Providers run only while enabled rules use their trigger family. The runtime bounds total automatic runs and prevents overlapping runs of the same workflow.

An action must explicitly declare the `.automatic` capability to run unattended; `.background` alone is insufficient. Calendar offsets, battery-threshold crossings, and network transitions use exact event identities so adjacent rules do not cross-fire. Positive calendar offsets retain ended events across provider refreshes.

Skipped rules record a reason. Recursion and execution depth are bounded, and unfinished runs become interrupted history entries after restart. Branches, loops, variables, workflow folders, and application-specific Action Grid profiles are not supported.

## Developer ownership

| Component | Responsibility |
| --- | --- |
| `ActionRegistry` | Definitions, catalog indexes, migration, live availability, and provider revisions |
| `ActionExecutor` | Parameter and mode validation, confirmation, revalidation, deadlines, concurrency, and supported cancellation |
| `ShortcutAssignmentService` | Ordinary action bindings, conflicts, migration, persistence, and Carbon registration |
| Automation | Workflow and rule storage, serial step execution, progress, and bounded history |
| `AppURLRouter` | Strict URL parsing and one bounded, ordered navigation/action queue |
| Action Grid | Folder structure and positioned `ActionReference` values |

All execution enters `ActionExecutor`. After confirmation it revalidates the approved request, provider, and availability. Overlapping invocations are rejected by default; providers may explicitly choose serialization or concurrency. Deadlines apply to every action, while provider cancellation requires the corresponding capability.

Plugins should publish canonical actions through `PluginActionProviding`. Plugin settings retain only specialized shortcuts that are not ordinary action assignments. For composition across providers, use `PluginActionExecutionHostContext`: its lookup and execution closures enter the same registry and executor without exposing provider instances. The host refreshes this context after catalog revisions and clears it when isolating a plugin.

Run Link controls copy a direct URL for eligible parameterless actions. Parameterized actions may use a host-owned preset, whose URL contains only an opaque identifier; see the [URL contract](url-scheme.md).

## Backup and restoration

Portable imports restore providers that define action identities before admitting their dependent references. Workflows restore before shortcuts, Run Links, Trackpad mappings, and Action Grid entries. Failed provider or workflow persistence produces a warning and removes the affected imported dependency chain.

An explicitly empty action-shortcut section in a current backup clears that section. Older backups migrate only the legacy assignments they contain and preserve unrelated destination bindings.

## Verification

Reuse the smallest relevant existing test class: `ActionRegistryTests`, `ActionExecutorTests`, `AppURLRouterTests`, or the affected workflow, rule, or shortcut suite. Add coverage for missing core behavior or a concrete regression, especially permissions, confirmation, persistence, cancellation, and unavailable providers.

```bash
xcodebuild -project MacTools.xcodeproj -scheme MacTools -configuration Debug \
  -derivedDataPath build/DerivedData test -quiet \
  -only-testing:MacToolsTests/ActionExecutorTests
```

Use `make ci` before pushing cross-module or PluginKit changes. For native interactions, select the affected scenarios from the [end-to-end guide](testing/actions-automation-e2e.md); a copy or layout change does not require replaying the entire matrix. See [Contributing](../CONTRIBUTING.md#validation) for the shared validation policy.
