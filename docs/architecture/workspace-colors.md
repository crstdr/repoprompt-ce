# Workspace Colors

A workspace can carry one color from a fixed palette, so windows are easy to tell apart at a glance. The color belongs to the workspace, not to a window: every window that shows the workspace shows the same color, and the color stays visible in the workspace lists while no window is open.

## Saved contract

- File: the workspace's `workspace.json` (owner: `WorkspaceModel`, `Sources/RepoPrompt/Features/Workspaces/WorkspaceModel.swift`).
- Key: top-level `color`. The value is one of the ids in the table below.
- None: the key is absent. The app never writes an empty string or `null`.
- Readers must treat an unknown id as None. The app itself keeps an unknown id on re-save, so a value written by a newer build survives.
- The app trims and lowercases the value when it reads the file.
- Builds from before this feature ignore the key and drop it the next time they save that workspace.
- The value is an id, not a hex color, so the palette can be retuned without migrating files.

## Palette

The order below is the menu order. Light values are for light appearances and dark values for dark appearances; the app renders these exact sRGB values (`WorkspaceColor`, `Sources/RepoPrompt/Features/Workspaces/WorkspaceColor.swift`).

| id | Display name | Light hex | Dark hex |
|---|---|---|---|
| `red` | Red | `#DC2626` | `#F87171` |
| `orange` | Orange | `#EA580C` | `#FB923C` |
| `yellow` | Yellow | `#CA8A04` | `#FACC15` |
| `lime` | Lime | `#65A30D` | `#A3E635` |
| `green` | Green | `#16A34A` | `#4ADE80` |
| `teal` | Teal | `#0D9488` | `#2DD4BF` |
| `aqua` | Aqua | `#0891B2` | `#22D3EE` |
| `blue` | Blue | `#2563EB` | `#60A5FA` |
| `indigo` | Indigo | `#4F46E5` | `#818CF8` |
| `violet` | Violet | `#7C3AED` | `#A78BFA` |
| `magenta` | Magenta | `#C026D3` | `#E879F9` |
| `pink` | Pink | `#DB2777` | `#F472B6` |
| `brown` | Brown | `#92633A` | `#C8A27C` |
| `grey` | Gray | `#6B7280` | `#9CA3AF` |

The id `grey` keeps its British spelling for compatibility with existing readers; the UI shows "Gray".

## Where it shows

- An 8 pt dot before the toolbar title, before workspace names in the workspace picker, and in Manage Workspaces rows.
- A 2 pt line along the top content edge, directly below the toolbar. It reserves its own 2 pt, so content starts below it and is never covered. It takes space only while a colour is set. In debug builds it sits below the debug build's own 2 pt rule.
- With None, nothing is drawn.

To set a color, right-click the toolbar title or a row in Manage Workspaces and choose from the `Workspace Color` section. The System workspace and consolidated recovery copies have no color menu.

## Not exposed over MCP

MCP tools do not report or change the color. Adding it to `manage_workspaces` or `bind_context` results would change the MCP contract and needs its own approval.
