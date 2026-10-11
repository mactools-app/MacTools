# Issue 472 website comparison

Captured from the local static website before and after the capability-search and
prerequisite-disclosure change. The baseline is commit
`d914bfbeccbd6806cd27c88a456a890cdcb6e9bd`; the implementation capture is commit
`bc3792f94133af57410fc2b99ab4ee7a5de8f312`. These captures show website navigation
and declared metadata; they do not execute MacTools actions or inspect a visitor's
installed applications.

| Task | Before | After |
| --- | --- | --- |
| Search `left half` or `左半屏` | No results | Window Layouts and its Left Half action |
| Search `pause clipboard history` | No results | Clipboard and its Pause Clipboard History action |
| Search `theme` | No results | Dark Mode |
| Read Homebrew Manager requirements | Executable omitted | Declared `brew` requirement |
| Read Apple Shortcuts requirements | Application omitted | Shortcuts and `com.apple.shortcuts` |

## Light appearance

![Left Half search before and after](search-before-after.png)

![Theme keyword search before and after](keywords-before-after.png)

![Homebrew requirements before and after](homebrew-before-after.png)

![Shortcuts requirements before and after](shortcuts-before-after.png)

## Dark appearance

![Grouped action search in dark appearance](search-dark.png)

![Declared requirements in dark appearance](prerequisites-dark.png)

## Interaction

The recording shows task searches, expanding and collapsing the 40 matching
Window Layouts actions, switching to Chinese, and clearing the query to restore
ordinary browsing.

![Search, disclosure, language switching, and clearing](search-interaction.gif)

## Validation after integrating current main

- Focused search/controller/rendered-page checks: 4 passed.
- Website tests: 12 passed.
- Generated manifest-data freshness check passed.
- Static build: 203 pages, no errors, warnings, or hints.
- Chromium and WebKit checks passed for English/Chinese task discovery, category
  filters, counts including collapsed actions, disclosure reset, clear/empty
  states, keyboard focus, action-to-plugin navigation, and prerequisite rows.
- `git diff --check` passed.
