local M = {}

-- Walk up from `dir`, return the path to notes.md if found.
-- Stops when a notes.md is found, the home dir is reached, or the filesystem root is reached.
function M.find_notes_md(dir)
  local home = vim.fn.expand("~")
  local current = dir

  while true do
    local notes_path = current .. "/notes.md"
    if vim.fn.filereadable(notes_path) == 1 then
      return notes_path
    end

    -- Stop at home directory
    if current == home then
      return nil
    end

    -- Walk up one level
    local parent = vim.fn.fnamemodify(current, ":h")
    if parent == current then
      -- Reached filesystem root
      return nil
    end
    current = parent
  end
end

-- Returns list of { dir, path } for each unique notes.md reachable from open buffers.
function M.get_active_notes()
  local seen = {}
  local results = {}

  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if not vim.api.nvim_buf_is_loaded(bufnr) then goto continue end

    local bufname = vim.api.nvim_buf_get_name(bufnr)
    if bufname == "" then goto continue end

    -- Skip non-file buffers (terminals, etc.)
    local buftype = vim.api.nvim_get_option_value("buftype", { buf = bufnr })
    if buftype ~= "" then goto continue end

    local dir = vim.fn.fnamemodify(bufname, ":h")
    local notes_path = M.find_notes_md(dir)

    if notes_path and not seen[notes_path] then
      seen[notes_path] = true
      table.insert(results, {
        dir = vim.fn.fnamemodify(notes_path, ":h"),
        path = notes_path,
      })
    end

    ::continue::
  end

  return results
end

return M
