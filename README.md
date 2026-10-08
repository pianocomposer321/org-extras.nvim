# org-extras.nvim

A bundle of independent extras for [org.nvim](https://github.com/xheisenbugx/org.nvim):
agenda lines you can lay out yourself, a composite "what to do next" score,
`:COMPLETION:` percent cycling, and a scheduling grid.

Each piece is separate — use one, use them all. They only touch each other
where documented (the urgency score reads the completion percent).

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
  cmp_user_defined = require("org_extras.urgency").cmp,
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
local lv = require("org_extras.list_view")
lv.user_tags.state = function(item)
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
local urgency = require("org_extras.urgency")
-- as a block's cmp_user_defined:
cmp_user_defined = urgency.cmp
-- or as a value:
urgency.urgency(item)
```

The expression, its rationale and the ranking rules it encodes live at the
top of [`lua/org_extras/urgency.lua`](lua/org_extras/urgency.lua). Tweak the
numbers to taste — sorting reads exactly that function.

Options:

```lua
require("org_extras").setup({
  urgency = { today_floor = 70 }, -- score floor for undated :today: tasks
})
```

### `completion` — `:COMPLETION:` percent cycling

Read an entry's `COMPLETION` property as a percent and cycle it through a
ladder of segments (10 → 25 → 50 → 75 → 90 → none — never 100: a fully
completed task is DONE). `setup()` installs both actions; bind them the
org.nvim way:

```lua
require("org_extras").setup({
  completion = { segments = { 10, 25, 50, 75, 90 } },
})

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

`plan` is a native org.nvim extension (it ships at
`lua/org/extensions/plan.lua`), so you enable it through org.nvim's own
extensions table:

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

## Installation

org-extras loads as a dependency of org.nvim, and `org_extras.setup()` runs
in org.nvim's config *before* `org.setup()` — that order matters: org.setup
resolves the `plan` extension by requiring it, and `setup()` registers the
`list_view` type and the completion actions with org's renderer.

```lua
{
  "xheisenbugx/org.nvim",
  branch = "dev",
  dependencies = { "pianocomposer321/org-extras.nvim" },
  opts = { -- your org.nvim opts, including extensions = { plan = { ... } }
  },
  config = function(_, opts)
    require("org_extras").setup({
      -- all extensions are on by default; disable with `false`:
      -- list_view = false, urgency = false, completion = false,
    })
    require("org").setup(opts)
  end,
}
```

Requires Neovim >= 0.10 and org.nvim (the `dev` branch).

## License

MIT
