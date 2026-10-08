---@mod org.extensions.completion Completion-percent model and cycling
---
--- A `:COMPLETION:` property model for org headlines: read it as a percent,
--- cycle it through a fixed ladder of segments, and act on it from an org
--- buffer or an agenda view.
---
--- As an org extension it registers the `set_completion` action for
--- `mappings.org.set_completion` and `:Org set_completion` (the contract's
--- `actions` field). The agenda side dispatches through a separate registry
--- (`org.agenda.view.actions`), which the extension contract has no field
--- for, so `setup()` assigns it there and `teardown()` restores it. Bind
--- both sides in your config:
---
--- ```lua
--- extensions = { completion = { segments = { 10, 25, 50, 75, 90 } } },
--- mappings = {
---   org = { set_completion = "<prefix>C" },
---   agenda = { set_completion = "C" },
--- },
--- ```
---
--- There is no 100% segment: a fully completed task is DONE, so the cycle
--- ends at 90 -> none rather than claiming completion.

local M = {}

--- Option defaults; the user's `extensions.completion` table is merged
--- over them by the extension loader.
M.defaults = {
  --- The allowed values of an item's :COMPLETION:.
  segments = { 10, 25, 50, 75, 90 },
}

--- Current segments; `setup(opts)` refreshes it from `opts.segments`.
---@type integer[]
M.SEGMENTS = vim.deepcopy(M.defaults.segments)

--- Registered into `org.actions.list` by the extension loader:
--- `mappings.org.set_completion` and `:Org set_completion` resolve here.
---@type table<string, org.Action>
M.actions = {
  set_completion = {
    "org.extensions.completion",
    "cycle_completion_at_cursor",
    desc = "Cycle the completion percent of the entry at point",
  },
}

--- Completion percent of an item, 0..100, 0 when it has none. The value of
--- its headline's :COMPLETION: property (inherited up the file if absent).
---@param item table
---@return integer
function M.completion_pct(item)
  local hl = item and item.headline
  local v = hl and tostring(hl:get_property("COMPLETION") or ""):match("^(%d+)")
  if not v then
    return 0
  end
  return math.min(math.max(tonumber(v), 0), 100)
end

--- The completion fraction of an item, 0..1, `nil` when unset (so "not
--- tracked" stays neutral for readers like the urgency score instead of
--- counting as 0%).
---@param item table
---@return number|nil
function M.completion_fraction(item)
  local hl = item and item.headline
  if not (hl and hl:get_property("COMPLETION")) then
    return nil
  end
  return M.completion_pct(item) / 100
end

--- Move an entry's :COMPLETION: to the next segment (10 -> 25 -> 50 -> 75 ->
--- 90 -> none) and save its buffer. The engine behind both the buffer
--- mapping and the agenda `C` key. Returns the new value as display text
--- ("50%", "none"), nil when there is no entry.
---@param bufnr integer
---@param lnum integer
---@param hl org.Headline|nil
---@return string|nil
function M.cycle_completion(bufnr, lnum, hl)
  if not hl then
    return nil
  end
  local cur = M.completion_pct({ headline = hl })
  local pick
  for i, s in ipairs(M.SEGMENTS) do
    if s > cur then
      pick = i
      break
    end
  end
  local target = { bufnr = bufnr, lnum = lnum }
  local props = require("org.properties")
  local utils = require("org.utils")
  if pick then
    props.set_property(target, "COMPLETION", tostring(M.SEGMENTS[pick]))
  else
    props.delete_property(target, "COMPLETION")
  end
  if vim.bo[target.bufnr].modified then
    utils.save_buffer_or_warn(target.bufnr)
  end
  return pick and ("%d%%"):format(M.SEGMENTS[pick]) or "none"
end

--- Cycle the completion of the entry under the cursor in an org buffer (the
--- heading mapping). Returns false when not on an entry, so the key falls
--- through to its default behaviour.
---@return boolean handled
function M.cycle_completion_at_cursor()
  local edit = require("org.edit")
  local bufnr, _, hl = edit.resolve()
  if not hl then
    return false
  end
  local res = M.cycle_completion(bufnr, hl.line, hl)
  if res then
    require("org.utils").notify(("COMPLETION: %s"):format(res))
  end
  return true
end

--- The agenda side of `set_completion`: cycles the entry under the cursor
--- from any agenda view and refreshes, so an urgency-sorted view re-ranks
--- right away and the new percent shows at the end of the line. The target
--- is resolved through view.resolve_target, which loads the item's own file
--- and points at the real headline line.
function M.agenda_cycle()
  local view = require("org.agenda.view")
  local item = view.item_at_cursor()
  if not item or item.not_org then
    return
  end
  local target = item.headline and view.resolve_target(item)
  if not target then
    return
  end
  local file = require("org.files").get_buffer(target.bufnr)
  local res = file and M.cycle_completion(target.bufnr, target.lnum, file:headline_at(target.lnum))
  if res then
    require("org.utils").notify(("COMPLETION: %s"):format(res))
    view.refresh()
  end
end

local saved_view_action, saved = nil, false

--- Resolve options (called by the extension loader) and wire the agenda
--- action; `mappings.agenda.set_completion` dispatches through
--- `org.agenda.view.actions`, which has no field on `org.Extension`.
---@param opts? table
function M.setup(opts)
  opts = opts or {}
  if opts.segments ~= nil then
    if type(opts.segments) ~= "table" or #opts.segments == 0 then
      error(("completion: opts.segments must be a non-empty list, got %s"):format(vim.inspect(opts.segments)))
    end
    M.SEGMENTS = opts.segments
  else
    M.SEGMENTS = vim.deepcopy(M.defaults.segments)
  end
  local view = require("org.agenda.view")
  if not saved then
    saved_view_action = view.actions.set_completion
    saved = true
  end
  view.actions.set_completion = M.agenda_cycle
end

--- Undo what `setup` did when the extension is turned off or reconfigured.
function M.teardown()
  if saved then
    require("org.agenda.view").actions.set_completion = saved_view_action
    saved_view_action, saved = nil, false
  end
  M.SEGMENTS = vim.deepcopy(M.defaults.segments)
end

return M
