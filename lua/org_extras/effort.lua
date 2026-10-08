---@mod org_extras.effort Effort parsing and labels
---
--- The helpers behind `list_view`'s `%e` cell and any view that buckets
--- tasks by how long they take.

local M = {}

--- Minutes as the "#h##" of org-mode's effort field ("60" -> "1:00").
--- Nothing (nil or 0) gives "".
---@param minutes integer|nil
---@return string
function M.format_effort(minutes)
  if not minutes or minutes <= 0 then
    return ""
  end
  return ("%d:%02d"):format(math.floor(minutes / 60), minutes % 60)
end

-- The effort ladder a 0:30 / 1:00 / 2:00 Effort_ALL uses and the
-- human-readable name it maps to ("short" / "medium" / "long").
---@param minutes integer|nil
---@return string "" when there is no effort
function M.effort_name(minutes)
  if not minutes or minutes <= 0 then
    return ""
  end
  local best = "medium"
  local bd = math.huge
  for _, e in ipairs({ { 30, "short" }, { 60, "medium" }, { 120, "long" } }) do
    local d = math.abs(minutes - e[1])
    if d < bd then
      best, bd = e[2], d
    end
  end
  return best
end

--- "1:00" -> 60, "0:30" -> 30; tolerant of "90", "30m", "1h", "1h30", "2d".
--- Anything unparseable returns nil.
---@param v any
---@return integer|nil
function M.duration_minutes(v)
  v = tostring(v or ""):match("^%s*(.-)%s*$")
  if v == "" then
    return nil
  end
  local hh, mm = v:match("^(%d+):(%d%d)$")
  if hh then
    return tonumber(hh) * 60 + tonumber(mm)
  end
  if v:match("^%d+$") then
    return tonumber(v)
  end
  local hh2, mm2 = v:match("^(%d+)h(%d+)$")
  if hh2 then
    return tonumber(hh2) * 60 + tonumber(mm2)
  end
  local total = 0
  for n in v:gmatch("(%d+)d") do
    total = total + tonumber(n) * 24 * 60
  end
  for n in v:gmatch("(%d+)h") do
    total = total + tonumber(n) * 60
  end
  for n in v:gmatch("(%d+)m") do
    total = total + tonumber(n)
  end
  return total > 0 and total or nil
end

--- Effort of an agenda item in minutes (nil when it has none), through
--- org.nvim's own effort field.
---@param item table
---@return integer|nil
function M.minutes_of(item)
  return require("org.agenda.items").effort(item)
end

return M
