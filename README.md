# org-extras.nvim

Native [org.nvim](https://github.com/xheisenbugx/org.nvim) extensions for
agenda lines you can lay out yourself, a composite "what to do next" score,
`:COMPLETION:` percent cycling, and a scheduling grid — plus two small
shared libraries (relative date labels, the effort ladder) they build on.

Everything with a lifecycle is a real `org.Extension` (contract in `:h
org.extensions`): each ships at `lua/org/extensions/<name>.lua` with
`defaults`, `actions` and `setup`/`teardown`, is enabled through org.nvim's
own `extensions` table, and is torn down cleanly on re-setup. They only
touch each other where documented (the urgency score reads the completion
percent; the `list_view` tokens read both).

## Extensions

### `list_view` — agenda lines from format strings

The `list_view` agenda type renders every item as one line: a `left` section
that flows from the start, and a `right` block padded flush with the right
edge of the view. Which cells appear is up to the block:

```lua
-- in an agenda custom command's block
{
  type = "list_view",
  match = "TODO|NEXT|STARTED",
  files = { "~/org/**/*.org" },
  sorting = { "user-defined-up" },
  cmp_user_defined = require("org.extensions.urgency").cmp,
  sections = { left = "%t %i", right = "%c %s %d" },
}
```

Format strings are literal text with `%token` specs (the
`org-agenda-prefix-format` idiom): `%%` is a literal `%`, and `%22c` pads or
right-aligns the value to a width. Omitted sides fall back to the defaults —
`left` is the todo keyword, priority and title; `right` is
`"%c %s %d %e %p"`.

| Token | Meaning | Default width |
|-------|---------|---------------|
| `%t`  | todo keyword | — |
| `%i`  | item title (truncated to fit) | — |
| `%c`  | category (a file/headline property, `COURSE` by default) | 22 |
| `%s`  | scheduled, relative label ("today", "next Thursday") | 14 |
| `%d`  | deadline, relative label | 14 |
| `%e`  | effort name ("short", "medium", "long") | 6 |
| `%p`  | completion percent ("50%", empty when unset) | 4 |

`sections` may also be `function(item, ctx)` returning the same table, for
layouts that depend on the item.

New cells don't need a patch: register a token once and every format can use
it.

```lua
local lv = require("org.extensions.list_view")
lv.user_specs.state = function(item)
  return item.headline:get_property("STATE") or ""
end
-- or per block:
--   specs = { state = { value = fn, width = 10, face = "Comment" } }
```

Rendering is all this type does — sorting stays whatever the block's
`sorting` says, so a `list_view` block is never implicitly urgency-sorted,
and any other block type can sort by urgency without using the layout.

### `urgency` — sort by what to do next

A composite score instead of a raw date: how soon a task is due, how big it
is (Effort, log scale so one day of distance always beats the whole effort
ladder), how far along it already is (the completion percent damps gently),
plus a floor for tasks tagged `:today:`. Overdue > today > tomorrow > later,
always.

```lua
local urgency = require("org.extensions.urgency")
-- as a block's cmp_user_defined:
cmp_user_defined = urgency.cmp
-- or as a value:
urgency.urgency(item)
```

The expression, its rationale and the ranking rules it encodes live at the
top of [`lua/org/extensions/urgency.lua`](lua/org/extensions/urgency.lua).

**Everything about the formula is configurable.** Each constant is an
option, and `score` replaces the expression outright:

| Option | Default | Meaning |
|--------|---------|---------|
| `today_floor` | 70 | floor for undated `:today:`-tagged tasks |
| `severity_now` | 80 | severity of a date at zero days out (peak, and the base overdue adds to) |
| `overdue_rate` | 40 | extra severity per day past due |
| `decay` | 0.75 | how fast dates ahead fall off (`severity_now / (1+days)^decay`) |
| `scheduled_weight` | 0.8 | a scheduled day's share of the same-day severity |
| `deadline_bonus` | 6 | flat add: due-by outranks start-hint |
| `effort_scale` | 1 | multiplier on `ln(1 + hours)`; 0 drops Effort from the ranking |
| `completion_damping` | 0.5 | largest fraction completion may subtract; 0 disables |
| `completion_gamma` | 1.5 | penalty ramp; above 1 the middle barely dents |
| `score` | — | `function(item) -> number`, used instead of all of the above |

Options go through org.nvim's extensions table (the loader merges them over
`defaults` before org.setup sets keymaps):

```lua
extensions = {
  urgency = {
    today_floor = 60,
    effort_scale = 0,      -- rank by dates only
    -- or take over completely:
    -- score = function(item) return <your number> end,
  },
},
```

For one view with a different idea of "urgent", wrap any scoring function
in `cmp_with` and bind it per block:

```lua
local cmp_with = require("org.extensions.urgency").cmp_with
-- ...
cmp_user_defined = cmp_with(function(item)
  return <your number>
end)
```

### `completion` — `:COMPLETION:` percent cycling

Read an entry's `COMPLETION` property as a percent and cycle it through a
ladder of segments (10 → 25 → 50 → 75 → 90 → none — never 100: a fully
completed task is DONE). The extension registers `set_completion` for
`mappings.org` and `:Org` through its `actions` field; the agenda side is
wired in `setup()` (the contract has no field for the agenda action
registry) and unwired by `teardown()`. Enable it and bind both sides the
org.nvim way:

```lua
extensions = {
  completion = { segments = { 10, 25, 50, 75, 90 } }, -- defaults shown
},

-- in org.nvim's opts:
mappings = {
  org = { set_completion = "<prefix>C" },  -- in an org buffer
  agenda = { set_completion = "C" },       -- on an agenda line (refreshes the view)
},
```

### `plan` — a scheduling grid

One row per task, a rectangle on the day it is scheduled — nothing for a
deadline, and undated tasks still get a row so `S` can point them at a day.
Zoom day/week/month, pan, reschedule and set deadlines from the grid.

```lua
extensions = {
  plan = {
    source = { "~/org/**/*.org" },
    zoom = "week",
  },
},
```

Then `:Org plan [agenda|buffer|subtree|<file>] [day|week|month] [filter]`.
See `:h org.extensions` in org.nvim for the extension contract; `plan`'s own
options are documented at the top of
[`lua/org/extensions/plan.lua`](lua/org/extensions/plan.lua).

## Libraries

Two plain modules with no lifecycle, shared by the extensions above — require
them directly, they need no enabling:

- `org_extras.dates` — the relative-label ladder ("today", "next Thursday")
  behind the `%s`/`%d` tokens and agenda date echoes.
- `org_extras.effort` — the effort ladder (`0:30` / `1:00` / `2:00`) and
  `duration_minutes`, the Effort/Length parsing the score and tokens read.

## Installation

org-extras loads as a dependency of org.nvim; all four extensions are then
enabled through org.nvim's own `extensions` table, so org.setup resolves
them (and their default keymaps) itself — there is no separate setup call.

```lua
{
  "xheisenbugx/org.nvim",
  branch = "dev",
  dependencies = { "pianocomposer321/org-extras.nvim" },
  opts = {
    extensions = {
      list_view = true,                 -- default opts; `false` disables
      completion = true,
      urgency = true,                   -- or { today_floor = 90, score = fn }
      plan = { source = { "~/org/**/*.org" }, zoom = "week" },
      -- plus any built-in extensions you want (timeline, quickadd, ...)
    },
  },
}
```

Requires Neovim >= 0.10 and org.nvim (the `dev` branch).

## License

MIT
