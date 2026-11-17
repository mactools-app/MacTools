# AI Usage

AI Usage (`ai-usage`) is a PluginKit v7 plugin. It shows one full-width panel widget, the AI page adapted from [Vorssaint](https://github.com/vorssaint/vorssaint-utils) (GPL-3.0-or-later): plan limits, API value, trend, models, projects, a thirteen-week activity map, running turns and Codex banked resets for Claude Code, Codex, OpenCode and GitHub Copilot. Only agents that left usage on this Mac get cards.

## Layout

The widget follows Vorssaint's information design and card set. The MacTools panel is 304 pt wide, below the 390 pt at which Vorssaint pairs cards, so every card takes its own row, as Vorssaint does on a narrow island. While a card follows the period, the page's top row holds the Today / 7 days / 30 days menu, which Vorssaint puts in the island's top row. The page has no title of its own, and the Claude card does not show the account email. Cards use the panel's card surface and follow its light or dark appearance. Card order and visibility, agents, limit display (left or used) and price-list updates are in the plugin settings. Placing the widget on a panel tab of its own gives it the full panel height.

Not ported: Vorssaint's closed-island strip and working indicator, turn-finished, limit and budget alerts, and added Codex homes or Claude account folders.

## Data sources

- Claude Code: `~/.claude/projects` and `~/.config/claude/projects` session logs, and the plan in `~/.claude.json`.
- Claude plan limits: the percentages the Claude app saves in `~/Library/Application Support/Claude/plan-usage-history.json`, and, while the page is on screen, Claude Code's own account check (`claude --print` with no prompt, tools, MCP servers or session file) at most once a minute.
- Codex: `~/.codex/sessions` logs, which carry its plan limits. The Resets card asks `codex app-server` for banked resets and spends one only after a confirmation.
- OpenCode: its SQLite database, read only. GitHub Copilot: its session event logs.
- Prices: the bundled `agent-prices.json`. With price updates on, the same public list is fetched at most once a day from `raw.githubusercontent.com`; the request carries no usage.

Logs are read in place. Only counters are kept: in memory, and in an archive in the plugin's cache folder so later launches read only new lines. Prompts, replies and files are never stored, and usage never leaves the Mac. Disabling or removing the plugin removes the archive.

## Performance

The first launch reads thirteen weeks of history once on a utility queue (about 4 s for 3.5 GB of logs); quitting keeps the saved progress, so later launches read only new lines. Lines are parsed in place from a buffer mapped from the kernel, and string values over 16 KB (file contents, tool output) are emptied before a long line is decoded, so the read adds no lasting memory beyond the counters. While the page is off screen the reader is paused: no timer, poller, file watcher or account check runs. Showing the page reads what the agents wrote meanwhile, then follows the logs with file events and a two-second check of logs written in the last half hour until the page closes.

## Verification

```sh
make generate
make build-plugin PLUGIN=AIUsage
```

Open the panel with the widget placed and compare limits, spend and tokens with the agents' own `/usage` and `/status` readings.
