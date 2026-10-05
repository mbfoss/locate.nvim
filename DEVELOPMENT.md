# Development

Technical notes for working on locate.nvim.

## Requirements

- Neovim ≥ 0.11 (enforced at load time in [`plugin/locate.lua`](plugin/locate.lua))
- [busted](https://lunarmodules.github.io/busted/) for the test suite,
  installed for Lua 5.1 (see below)
- [ripgrep](https://github.com/BurntSushi/ripgrep) for the `files` and
  `live_grep` sources at runtime

## Testing

[busted](https://lunarmodules.github.io/busted/) specs in [`tests/`](tests/),
discovered through [`.busted`](.busted) and run through
[`tests/nvim-lua`](tests/nvim-lua), so each spec executes inside a real Neovim
and can use the `vim` API.

```bash
# Run the whole suite
make test

# Pass flags through to busted
make test BUSTED_ARGS="--filter=registry -o gtest"
make test BUSTED_ARGS=tests/registry_spec.lua
```

- busted must already be installed for Lua 5.1, the version Neovim embeds,
  with `luarocks --lua-version=5.1 --local install busted`; `make test` fails
  if it is missing rather than installing anything.
- The runner is defined in the [`Makefile`](Makefile).
- [`tests/init.lua`](tests/init.lua) is the busted helper that puts the plugin
  on the runtimepath.

## Architecture

```
plugin/locate.lua        Neovim version guard, `:Locate`, highlight groups (loaded on startup)
lua/locate/init.lua      public API: setup, pick, register, resume
lua/locate/cmdline.lua   `:Locate` argument parsing and completion
lua/locate/registry.lua  name -> spec table for the built-in sources
lua/locate/select.lua    vim.ui.select implementation
lua/locate/base/         the picker engine
lua/locate/pickers/      one file per built-in source
lua/locate/icons.lua     filetype icons (optional, via keystone.nvim)
lua/locate/util/         shared low-level toolkit (see below)
tests/                   busted specs
```

### The engine (`base`)

**`picker.lua`**: the window, list rendering, preview, keymaps and the async
fetch loop. Everything user-visible happens here.

**`pickertools.lua`**: matching and highlighting helpers shared by sources:

- `match_label`: fuzzy subsequence + highlight chunks;
- `match_globs`: rg-style glob matching;
- `file_preview` / `buffer_preview` loaders; the latter previews `data.bufnr`
  when that buffer is loaded and falls back to the file on disk;
- `make_history_provider`, persisting per-source query history under
  `stdpath("state")/locate/pickhist.<name>.json`.

**`queryflags.lua`**: reads a flags line (`switch`, `key=value`,
`key=one,two`) and drives flag completion.

- The two prompt sections never share a line: the flags are a mode of their own
  (`<C-f>`), and the parser is handed the flags alone, with the query one line
  over. So a name needs no marking prefix, and a word naming no flag is a
  mistake.
- Everything outside the prompt keeps the two apart too: `Picker.initial_flags`
  beside `initial_query`, `on_close(query, flag_text, index)`,
  `:Locate --flags … --` beside the query that runs on after it, and the query
  history, which `_encode_history` writes as JSON `{q=..,f=..}` once a flagged
  entry needs it and as the plain query otherwise.
- `\` escaping is local to a value and follows `:h <f-args>` plus the list
  separator: only whitespace, `,` and `\` are escapable.
- A `multi` flag takes its values comma-separated in one token
  (`type=lua,rust`) and comes back as a `string[]`.
- Every flag is written at most once; a repetition is an error, with the last
  one winning.
- `parse` never fails on what was typed: anything doubtful comes back as a
  `ParseResult.errors` entry beside the flags it could read, which the picker
  underlines in the prompt. A malformed *schema* does fail at once (`strict`
  without `values` asserts).
- A line carrying an error has no single reading, so the picker refuses to
  search it at all: the fetch is cancelled and the list cleared until the
  errors are gone.
- Every problem is reported, including the half-written states a correct flag
  passes through. Telling those apart takes the cursor, so the picker is where
  an error's *message* is held back until the cursor leaves what it points at;
  the search stops either way.

**`layouts.lua`**: geometry for the list/preview floats. The prompt's height
is an input: the picker measures what the query wraps to with
`nvim_win_text_height` and asks for that many rows, which `_split_frame` grants
out of the list's share, never past an even split with it.

### Sources

A source is an `locate.PickerSpec`: a `prompt`, a `finder` turning (query,
flags) into items, an `on_confirm`, and optional `flags`, `previewer`, `setup`
and `quickfix_formatter`.

- Nothing about a source is special-cased by the engine: the built-ins in
  [`lua/locate/pickers/`](lua/locate/pickers/) use exactly the interface
  anything registered with `require("locate").register` uses.
- [`registry.lua`](lua/locate/registry.lua) maps each built-in name to a
  *function* returning its spec, so a source's module is `require`d only the
  first time it is opened. Keep `setup()` cheap and defer heavy work to first
  use.
- Names are unique: `register` appends a counter (`tasks_2`) rather than
  overwriting, warns, and returns the name it used. Nothing already in the
  table can be replaced, built-in or not.
- A `finder` may return a cancel function; the engine calls it when the query
  changes or the picker closes, so long-running work (rg, LSP requests) must be
  cancellable.

### Ranking

The engine sorts each result set by `item.score`, best first, before rendering.
A source opts in by passing through the score `match_label` gave it:

```lua
local match = pickertools.match_label(label, query)
if match then
    table.insert(items, { label_chunks = match.chunks, score = match.score, data = ... })
end
```

Two properties make this work without per-source configuration:

- `match_label` reports **no score for an empty query**, so an unfiltered list
  reads in the order its source produced: `lsp_references` by file and
  position, `buffers` by number, `marks` grouped local-then-global. Ranking
  starts only once there is a query to rank by.
- The sort is **stable**. `table.sort` is not, and equal scores are the common
  case, so the engine sorts an index array and breaks ties on position;
  otherwise equal-scoring rows reshuffle on every keystroke.

A source leaving `score` unset is never reordered. Three do so deliberately,
each with the reason in the code:

- `spell_suggest`: `spellsuggest()` already ranks by likelihood;
- `quickfix` / `loclist`: the list's order belongs to whatever built it;
- `jumplist`: recency is the reason you opened it.

Other source behaviours:

- A source can decline to open twice over: its spec builder may return `nil`
  (no marks are set, no LSP client answers `workspace/symbol`), and an async
  `setup` may call back with `nil` data. The LSP location sources use the
  latter to jump straight to a lone result instead of showing a one-row picker.
- `on_confirm` is called on *every* close, with `nil` when the picker was
  dismissed. That is where a source undoes anything it did while previewing,
  as `colorschemes` does when it restores the original scheme.

### Shared toolkit (`util`)

[`lua/locate/util/`](lua/locate/util/) holds the low-level primitives the
picker builds on: `Spinner`, `floatwin`, `fsutil`, `spawn`, `strutil`, `timer`
and `ui`. These are plugin-agnostic on purpose, knowing nothing about pickers,
so prefer extending `util` over duplicating window, filesystem or process
plumbing inside a source.

### Icons

`lua/locate/icons.lua` holds no icon data: it resolves `keystone.icons` lazily
on first use and forwards to it; without keystone.nvim installed, `get_icon`
returns `nil` and rows render without an icon. This keeps locate free of hard
plugin dependencies without duplicating keystone's icon table.

## Help file

[`doc/locate.txt`](doc/locate.txt) is generated from [`README.md`](README.md)
with [panvimdoc](https://github.com/kdheepak/panvimdoc), pinned to a commit in
the script. `doc/tags` is refreshed with `:helptags`.

```bash
make doc          # rewrite doc/locate.txt and doc/tags
make doc_check    # exit 1 when the help file is out of date
```

Help tags come from a hidden comment at the end of a section heading, so a
heading can be renamed without breaking `:help` links:

```markdown
## Writing your own source <!-- tag: custom-sources -->
```

- The `locate-` prefix is added automatically, so that yields
  `*locate-custom-sources*`.
- The comment is stripped before panvimdoc runs and never renders on GitHub.
- A heading without one keeps panvimdoc's derived tag
  (`locate-<heading, lowercased, spaces to dashes>`).
- Tags are limited to `[A-Za-z0-9_-]`; anything else fails the build.

## Coding style

- Add Lua annotations (`---@param`, `---@return`, `---@class`, …) wherever
  possible.
- **Class-based modules** are named in PascalCase; **functional modules** in
  snake_case.
- Module-scope `local` variables are `_`-prefixed, except: a module name from
  `require()`, the conventional `M` module table, and class types (`MyType`).
- Function-local variables are **not** `_`-prefixed.
- Inside a class, private members are `_`-prefixed.
- Avoid `pcall()` when it isn't required.
