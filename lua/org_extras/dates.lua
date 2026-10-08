---@mod org_extras.dates Relative-day labels for planning timestamps
---
--- Shared helpers for the extensions in this bundle: the "today / tomorrow /
--- next Friday" ladder used by the `list_view` cells, the agenda echo and
--- column display functions.

local M = {}

--- Relative day label of a `date` relative to today ("today", "tomorrow",
--- a weekday up to a week out, "next <weekday>" up to the fortnight, then
--- "Mon 5").
---@param ts table org.date
---@return string
function M.relative_day(ts)
  local n = ts:days() - require("org.date").today_days()
  if n == 0 then
    return "today"
  elseif n == 1 then
    return "tomorrow"
  elseif n < 0 then
    return "overdue"
  elseif n <= 6 then
    return (ts:strftime("%A"))
  elseif n <= 13 then
    return "next " .. (ts:strftime("%A"))
  end
  return (ts:strftime("%b %-d"))
end

--- Two relative-day labels of an item's planning dates: `"tomorrow", "Friday"`.
--- A missing date gives an empty label.
---@param item table
---@return string,string scheduled, deadline
function M.planning_labels(item)
  local p = item.headline and item.headline.planning or {}
  local s = p.scheduled and M.relative_day(p.scheduled) or ""
  local d = p.deadline and M.relative_day(p.deadline) or ""
  return s, d
end

return M
