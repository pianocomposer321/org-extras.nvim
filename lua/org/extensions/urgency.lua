---@mod org.extensions.urgency A composite urgency score for agenda items
---
--- Sort a list by "what to do next" instead of by date alone. The score
--- combines how soon a task is due, how big it is (Effort, log scale) and
--- how far along it already is (the `org.extensions.completion` percent),
--- with a floor for tasks you tagged "today". `cmp` is that score as a
--- `cmp_user_defined` comparator — bind it on a block that sorts
--- "user-defined-up":
---
--- ```lua
--- { type = "list_view", sorting = { "user-defined-up" },
---   cmp_user_defined = require("org.extensions.urgency").cmp }
--- ```
---
--- The formula is fully configurable through `defaults` below: every
--- constant is an option, and `extensions = { urgency = { score = fn } }`
--- replaces the score outright. `cmp_with(fn)` builds a comparator over any
--- scoring function, for a one-off view with its own idea of "urgent".

local completion = require("org.extensions.completion")

local M = {}

--- Option defaults; the user's `extensions.urgency` table is merged over
--- them by the extension loader (direct `setup(opts)` calls merge too —
--- no args restores them). Each maps onto one term of the expression
--- documented on `M.urgency`.
M.defaults = {
  --- Urgency floor for a headline tagged `:today:` with no dates at all:
  --- you said you'd do it today.
  today_floor = 70,
  --- Severity of a date at zero days out — the peak of the curve, and the
  --- base every overdue day adds to.
  severity_now = 80,
  --- Extra severity for each day past due (overdue = severity_now + this * days).
  overdue_rate = 40,
  --- How fast dates ahead fall off: severity_now / (1 + days) ^ decay.
  --- Smaller = dates matter less, 0 = all future dates equal.
  decay = 0.75,
  --- A scheduled day counts at this fraction of the same-day severity
  --- (a start-hint, not a promise).
  scheduled_weight = 0.8,
  --- Flat add on a deadline's severity: due-by outranks start-hint.
  deadline_bonus = 6,
  --- Multiplier on ln(1 + hours) of Effort: 0 removes effort from the
  --- ranking entirely, bigger gives it more say.
  effort_scale = 1,
  --- Largest fraction completion may subtract (0 disables the penalty).
  completion_damping = 0.5,
  --- Ramp of the completion penalty: above 1, the middle of the scale
  --- barely dents and only near-done tasks are demoted hard.
  completion_gamma = 1.5,
  --- Full override: `function(item) -> number`, used instead of every
  --- option above (including today_floor).
  score = nil,
}

---@type table
M.opts = vim.deepcopy(M.defaults)

--- Merge options (nil resets to defaults). Called by the extension loader
--- with `defaults` merged under the user's `extensions.urgency` table; the
--- merge is idempotent, so direct calls work too. `score` (if given) must
--- be a function(item) -> number and replaces the whole expression.
---@param opts? table
function M.setup(opts)
  opts = opts or {}
  if opts.score ~= nil and type(opts.score) ~= "function" then
    error(("urgency: opts.score must be a function, got %s"):format(type(opts.score)))
  end
  M.opts = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts)
end

--- Forget any configured options when the extension is turned off or
--- reconfigured; the next `setup` starts from `defaults` again.
function M.teardown()
  M.opts = vim.deepcopy(M.defaults)
end

--- How many days a date is away weighs on urgency: overdue counts the most
--- (each past day adds), today is the peak of the normal scale, and further
--- dates fall off along a power curve that stays positive forever — a task
--- due in two months still has a score instead of the zero (or negative)
--- that buried fresh tasks under half-done ones.
---@param days integer days until the date; negative when past
---@return number
function M.date_severity(days)
  local o = M.opts
  if days < 0 then
    return o.severity_now + o.overdue_rate * (-days)
  end
  return o.severity_now / (1 + days) ^ o.decay
end

--- How Effort weighs on urgency: bigger tasks need a longer runway, but on a
--- log scale (effort_scale * ln of the hours) so the effort ladder orders
--- tasks at the same date without ever jumping a whole day's difference.
---@param minutes integer|nil
---@return number
function M.effort_weight(minutes)
  if not minutes or minutes <= 0 then
    return 1
  end
  return 1 + M.opts.effort_scale * math.log(1 + minutes / 60)
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

--- How completion weighs on urgency: a penalty of up to `completion_damping`,
--- ramped by completion ^ completion_gamma so the middle of the scale barely
--- dents a task (factor ~0.82 at 50% with the defaults) while a nearly-done
--- one settles to ~0.57 at 90% — still enough to keep progress demoting, not
--- enough to bury a due-soon task. A task without a completion property is
--- untouched (factor 1).
---@param item table
---@return number
function M.completion_factor(item)
  local f = completion.completion_fraction(item)
  if not f then
    return 1
  end
  return 1 - M.opts.completion_damping * f ^ M.opts.completion_gamma
end

--- Urgency of an agenda item, bigger is more urgent. The subjective rules
--- it encodes (and rcheck.lua tests):
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
---   date severity   = severity_now + overdue_rate*days_overdue  when past
---                      severity_now / (1 + days)^decay          when ahead
---   scheduled       = scheduled_weight * severity(days until scheduled)
---   deadline        = severity(days until deadline) + deadline_bonus
---   today-tag floor = today_floor (max'd in before effort/completion)
---   effort weight   = 1 + effort_scale * ln(1 + hours)
---   completion      = 1 - completion_damping * completion^completion_gamma
---   urgency         = closer * effort weight * completion factor
---
--- with the defaults from `M.defaults` — or, when `opts.score` is set, that
--- function's return value instead. Tweak the numbers to taste; sorting and
--- the ranking tests all read exactly this function.
---@param item table
---@return number
function M.urgency(item)
  local o = M.opts
  if o.score then
    local v = o.score(item)
    assert(type(v) == "number", ("urgency: opts.score must return a number, got %s"):format(type(v)))
    return v
  end
  local today = require("org.date").today_days()
  local planning = item.headline and item.headline.planning or {}
  local s = planning.scheduled and planning.scheduled:days() or nil
  local d = planning.deadline and planning.deadline:days() or nil
  local closer = 0
  if s then
    closer = math.max(closer, o.scheduled_weight * M.date_severity(s - today))
  end
  if d then
    closer = math.max(closer, M.date_severity(d - today) + o.deadline_bonus)
  end
  local hl = item.headline
  if hl and M.has_today_tag(hl) then
    closer = math.max(closer, o.today_floor)
  end
  if closer == 0 then
    return 0
  end
  local minutes = require("org.agenda.items").effort(item)
  return closer * M.effort_weight(minutes) * M.completion_factor(item)
end

--- Any scoring function as a `cmp_user_defined` comparator: descending,
--- `nil` when undecided so the next strategy in the block's `sorting`
--- breaks ties. Use it for a view with its own idea of urgency:
---
--- ```lua
--- local cmp_with = require("org.extensions.urgency").cmp_with
--- cmp_user_defined = cmp_with(function(item) ... return score end)
--- ```
---@param score fun(item: table): number
---@return fun(a: table, b: table): integer|nil
function M.cmp_with(score)
  return function(a, b)
    local x, y = score(a), score(b)
    if x == y then
      return nil
    end
    return x > y and -1 or 1
  end
end

--- The default score (`M.urgency`) as a comparator — see `cmp_with`.
---@param a table
---@param b table
---@return integer|nil
M.cmp = M.cmp_with(function(item)
  return M.urgency(item)
end)

return M
