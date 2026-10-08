---@mod org.extensions.list_view The `list_view` agenda type: a configurable line layout
---
--- A `list_view` block renders each item as one line built from two format
--- strings — a `left` section that flows from the line's start and a `right`
--- block padded flush with the right edge of the view. Sorting is *not* part
--- of this type: a block sorts by whatever its own `sorting` (and optional
--- `cmp_user_defined`) says, and a list view need not be urgency-sorted.
--- `setup()` registers the type with org.nvim:
--- `render.sources.list_view` picks the items (same match/files rules as the
--- built-in `todo` type) and `render.item_parts` routes the line layout here.
---
--- A block chooses what the line shows with `sections`:
---
---     sections = { left = "%t %i", right = "%c %s %d %e %p" }
---
--- `left` flows naturally after the line's start, `right` is padded as one
--- block flush with the right edge of the view. Both are literal text with
--- `%token` specs (like `org-agenda-prefix-format`; `%%` is a literal `%`,
--- `%<digits><token>` pads/right-aligns to that width — otherwise the
--- token's default width applies). `sections` may also be
--- `function(item, ctx)` returning the same table, for layouts that depend
--- on the item. Omitted sides fall back to the defaults below:
---
---     left  = todo keyword, priority, title        (built in, not a format)
---     right = "%c %s %d %e %p"
---
--- Standard library (default width in parentheses):
---
---   %t  todo keyword          %i  item title (truncated to fit)
---   %c  category / any headline or file property (see `specs` below) (22)
---   %s  scheduled, relative label ("today", "next Thursday") (14)
---   %d  deadline, relative label (14)
---   %e  effort name ("short", "medium", "long") (6)
---   %p  completion percent ("50%", "" when unset) (4)
---
--- Extensions: entries in `M.user_specs` (global) or the block's own
--- `specs` table win over the standard library:
---
---     specs = { x = function(item, ctx) return "..." end }
---     -- or a full entry: { value = fn, width = 8, face = "OrgTitle" }
---
--- `face` may be "todo" (keyword face), "item" (the headline's face), a
--- highlight-group string, or `function(item)` -> group.

local dates = require("org_extras.dates")
local effort = require("org_extras.effort")
local completion = require("org.extensions.completion")

local M = {}

-- org.nvim modules, required lazily: this module must load before
-- org.nvim itself is available (bundle ordering), only setup() and the
-- rendering path actually need them.
local render, utils ---@type table|nil, table|nil
local function R()
  render = render or require("org.agenda.render")
  return render
end
local function U()
  utils = utils or require("org.utils")
  return utils
end

local DEFAULT_RIGHT = "%c %s %d %e %p"
M.DEFAULT_RIGHT = DEFAULT_RIGHT

local function todo_value(item)
  return item.todo or ""
end

local function title_value(item)
  return R().display_title(item.display_title or item.title or "")
end

local function course_value(item)
  local hl = item.headline
  return hl and hl.file and hl.file:get_property("COURSE") or ""
end

--- The standard library: token -> { value, width?, face? }.
M.specs = {
  t = { value = todo_value, face = "todo" },
  i = { value = title_value, face = "item" },
  c = { value = course_value, width = 22, face = "OrgAgendaCategory" },
  s = {
    width = 14,
    value = function(item)
      return (dates.planning_labels(item))
    end,
  },
  d = {
    width = 14,
    value = function(item)
      local _, due = dates.planning_labels(item)
      return due
    end,
  },
  e = {
    width = 6,
    value = function(item)
      return effort.effort_name(effort.minutes_of(item))
    end,
  },
  p = {
    width = 4,
    value = function(item)
      local n = completion.completion_pct(item)
      return n > 0 and ("%d%%"):format(n) or ""
    end,
  },
}

--- User extensions, merged under a block's own `specs`:
--- `M.user_specs.week = function(item) return "wk" end`.
M.user_specs = {}

local function norm_spec(v)
  if type(v) == "function" then
    return { value = v }
  end
  return v
end

local function specs_for(block)
  local out = {}
  for k, v in pairs(M.specs) do
    out[k] = v
  end
  for k, v in pairs(M.user_specs) do
    out[k] = norm_spec(v)
  end
  for k, v in pairs(block.specs or {}) do
    out[k] = norm_spec(v)
  end
  return out
end

-- `%22c`-style padding: right-aligned, content wider than the width is
-- never clipped (the caller's padding math uses the real width).
local function cell(s, w)
  local sw = U().width(s)
  if sw >= w then
    return s
  end
  return string.rep(" ", w - sw) .. s
end

-- `s` clipped to `n` display cells with "..." when it does not fit. The
-- literal three dots keep the line width deterministic (a "…" glyph can
-- render at 1 or 2 cells, which would push the right-aligned block around).
local function truncate(s, n)
  if U().width(s) <= n then
    return s
  end
  if n <= 3 then
    return string.rep(".", n)
  end
  return vim.fn.strcharpart(s, 0, n - 3) .. "..."
end

--- Parse a format string into { { lit = "..." } | { tok = ..., width = ... } }.
---@param fmt string
---@return table[]
function M.parse(fmt)
  local out, lit = {}, {}
  local function flush()
    if #lit > 0 then
      out[#out + 1] = { lit = table.concat(lit) }
      lit = {}
    end
  end
  local i = 1
  while i <= #fmt do
    local w, tok, j = fmt:match("^%%(%d*)(%a+)()", i)
    if tok then
      flush()
      out[#out + 1] = { tok = tok, width = w ~= "" and w or nil }
      i = j
    elseif fmt:sub(i, i) == "%" and fmt:sub(i + 1, i + 1) == "%" then
      lit[#lit + 1] = "%"
      i = i + 2
    else
      lit[#lit + 1] = fmt:sub(i, i)
      i = i + 1
    end
  end
  flush()
  return out
end

local function face_of(spec, item)
  local face = spec.face
  if face == nil then
    return nil
  elseif face == "todo" then
    return R().todo_group(item)
  elseif face == "item" then
    return item.face
  elseif type(face) == "function" then
    return face(item)
  end
  return face
end

--- Expand a format string for one item into parts { { text, group, trunc? } }
--- plus whether any token produced a non-empty value (an all-empty right
--- block is not drawn at all, so undated plain lines stay short).
---@param fmt string
---@param item table
---@param ctx table
---@param specs table
---@return table[], boolean
function M.expand(fmt, item, ctx, specs)
  local parts, any = {}, false
  for _, seg in ipairs(M.parse(fmt)) do
    if seg.lit then
      parts[#parts + 1] = { seg.lit }
    else
      local sp = specs[seg.tok]
      if not sp then
        -- unknown tokens stay visible for debugging instead of vanishing
        parts[#parts + 1] = { "%" .. (seg.width or "") .. seg.tok }
      else
        local v = tostring(sp.value(item, ctx) or "")
        if v ~= "" then
          any = true
        end
        local w = tonumber(seg.width) or sp.width
        v = w and cell(v, w) or v
        parts[#parts + 1] = { v, face_of(sp, item), seg.tok == "i" or nil }
      end
    end
  end
  return parts, any
end

local function sections_of(block, item, ctx)
  local sec = block.sections
  if type(sec) == "function" then
    sec = sec(item, ctx)
  end
  return sec or {}
end

--- The parts of one `list_view` line: left section, then (when any right
--- token has a value) padding and the right block flush to the edge.
---@param item table
---@param ctx table must carry `block` (type `list_view`)
---@return table[]
function M.parts(item, ctx)
  local block = ctx.block
  local sec = sections_of(block, item, ctx)
  local specs = specs_for(block)
  local rparts, any = M.expand(sec.right or DEFAULT_RIGHT, item, ctx, specs)
  local right_w = 0
  for _, p in ipairs(rparts) do
    right_w = right_w + U().width(p[1])
  end

  local parts, width = {}, 0
  local function push(s, group, trunc)
    if s == "" then
      return
    end
    parts[#parts + 1] = { s, group, trunc = trunc }
    width = width + U().width(s)
  end

  if sec.left then
    local lparts = M.expand(sec.left, item, ctx, specs)
    for _, p in ipairs(lparts) do
      push(p[1], p[2], p[3])
    end
    -- clip the %i part when the line plus the right block would overflow
    local overflow = width + right_w + 1 - ((ctx.width or 80) - 1)
    if overflow > 0 then
      for _, p in ipairs(parts) do
        if p.trunc then
          local w = U().width(p[1])
          local keep = math.max(w - overflow, 1)
          p[1] = truncate(p[1], keep)
          width = width - (w - U().width(p[1]))
          break
        end
      end
    end
  else
    -- the default left: keyword, priority, title
    if item.todo then
      push(item.todo, R().todo_group(item))
      push(" ")
    end
    if item.priority then
      push("[#" .. item.priority .. "]", R().priority_group(item) or item.face)
      push(" ")
    end
    local room = (ctx.width - 1) - width - right_w - 1
    push(truncate(title_value(item), math.max(room, 1)), item.face)
  end

  if any then
    push(string.rep(" ", math.max((ctx.width - 1) - width - right_w, 1)))
    for _, p in ipairs(rparts) do
      push(p[1], p[2])
    end
  end
  return parts
end

--- Register the agenda type and the line builder with org.nvim. Called by
--- the extension loader during `org.setup` (before keymaps are set); the
--- teardown below undoes it on re-setup or when the extension is disabled.
local orig_item_parts ---@type function|nil

function M.setup(_opts)
  -- The same items the built-in "todo" type returns, claimed under our own
  -- block type so the line builder can key the rendering off
  -- ctx.block.type. Blocks keep their own match / files / skip / sorting /
  -- sections; the header comes from block.header.
  R().sources.list_view = function(block, ctx, lopts)
    local kws = block.keywords
    if type(kws) == "string" then
      kws = vim.split(kws, "[|%s]+", { trimempty = true })
    end
    if not kws and block.match and block.match ~= "" then
      kws = vim.split(block.match, "[|%s]+", { trimempty = true })
    end
    return { items = require("org.agenda.items").todo(ctx.files, kws, lopts), kind = "todo" }
  end
  -- Route every `list_view` block through the parts builder; anything else
  -- falls through to the stock renderer untouched. The saved original is
  -- also the re-entry guard: teardown restores it, so a re-setup wraps
  -- exactly once.
  if not orig_item_parts then
    orig_item_parts = R().item_parts
    R().item_parts = function(item, ctx)
      if not (ctx and ctx.block and ctx.block.type == "list_view") then
        return orig_item_parts(item, ctx)
      end
      return M.parts(item, ctx)
    end
  end
end

--- Restore the stock renderer: unwrap `item_parts` and drop the source.
function M.teardown()
  if orig_item_parts then
    R().item_parts = orig_item_parts
    orig_item_parts = nil
  end
  R().sources.list_view = nil
end

return M
