# assets

Orphan branch holding the demo recordings linked from the README on `main`.
It shares no history with `main` and carries nothing but these files.

| File | Scene |
| --- | --- |
| `files.gif` | `:Locate files` — fuzzy query, `dir=` narrowing it, confirm opening the file |
| `live_grep.gif` | `:Locate live_grep` — ripgrep query, `type=` and `filter=` narrowing it, confirm jumping to the match |

Regenerate them from `main` with `nvim-demo-tool` using the scenes in `demo/`
(`files.scene` and `live_grep.scene`), then commit the results here.
