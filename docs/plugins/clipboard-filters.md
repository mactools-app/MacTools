# Clipboard History filters

All, History, and Snippets stay on the left. Compact Type and Contains menus appear on the right: open either menu and choose a filter in two clicks. Their labels show the selected values with a subtle highlight when active, while fixed compact widths keep the controls stable. Long values are truncated; their full names remain available in the menus, help text, and accessibility labels. Saved only and Remember Filters on Reopen are in the ellipsis menu, which highlights when Saved only is active. On narrower windows, the filter controls wrap together below the scope selector.

Menu choices use monochrome icons alongside their names, with native checkmarks for selection. Toolbar buttons keep their text labels and chevrons.

Choose one type and one content condition. These combine with the collection scope, Saved only, and search text. Files can also match more specific types such as PDF. Saved only includes saved clips and snippets in All, saved clips still in History, and all snippets in Snippets.

Clear clears the type, content condition, and Saved only. It appears to the left of the right-aligned menus only when a secondary filter is active, using the existing flexible gap instead of reserving an empty slot. The menus keep their positions and compact widths across filter changes. Clear keeps the current scope and search text, and Remember Filters alone does not reveal it. Choosing All Types or Any Content resets only that menu. Zero-result filter choices remain available, and Actions works with an empty list. Result counts are omitted; pagination and selection feedback remain available.

## Reopening

The default is to reset filters and search text when opening a closed window. Enable Remember Filters on Reopen in the ellipsis menu to retain the last selected filters across openings and app restarts. Search text still clears. Bringing an already-visible window forward keeps its current state.

Manage Snippets opens Snippets without inherited filters. This navigation does not replace remembered filters; subsequent filter changes do. Turning remembering off discards the remembered selection without changing the current view immediately.

The remember preference participates in preferences backups. The last selected filter axes remain local, like window positions. Search text and selected clipboard contents are never stored as filter preferences.

## Keyboard and Actions

| Default shortcut | Filter |
| --- | --- |
| Option–Command–1 | All Types |
| Option–Command–2 | Text |
| Option–Command–3 | Images |
| Option–Command–4 | Files |
| Option–Command–5 | PDF |
| Option–Command–6 | Media |
| Option–Command–7 | Colors |
| Shift–Option–Command–1 | Any Content |
| Shift–Option–Command–2 | Links |
| Shift–Option–Command–3 | Email |
| Shift–Option–Command–4 | Recognized Text |
| Option–Command–0 | Clear filters |

These shortcuts apply only while the Clipboard window is focused and can be changed under Clipboard Window Shortcuts in Advanced settings. Command-K Actions and the Shortcuts guide show effective bindings, including custom assignments; filter menus show only names and checkmarks. Existing custom assignments retain ownership when a new default conflicts; the new filter remains unassigned and can still be chosen with its menu or Actions.

This plugin update requires MacTools 2.2.4 for shortcut ownership arbitration, including preferences restores, and effective binding notifications for local shortcuts. The Clipboard window reuses these notifications for labels and key handling instead of resolving every shortcut during rendering. Older hosts keep their compatible installed plugin until the host is updated.

Control–1, Control–2, and Control–3 select All, History, and Snippets. Command–1 through Command–9 retain their quick-paste behavior. Command–K opens searchable Type, Contains, Scope, Saved only, clear, and remember actions, alongside available item actions.
