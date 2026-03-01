local M = {}

-- Parse a notes.md file into a list of structured items.
-- Each item: { type, text, done?, level?, raw }
--   type: "task" | "header" | "item" | "text"
--   done: boolean (tasks only)
--   level: number (headers only, 1-6)
function M.parse(path)
  local items = {}
  local file = io.open(path, "r")
  if not file then return items end

  local line_num = 0
  for line in file:lines() do
    line_num = line_num + 1

    -- Skip blank lines — UI uses them as visual separators
    if line:match("^%s*$") then
      goto continue
    end

    -- Task: - [ ] or - [x] (case-insensitive x)
    local done_marker, task_text = line:match("^%s*%-%s*%[([xX ])%]%s*(.*)")
    if done_marker then
      table.insert(items, {
        type = "task",
        text = task_text,
        done = done_marker:lower() == "x",
        line_num = line_num,
        raw = line,
      })
      goto continue
    end

    -- Header: ## text
    local hashes, header_text = line:match("^(#+)%s+(.*)")
    if hashes then
      table.insert(items, {
        type = "header",
        text = header_text,
        level = #hashes,
        line_num = line_num,
        raw = line,
      })
      goto continue
    end

    -- List item: - text (not a task)
    local item_text = line:match("^%s*%-%s+(.*)")
    if item_text then
      table.insert(items, {
        type = "item",
        text = item_text,
        line_num = line_num,
        raw = line,
      })
      goto continue
    end

    -- Plain text
    table.insert(items, {
      type = "text",
      text = line,
      line_num = line_num,
      raw = line,
    })

    ::continue::
  end

  file:close()
  return items
end

return M
