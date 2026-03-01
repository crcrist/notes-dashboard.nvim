local M = {}

local ui = require("notes_dashboard.ui")

-- Optional config (none required for MVP)
M.config = {}

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
end

function M.open()
  ui.render()
end

function M.close()
  ui.close()
end

return M
