---@mod org_extras org-extras.nvim — extras for org.nvim
---
--- A bundle of independent extensions for [org.nvim](https://github.com/xheisenbugx/org.nvim):
---
---   * `org_extras.list_view` — the `list_view` agenda type: agenda lines
---     laid out from format strings, right-aligned cells and all;
---   * `org_extras.urgency` — a composite "what to do next" score and the
---     `cmp` comparator for it;
---   * `org_extras.completion` — the `:COMPLETION:` percent model, its
---     cycling actions, and the values the urgency score reads;
---   * `org.extensions.plan` — a scheduling grid (installable as an
---     org.nvim extension; enable it through `org.setup`, see the README).
---
--- ```lua
--- require("org_extras").setup({
---   urgency = { today_floor = 70 },
---   completion = { segments = { 10, 25, 50, 75, 90 } },
--- })
--- ```
---
--- Every extension can be turned off with `setup({ <name> = false })`; they
--- are all on by default.

local M = {}

--- Enable / configure the bundle. Idempotent-ish: each extension's setup
--- guards its own registration, so calling this twice is safe.
---@param opts? { list_view?: table|boolean, urgency?: table|boolean, completion?: table|boolean }
function M.setup(opts)
  opts = opts or {}
  if opts.list_view ~= false then
    require("org_extras.list_view").setup(opts.list_view)
  end
  if opts.urgency ~= false then
    require("org_extras.urgency").setup(opts.urgency)
  end
  if opts.completion ~= false then
    require("org_extras.completion").setup(opts.completion)
  end
end

return M
