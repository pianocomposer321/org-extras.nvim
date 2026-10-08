---@mod org.extensions.plan Scheduling grid of tasks
---
--- One row per task of the source; a rectangle on the day it is scheduled.
--- Unlike the timeline there is no bar across the scheduled-to-deadline span
--- and nothing is drawn for a deadline: a task that is not scheduled yet
--- still gets a row (with no rectangle), so it can be scheduled in place
--- with `S` and the rectangle appears on the day chosen. `D` and `S` use
--- the usual org date prompt and save after editing.
---
--- ```lua
--- require("org").setup({ extensions = { plan = { zoom = "week" } } })
--- ```
---
--- `:Org plan [agenda|buffer|subtree|<file>] [day|week|month] [filter]`

local views = require("org.extensions.views_util")
local date = require("org.date")
local utils = require("org.utils")

local M = {}

local MOD = "org.extensions.plan"
local ns = vim.api.nvim_create_namespace("org_plan")
local augroup = vim.api.nvim_create_augroup("OrgPlan", { clear = true })

--- Zoom levels, finest first: days per cell and cell width.
M.ZOOMS = {
  { name = "day", days = 1, width = 3 },
  { name = "week", days = 1, width = 1 },
  { name = "month", days = 7, width = 1 },
}

M.defaults = {
  --- Tasks come from: "agenda", "buffer", "subtree", or files / globs.
  source = "agenda",
  --- Only tasks matching this org-ql query (sexp or plain syntax).
  ---@type string|nil
  query = nil,
  --- Only tasks with this tag (inherited tags count).
  ---@type string|nil
  tag = nil,
  --- Also show DONE tasks (dimmed).
  show_done = false,
  --- Starting zoom: "day" (3 columns a day), "week" (a column a day) or
  --- "month" (a column a week).
  zoom = "day",
  --- Days before today shown at the left edge when opening.
  days_before = 3,
  --- Width of the task names on the left.
  label_width = 34,
  --- Window: "float", "tab", "split", "vsplit" or "current".
  layout = "float",
  width = 0.94,
  height = 0.88,
  --- Save the file after S / D; nil follows `agenda.save_after_edit`.
  ---@type boolean|nil
  save = nil,
  --- Keys in the plan grid. Like the timeline's, minus `c` (no clocks).
  keys = {
    zoom_in = { "+", "=" },
    zoom_out = "-",
    pan_left = "[",
    pan_right = "]",
    today = ".",
    jump = "<CR>",
    schedule = "S",
    deadline = "D",
    refresh = "r",
    quit = { "<Esc>", "q" },
  },
}

M.actions = {
  plan_open = { MOD, "open", desc = "Scheduling grid of tasks by scheduled day" },
  plan_buffer = { MOD, "open_buffer", desc = "Scheduling grid of the tasks of the current buffer" },
}

M.commands = {
  plan = {
    MOD,
    "command",
    desc = "Plan: :Org plan [agenda|buffer|subtree|<file>] [day|week|month] [filter]",
    complete = function(arglead, cmdline)
      return require(MOD).complete(arglead, cmdline)
    end,
  },
}

M.mappings = { global = { plan_open = "<prefix>Vp" } }
M.groups = { { "V", "views" } }

---@type table|nil
M.state = nil

local function opts()
  return require("org.extensions").opts("plan") or M.defaults
end

function M.setup()
  views.highlights(augroup, {
    OrgPlanTitle = { link = "Title" },
    OrgPlanHint = { link = "Comment" },
    OrgPlanAxis = { link = "Comment" },
    OrgPlanMonth = { link = "Title" },
    OrgPlanSeparator = { link = "WinSeparator" },
    OrgPlanBar = { link = "Function" },
    OrgPlanDone = { link = "Comment" },
    OrgPlanRepeat = { link = "Identifier" },
    OrgPlanTodayLabel = { link = "Search" },
    OrgPlanTask = {},
  })
  views.highlights(augroup, M.column_highlights)
end

--- Backgrounds of the today and weekend columns: faint tints of the
--- window background, so the rectangles stay readable.
---@return table<string, table>
function M.column_highlights()
  local light = vim.o.background == "light"
  local bg = views.color("NormalFloat", "bg") or views.color("Normal", "bg") or (light and 0xffffff or 0x000000)
  local fg = views.color("Normal", "fg") or (light and 0x000000 or 0xffffff)
  local warn = views.color("DiagnosticWarn", "fg") or 0xd7af00
  return {
    OrgPlanWeekend = { bg = views.blend(bg, fg, 0.05), ctermbg = light and 255 or 234 },
    OrgPlanToday = { bg = views.blend(bg, warn, 0.2), ctermbg = light and 230 or 236 },
  }
end

function M.teardown()
  M.close()
  vim.api.nvim_clear_autocmds({ group = augroup })
end

function M.health(h)
  h.ok(string.format("%s: :Org plan", "plan"))
end

---------------------------------------------------------------------------
-- Tasks
---------------------------------------------------------------------------

--- The row of a headline: the day it is scheduled, or nil when it is not
--- scheduled (still listed, with `scheduled = nil`, so it can be scheduled
--- from the grid). `rep` is the repeating scheduled timestamp, whose later
--- occurrences get their own rectangles.
---@param hl org.Headline
---@return table
function M.task(hl)
  local sts = hl.planning.scheduled
  local s = sts and sts:days()
  local done = hl:is_done()
  local rep
  if s and not done and sts.repeater and (sts.repeater.value or 0) > 0 then
    rep = sts
  end
  return {
    ref = views.ref(hl),
    todo = hl.todo,
    title = views.title(hl),
    scheduled = s,
    rep = rep,
    done = done,
    first = s,
  }
end

local function sort_rows(rows)
  table.sort(rows, function(a, b)
    if a.first ~= b.first then
      if a.first == nil then
        return false
      elseif b.first == nil then
        return true
      end
      return a.first < b.first
    end
    return a.order < b.order
  end)
end

--- The rows of the grid's tasks, sorted by scheduled day (undated last).
--- Remembers the files shown (`file_set`, `key`) for the redraw watch.
---@param st table
---@return table[] rows, string|nil err
function M.build(st)
  local o = st.opts
  local files = views.files(st.src)
  st.file_set = views.file_set(files)
  st.key = views.files_key(files)
  local hls, err = views.collect(st.src, {
    files = files,
    query = o.query,
    filter = st.filter,
    tag = st.tag,
    pred = function(hl)
      return (o.show_done or not hl:is_done()) and hl:is_todo()
    end,
  })
  local rows = {}
  for i, hl in ipairs(hls) do
    local t = M.task(hl)
    t.order = i
    rows[#rows + 1] = t
  end
  sort_rows(rows)
  return rows, err
end

---------------------------------------------------------------------------
-- Drawing
---------------------------------------------------------------------------

local function zoom(st)
  return M.ZOOMS[st.zoom]
end

local function win_width(st)
  local win = st.win and vim.api.nvim_win_is_valid(st.win) and st.win or nil
  return win and vim.api.nvim_win_get_width(win) or vim.o.columns
end

--- Width of the task names: `label_width`, at most 40% of a narrow window.
local function label_width(st)
  return math.max(8, math.min(st.opts.label_width or 34, math.floor(win_width(st) * 0.4)))
end

--- The drawing characters, with the two-cells-wide glyphs falling back to
--- ASCII when `ambiwidth` is "double": the grid is one character per cell.
local function glyphs()
  local function pick(ch, alt)
    return utils.width(ch) == 1 and ch or alt
  end
  return {
    v = "│",
    h = "─",
    x = "┼",
    bar = pick("█", "#"),
  }
end
-- the characters of the current draw (set by M.draw)
local G = glyphs()

--- `ch` repeated over `cells` display cells; a cell it can't fill (it is
--- two cells wide) is a space.
local function fill(ch, cells)
  local cw = math.max(1, utils.width(ch))
  local n = math.max(0, math.floor(cells / cw))
  return string.rep(ch, n) .. string.rep(" ", math.max(0, cells - n * cw))
end

--- Number of cells that fit in the chart area.
local function cell_count(st)
  local width = win_width(st) - label_width(st) - 2 - utils.width(G.v)
  return math.max(4, math.floor(width / zoom(st).width))
end

--- First and last day of cell `i` (0-based).
local function cell_days(st, i)
  local z = zoom(st)
  local a = st.start + i * z.days
  return a, a + z.days - 1
end

-- highlight group lists by background (weekend / today) and foreground,
-- shared so that runs of equal cells merge into one extmark
local BG = {
  we = { "OrgPlanWeekend" },
  t = { "OrgPlanToday" },
  wet = { "OrgPlanWeekend", "OrgPlanToday" },
}
local combos = {}
local function groups_of(bg, fg)
  local key = (bg or "") .. "|" .. (fg or "")
  local g = combos[key]
  if g == nil then
    g = vim.list_extend({}, BG[bg] or {})
    if fg then
      g[#g + 1] = fg
    end
    g = #g > 0 and g
    combos[key] = g
  end
  return g or nil
end

--- The days of `row` that fall inside [from, to], own occurrence first:
--- the scheduled day, then, for a repeating schedule, each later repeat.
local function occurrence_days(row, from, to)
  local days = {}
  if not row.scheduled then
    return days
  end
  days[#days + 1] = row.scheduled
  if row.rep then
    local base = row.rep:days()
    for _, occ in ipairs(date.occurrences(row.rep, from, to)) do
      local delta = occ:days() - base
      if delta > 0 then
        days[#days + 1] = base + delta
      end
    end
  end
  return days
end

--- The cells of a row between cells 0 and n-1: `hit[i]` the scheduled-day
--- rectangles (the highlighted day), `rep[i]` true when it is a repeat.
local function row_features(st, row, n, from)
  local zd = zoom(st).days
  local days = occurrence_days(row, from, from + n * zd - 1)
  local hit, rep = {}, {}
  for _, d in ipairs(days) do
    local i = math.floor((d - from) / zd)
    if i >= 0 and i < n then
      hit[i] = true
      if row.rep and d ~= row.scheduled then
        rep[i] = true
      end
    end
  end
  return hit, rep
end

--- Draw the chart part of a row into the canvas.
local function draw_row(cv, st, row, n, today, bgs, from)
  local w = zoom(st).width
  local hit, rep = row_features(st, row, n, from)
  local bar_hl = row.done and "OrgPlanDone" or "OrgPlanBar"
  -- runs of equal characters and highlights become one segment
  local run_ch, run_n, run_hl = nil, 0, nil
  local function emit(ch, hl)
    if ch == run_ch and hl == run_hl then
      run_n = run_n + 1
      return
    end
    if run_n > 0 then
      cv:put(string.rep(run_ch, run_n), run_hl)
    end
    run_ch, run_n, run_hl = ch, 1, hl
  end
  for i = 0, n - 1 do
    local bg = bgs[i]
    local ch, hl = " ", groups_of(bg, nil)
    if hit[i] then
      ch = G.bar
      hl = groups_of(bg, rep[i] and "OrgPlanRepeat" or bar_hl)
    end
    for _ = 1, w do
      emit(ch, hl)
    end
  end
  if run_n > 0 then
    cv:put(string.rep(run_ch, run_n), run_hl)
  end
end

--- The axis lines: months, then day numbers (and weekdays at day zoom).
local function axis(st, n, today)
  local z = zoom(st)
  local w = z.width
  local total = n * w
  local months = vim.split(string.rep(" ", total), "")
  local days = vim.split(string.rep(" ", total), "")
  local wdays = z.name == "day" and vim.split(string.rep(" ", total), "") or nil
  local function write(arr, pos, s)
    local chars = vim.fn.split(s, [[\zs]])
    for k, ch in ipairs(chars) do
      if pos + k - 1 <= #arr then
        arr[pos + k - 1] = ch
      end
    end
  end
  local last_month
  local today_pos
  local labels = {}
  for i = 0, n - 1 do
    local a, b = cell_days(st, i)
    local d = date.from_days(a)
    local pos = i * w + 1
    -- a month label where the month starts (the first cell always)
    local md = i == 0 and d or date.from_days(b)
    local key = md.year * 12 + md.month
    if key ~= last_month then
      labels[#labels + 1] = { pos = pos, month = md.month, year = md.year, first = i == 0 }
      last_month = key
    end
    if z.name == "day" then
      write(days, pos, string.format("%2d", d.day))
      write(wdays, pos, date.DAY_NAMES[d:weekday()]:sub(1, 2))
    elseif z.name == "week" then
      if d:weekday() == 1 then
        write(days, pos, tostring(d.day))
      end
    else
      if d.day <= 7 then
        write(days, pos, "┊")
      end
    end
    if today >= a and today <= b then
      today_pos = pos
    end
  end
  -- labels that would run into the next one are shortened or left out
  for k, l in ipairs(labels) do
    local room = (labels[k + 1] and labels[k + 1].pos or total + 1) - l.pos - 1
    local label = date.MONTH_NAMES[l.month]
    if (l.first or l.month == 1) and room >= #label + 5 then
      label = label .. " " .. l.year
    end
    if room >= #label then
      write(months, l.pos, label)
    end
  end
  local out = { table.concat(months), table.concat(days) }
  if wdays then
    out[#out + 1] = table.concat(wdays)
  end
  return out, today_pos
end

--- A friendlier label for a files source: the directory names of the
--- patterns ("assignments, todos"), not the "*.org" tails.
---@param src table
---@return string
local function source_label(src)
  if src.kind == "files" then
    local dirs, seen = {}, {}
    for _, p in ipairs(src.patterns) do
      local parts = vim.split(p, "/")
      -- drop a file part or a trailing ** glob before taking the directory
      if parts[#parts]:find("%*") or parts[#parts]:match("%.org$") then
        parts[#parts] = nil
      end
      if parts[#parts] == "**" or parts[#parts] == "*" then
        parts[#parts] = nil
      end
      local d = parts[#parts] or vim.fn.fnamemodify(p, ":t")
      if d ~= "" and not seen[d] then
        seen[d] = true
        dirs[#dirs + 1] = d
      end
    end
    if #dirs > 0 then
      return table.concat(dirs, ", ")
    end
  end
  return views.source_label(src)
end

local function hint(o)
  local k = o.keys or {}
  local function key(name)
    return require("org.extensions.views_util").key_hint(k, name)
  end
  local parts = {}
  for _, p in ipairs({
    { "zoom_in", "zoom_out", "zoom" },
    { "pan_left", "pan_right", "pan" },
    { "today", nil, "today" },
    { "jump", nil, "open" },
    { "schedule", nil, "schedule" },
    { "deadline", nil, "deadline" },
    { "quit", nil, "quit" },
  }) do
    local a, b = key(p[1]), p[2] and key(p[2])
    if a then
      parts[#parts + 1] = (b and (a .. "/" .. b) or a) .. " " .. p[3]
    end
  end
  return table.concat(parts, "  ")
end

--- Draw the grid from `st.task_rows` (built by `build`).
function M.draw(st)
  if not vim.api.nvim_buf_is_valid(st.buf) then
    return
  end
  local o = st.opts
  G = glyphs()
  local today = date.today_days()
  local n = cell_count(st)
  st.cells = n
  local z = zoom(st)
  local lw = label_width(st)
  local rows = st.task_rows or {}
  st.rows = rows
  local cv = views.Canvas.new()
  local first, last = date.from_days(st.start), date.from_days(select(2, cell_days(st, n - 1)))
  cv:add({
    { " Plan", "OrgPlanTitle" },
    { "  " .. source_label(st.src), "OrgPlanHint" },
    {
      string.format(
        "  · %s · %s – %s",
        z.name,
        first:strftime(first.year == last.year and "%b %d" or "%b %d %Y"),
        last:strftime("%b %d %Y")
      ),
      "OrgPlanHint",
    },
  })
  for _, f in ipairs({
    o.query and ("query " .. o.query) or false,
    st.tag and ("tag " .. st.tag) or false,
    st.filter or false,
  }) do
    if f then
      cv:put("  · " .. f, "OrgPlanHint")
    end
  end
  if st.err then
    cv:put("  " .. st.err, "DiagnosticError")
  end
  cv:add({ { " " .. hint(o), "OrgPlanHint" } })
  local ax, today_pos = axis(st, n, today)
  for li, text in ipairs(ax) do
    cv:line()
    cv:put(string.rep(" ", lw + 1))
    cv:put(G.v, "OrgPlanSeparator")
    local hl = li == 1 and "OrgPlanMonth" or "OrgPlanAxis"
    if today_pos and li > 1 then
      -- the today cell of the day rows stands out
      local chars = vim.fn.split(text, [[\zs]])
      cv:put(table.concat(chars, "", 1, today_pos - 1), hl)
      cv:put(table.concat(chars, "", today_pos, today_pos + z.width - 1), "OrgPlanTodayLabel")
      cv:put(table.concat(chars, "", today_pos + z.width), hl)
    else
      cv:put(text, hl)
    end
  end
  cv:add({
    { fill(G.h, lw + 1), "OrgPlanSeparator" },
    { G.x, "OrgPlanSeparator" },
    { fill(G.h, n * z.width), "OrgPlanSeparator" },
  })
  -- the background of each cell: weekends (at day zoom) and today
  local bgs = {}
  for i = 0, n - 1 do
    local a, b = cell_days(st, i)
    local we = z.days == 1 and z.width > 1 and date.from_days(a):weekday() >= 6
    local t = today >= a and today <= b
    bgs[i] = (we and t) and "wet" or (we and "we") or (t and "t") or nil
  end
  st.first_row_line = #cv.lines + 1
  st.line_rows = {}
  local todo_cfg = require("org.todo_keywords").global()
  for _, row in ipairs(rows) do
    local lnum = cv:line()
    st.line_rows[lnum] = row
    cv:put(" ")
    -- the label is `lw` cells: keyword and title cut to fit together
    local room = lw
    if row.todo then
      local group = views.todo_group(row.todo, todo_cfg)
      local kw_w = utils.width(row.todo)
      if kw_w < room then
        cv:put(row.todo, group)
        cv:put(" ")
        room = room - kw_w - 1
      else
        cv:put(views.fit(row.todo, room), group)
        room = 0
      end
    end
    if room > 0 then
      cv:put(
        views.fit(row.title, room),
        row.done and "OrgPlanDone" or "OrgPlanTask"
      )
    end
    cv:put(G.v, "OrgPlanSeparator")
    draw_row(cv, st, row, n, today, bgs, st.start)
  end
  if #rows == 0 then
    cv:add({ { " No tasks" , "OrgPlanHint" } })
  end
  cv:draw(st.buf, ns)
  if st.win and vim.api.nvim_win_is_valid(st.win) then
    local cur = vim.api.nvim_win_get_cursor(st.win)[1]
    local line = math.max(cur, st.first_row_line)
    line = math.min(line, vim.api.nvim_buf_line_count(st.buf))
    pcall(vim.api.nvim_win_set_cursor, st.win, { line, 1 })
  end
end

--- Build and draw the grid.
function M.render(st)
  if not vim.api.nvim_buf_is_valid(st.buf) then
    return
  end
  st.task_rows, st.err = M.build(st)
  M.draw(st)
end

---------------------------------------------------------------------------
-- Commands
---------------------------------------------------------------------------

local function current()
  local st = M.state
  if st and vim.api.nvim_buf_is_valid(st.buf) then
    return st
  end
end

--- The task on the cursor line, or nil.
function M.row_at_cursor()
  local st = current()
  if not st or not (st.win and vim.api.nvim_win_is_valid(st.win)) then
    return nil
  end
  return st.line_rows[vim.api.nvim_win_get_cursor(st.win)[1]]
end

--- Rebuild and redraw. With `lazy` (the redraw watch), nothing happens
--- while the plan files are unchanged.
---@param lazy? boolean
function M.refresh(lazy)
  local st = current()
  if not st then
    return
  end
  if lazy == true and st.key and st.key == views.files_key(views.files(st.src)) then
    return
  end
  M.render(st)
end

--- First day of the view so that `day` is `offset` cells from the left.
local function start_for(st, day, offset)
  local z = zoom(st)
  local s = day - offset * z.days
  if z.days == 7 then
    -- weeks start on Monday
    s = s - (date.from_days(s):weekday() - 1)
  end
  return s
end

--- Zoom in (`dir` = -1) or out (1), keeping the middle day in place.
function M.zoom(dir)
  local st = current()
  if not st then
    return
  end
  local nz = math.max(1, math.min(#M.ZOOMS, st.zoom + dir))
  if nz == st.zoom then
    return
  end
  local mid = st.start + math.floor(st.cells / 2) * zoom(st).days
  st.zoom = nz
  local n = cell_count(st)
  st.start = start_for(st, mid, math.floor(n / 2))
  M.draw(st)
end

--- Pan by half a screen: `dir` = -1 to the past, 1 to the future.
function M.pan(dir)
  local st = current()
  if not st then
    return
  end
  st.start = st.start + dir * math.max(1, math.floor(st.cells / 2)) * zoom(st).days
  M.draw(st)
end

function M.goto_today()
  local st = current()
  if not st then
    return
  end
  st.start = start_for(st, date.today_days(), st.opts.days_before or 3)
  M.draw(st)
end

function M.jump()
  local st = current()
  local row = M.row_at_cursor()
  if st and row then
    views.jump(row.ref, st.how)
  end
end

--- Reschedule (`kind` "scheduled") or set the deadline of the task at the
--- cursor with the usual date prompt.
function M.plan(kind)
  local st = current()
  local row = M.row_at_cursor()
  if not st or not row then
    return
  end
  local target = views.target(row.ref)
  if not target then
    return
  end
  local ts = require("org.timestamps")
  local res = kind == "deadline" and ts.deadline(target) or ts.schedule(target)
  if res then
    views.after_edit(target.bufnr, st.opts.save)
  end
  if current() == st then
    M.render(st)
  end
end

function M.close()
  local st = M.state
  M.state = nil
  if not st then
    return
  end
  pcall(vim.api.nvim_del_augroup_by_id, st.watch)
  if vim.api.nvim_buf_is_valid(st.buf) then
    local win = st.how.win
    if win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == st.buf then
      views.close(st.how)
    end
    if vim.api.nvim_buf_is_valid(st.buf) then
      pcall(vim.api.nvim_buf_delete, st.buf, { force = true })
    end
  end
end

---------------------------------------------------------------------------
-- Opening
---------------------------------------------------------------------------

local function zoom_index(name)
  for i, z in ipairs(M.ZOOMS) do
    if z.name == name then
      return i
    end
  end
end

--- Open the grid.
---@param o? { source?: any, zoom?: string, filter?: string, tag?: string, query?: string }
function M.open(o)
  o = type(o) == "table" and o or {}
  local eopts = vim.deepcopy(opts())
  if o.query then
    eopts.query = o.query
  end
  local src, err = views.resolve_source(o.source or eopts.source)
  if not src then
    utils.error("plan: " .. err)
    return
  end
  M.close()
  local buf = views.scratch("org://plan", "orgplan")
  local st = {
    buf = buf,
    src = src,
    opts = eopts,
    filter = o.filter,
    tag = o.tag or eopts.tag,
    zoom = zoom_index(o.zoom or eopts.zoom) or 1,
  }
  M.state = st
  st.win, st.how = views.open(buf, eopts.layout, { width = eopts.width, height = eopts.height, title = "Plan" })
  vim.wo[st.win].cursorline = true
  st.start = start_for(st, date.today_days(), eopts.days_before or 3)
  views.map(buf, eopts.keys, {
    zoom_in = function()
      M.zoom(-1)
    end,
    zoom_out = function()
      M.zoom(1)
    end,
    pan_left = function()
      M.pan(-1)
    end,
    pan_right = function()
      M.pan(1)
    end,
    today = M.goto_today,
    jump = M.jump,
    schedule = function()
      M.plan("scheduled")
    end,
    deadline = function()
      M.plan("deadline")
    end,
    refresh = function()
      M.refresh()
    end,
    quit = M.close,
  }, "plan")
  st.watch = views.watch("OrgPlanWatch", function()
    if current() == st then
      M.refresh(true)
    end
  end, { buf = buf, relevant = views.relevant(st) })
  vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
    group = st.watch,
    callback = function(ev)
      if current() ~= st then
        return
      end
      if ev.event == "WinResized" and not vim.tbl_contains(vim.v.event.windows or {}, st.win) then
        return
      end
      if ev.event == "VimResized" then
        views.relayout(st.how)
      end
      pcall(M.draw, st)
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = st.watch,
    buffer = buf,
    callback = function()
      if M.state == st then
        M.state = nil
      end
      vim.schedule(function()
        pcall(vim.api.nvim_del_augroup_by_id, st.watch)
      end)
    end,
  })
  M.render(st)
  return st
end

function M.open_buffer()
  return M.open({ source = "buffer" })
end

--- Parse `:Org plan` arguments.
function M.parse_args(args)
  local o = {}
  local rest = {}
  for _, w in ipairs(vim.split(vim.trim(args or ""), "%s+", { trimempty = true })) do
    if not o.source and (w == "agenda" or w == "buffer" or w == "subtree") then
      o.source = w
    elseif not o.zoom and zoom_index(w) then
      o.zoom = w
    elseif not o.source and #rest == 0 and views.is_path(w) then
      o.source = utils.expand(w)
    else
      rest[#rest + 1] = w
    end
  end
  if #rest > 0 then
    o.filter = table.concat(rest, " ")
  end
  return o
end

--- Completion of `:Org plan`: sources, zooms and tags.
function M.complete(arglead)
  local out = views.complete_sources(arglead)
  for _, z in ipairs(M.ZOOMS) do
    out[#out + 1] = z.name
  end
  return vim.list_extend(out, views.complete_tags())
end

--- `:Org plan [agenda|buffer|subtree|<file>] [day|week|month] [filter]`.
function M.command(args)
  local o = M.parse_args(args)
  if o.filter then
    local _, err = views.compile_filter(o.filter)
    if err then
      utils.error(err)
      return
    end
  end
  return M.open(o)
end

return M