---@mod org_extras.urgency A composite urgency score for agenda items
---
--- Sort a list by "what to do next" instead of by date alone. The score
--- combines how soon a task is due, how big it is (Effort, log scale) and
--- how far along it already is (the `org_extras.completion` percent), with
--- a floor for tasks you tagged "today". `cmp` is that score as a
--- `cmp_user_defined` comparator — bind it on a block that sorts
--- "user-defined-up":
---
--- ```lua
--- { type = "list_view", sorting = { "user-defined-up" },
---   cmp_user_defined = require("org_extras.urgency").cmp }
--- ```

local completion = require("org_extras.completion")

local M = {}

--- Option defaults; `setup(opts)` merges over them.
M.defaults = {
  --- Urgency floor for a headline tagged `:today:` with no dates at all:
  --- you said you'd do it today.
  today_floor = 70,
}

---@type table
M.opts = vim.deepcopy(M.defaults)

--- Merge options (nil resets to defaults).
---@param opts? table
function M.setup(opts)
  M.opts = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
end

--- How many days a date is away weighs on urgency: overdue counts the most
--- (each past day adds), today is the peak of the normal scale, and further
--- dates fall off along a power curve that stays positive forever — a task
--- due in two months still has a score instead of the zero (or negative)
--- that buried fresh tasks under half-done ones.
---@param days integer days until the date; negative when past
---@return number
function M.date_severity(days)
  if days < 0 then
    return 80 + 40 * (-days)
  end
  return 80 / (1 + days) ^ 0.75
end

--- How Effort weighs on urgency: bigger tasks need a longer runway, but on a
--- log scale (1 + ln of the hours) so the effort ladder orders tasks at the
--- same date without ever jumping a whole day's difference.
---@param minutes integer|nil
---@return number
function M.effort_weight(minutes)
  if not minutes or minutes <= 0 then
    return 1
  end
  return 1 + math.log(1 + minutes / 60)
end

--- Whether the headline carries the :today: tag, which — like a due-now
--- date — puts such a task above undated ones and floors its urgency.
---@param hl table org.Headline
---@return boolean
function M.has_today_tag(hl)
  local tags = hl.tags
  if tags then
    for _, t in ipairs(tags) do
      if type(t) == "string" and t:lower() == "today" then
        return true
      end
    end
  end
  local path, line = hl.file and hl.file.filename, hl.line
  if path and line then
    local ok, lines = pcall(vim.fn.readfile, path)
    if ok and lines[line] then
      local body = lines[line]:match(":(.*):%s*$")
      if body then
        for t in (body:gsub("[%s:]+", ":")):gmatch("[^:]+") do
          if t:lower() == "today" then
            return true
          end
        end
      end
    end
  end
  return false
end

--- How completion weighs on urgency: a penalty of up to 50%, ramped by
--- completion^1.5 so the middle of the scale barely dents a task (factor
--- ~0.82 at 50%) while a nearly-done one settles to ~0.57 at 90% — still
--- enough to keep progress demoting, not enough to bury a due-soon task.
--- A task without a completion property is untouched (factor 1).
---@param item table
---@return number
function M.completion_factor(item)
  local f = completion.completion_fraction(item)
  if not f then
    return 1
  end
  return 1 - 0.5 * f ^ 1.5
end

--- Urgency of an agenda item, bigger is more urgent. The subjective rules
--- it encodes:
---
---   * overdue > due today > due tomorrow > later, always;
---   * a deadline outweighs the same-day schedule (due-by beats start-hint),
---     and a scheduled day is worth a little less than a deadline day;
---   * at equal dates more Effort ranks first (runway), but on a log scale
---     so one day of distance always beats the whole effort ladder;
---   * completion demotes gently (50% barely dents it, 90% settles to ~57%)
---     so a nearly-done task due tomorrow still outranks a fresh task due
---     next week — and, because the date curve never goes negative, never
---     below an undated one either;
---   * a :today:-tagged task with no dates still scores (the `today_floor`
---     option): you said you'd do it today.
---
---   date severity   = 80 + 40*days_overdue    when past
---                      80 / (1 + days)^0.75   when ahead (positive always)
---   scheduled       = 0.8 * severity(days until scheduled)
---   deadline        = 1.0 * severity(days until deadline) + 6
---   today-tag floor = opts.today_floor (max'd in before effort/completion)
---   effort weight   = 1 + ln(1 + hours)
---   completion      = 1 - 0.5 * completion^1.5   (completion 0..1)
---   urgency         = closer * effort weight * completion factor
---
--- Tweak the numbers to taste; sorting and the ranking tests all read
--- exactly this function.
---@param item table
---@return number
function M.urgency(item)
  local today = require("org.date").today_days()
  local planning = item.headline and item.headline.planning or {}
  local s = planning.scheduled and planning.scheduled:days() or nil
  local d = planning.deadline and planning.deadline:days() or nil
  local closer = 0
  if s then
    closer = math.max(closer, 0.8 * M.date_severity(s - today))
  end
  if d then
    closer = math.max(closer, M.date_severity(d - today) + 6)
  end
  local hl = item.headline
  if hl and M.has_today_tag(hl) then
    closer = math.max(closer, M.opts.today_floor)
  end
  if closer == 0 then
    return 0
  end
  local minutes = require("org.agenda.items").effort(item)
  return closer * M.effort_weight(minutes) * M.completion_factor(item)
end

--- The score as a `cmp_user_defined` comparator: descending, `nil` when
--- undecided so the next strategy in the block's `sorting` breaks ties.
---@param a table
---@param b table
---@return integer|nil
function M.cmp(a, b)
  local x, y = M.urgency(a), M.urgency(b)
  if x == y then
    return nil
  end
  return x > y and -1 or 1
end

return M
