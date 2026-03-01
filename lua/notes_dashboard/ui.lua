local M = {}

local scanner = require("notes_dashboard.scanner")
local parser = require("notes_dashboard.parser")

-- State
local state = {
  bufnr = nil,
  winnr = nil,
  line_map = {},  -- line (1-indexed) → notes path
  task_map = {},  -- line (1-indexed) → { path, file_line, done }
}

local ns = vim.api.nvim_create_namespace("notes_dashboard")

local BAR_WIDTH = 20

-- Setup highlight groups
local function setup_highlights()
  vim.api.nvim_set_hl(0, "NotesDashboardBorder", { link = "FloatBorder", default = true })
  vim.api.nvim_set_hl(0, "NotesDashboardTitle", { bold = true, default = true })
  vim.api.nvim_set_hl(0, "NotesDashboardProject", { bold = true, default = true })
  vim.api.nvim_set_hl(0, "NotesDashboardSep", { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "NotesDashboardHeader", { bold = true, link = "Title", default = true })
  vim.api.nvim_set_hl(0, "NotesDashboardDone", { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "NotesDashboardPending", { link = "Normal", default = true })
  vim.api.nvim_set_hl(0, "NotesDashboardTimestamp", { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "NotesDashboardItem", { link = "Normal", default = true })
  vim.api.nvim_set_hl(0, "NotesDashboardProgressFill", { link = "String", default = true })
  vim.api.nvim_set_hl(0, "NotesDashboardProgressEmpty", { link = "Comment", default = true })
end

-- Format a file's mtime as a human-readable "ago" string
local function format_age(path)
  local stat = vim.loop.fs_stat(path)
  if not stat then return "" end
  local age = os.time() - stat.mtime.sec
  if age < 60 then
    return age .. "s ago"
  elseif age < 3600 then
    return math.floor(age / 60) .. "m ago"
  elseif age < 86400 then
    return math.floor(age / 3600) .. "h ago"
  else
    return math.floor(age / 86400) .. "d ago"
  end
end

-- Shorten a path for display (replace home with ~)
local function short_path(p)
  local home = vim.fn.expand("~")
  if p:sub(1, #home) == home then
    return "~" .. p:sub(#home + 1)
  end
  return p
end

-- Toggle a task checkbox in the actual file on disk
local function toggle_task(path, file_line, done)
  local lines = vim.fn.readfile(path)
  local line = lines[file_line]
  if not line then return end
  if done then
    lines[file_line] = line:gsub("%[[xX]%]", "[ ]", 1)
  else
    lines[file_line] = line:gsub("%[ %]", "[x]", 1)
  end
  vim.fn.writefile(lines, path)
end

-- Build lines + highlight specs from notes entries
-- Returns: lines[], highlights[], line_map{}, task_map{}
local function build_content(entries, win_width)
  -- Each project box: ╭ + (win_width-2 cols) + ╮
  -- Content lines:    │ + space + (win_width-4 cols of text) + space + │
  local text_w = win_width - 4

  local lines = {}
  local highlights = {}
  local line_map = {}
  local task_map = {}

  local function add(line, path)
    table.insert(lines, line)
    if path then line_map[#lines] = path end
  end

  local function hl(line_idx, col_start, col_end, group)
    table.insert(highlights, { line_idx, col_start, col_end, group })
  end

  -- Pad str to exactly `width` display columns
  local function pad_to(str, width)
    local dw = vim.fn.strdisplaywidth(str)
    return str .. string.rep(" ", math.max(0, width - dw))
  end

  -- Wrap content in box sides: │ <space><content padded to text_w> <space>│
  local function make_content_line(content_str)
    local padded = pad_to(" " .. content_str, text_w)
    return "│ " .. padded .. " │"
    -- display: │(1) + space(1) + text_w + space(1) + │(1) = text_w+4 = win_width
  end

  add("") -- top padding

  for i, entry in ipairs(entries) do
    local project_name = vim.fn.fnamemodify(entry.dir, ":t")
    local display_dir = short_path(entry.dir)
    local age = format_age(entry.path)

    -- TOP BORDER: ╭─ project_name  display_dir ──── age ─╮
    local fill_w = win_width - 2
    local left_text = "─ " .. project_name .. "  " .. display_dir .. " "
    local right_text = " " .. age .. " ─"
    local dash_count = math.max(0, fill_w - vim.fn.strdisplaywidth(left_text) - vim.fn.strdisplaywidth(right_text))
    local top_border = "╭" .. left_text .. string.rep("─", dash_count) .. right_text .. "╮"

    local top_idx = #lines
    add(top_border, entry.path)
    hl(top_idx, 0, -1, "NotesDashboardBorder")
    -- project_name: ╭(3 bytes) + ─(3 bytes) + space(1 byte) = byte 7
    hl(top_idx, 7, 7 + #project_name, "NotesDashboardProject")
    -- age: before " ─╮" = space(1) + ─(3) + ╮(3) = 7 bytes from end
    local age_end = #top_border - 7
    hl(top_idx, age_end - #age, age_end, "NotesDashboardTimestamp")

    -- Parse items and count tasks
    local items = parser.parse(entry.path)
    local total_tasks, done_tasks = 0, 0
    for _, item in ipairs(items) do
      if item.type == "task" then
        total_tasks = total_tasks + 1
        if item.done then done_tasks = done_tasks + 1 end
      end
    end

    -- PROGRESS BAR
    if total_tasks > 0 then
      local filled = math.floor((done_tasks / total_tasks) * BAR_WIDTH)
      local bar_line = make_content_line(
        "[" .. string.rep("█", filled) .. string.rep("░", BAR_WIDTH - filled) .. "] " .. done_tasks .. "/" .. total_tasks
      )
      local bar_idx = #lines
      add(bar_line, entry.path)
      hl(bar_idx, 0, 3, "NotesDashboardBorder")
      hl(bar_idx, #bar_line - 3, #bar_line, "NotesDashboardBorder")
      -- fill start: │(3) + space(1) + space(1, leading in content) + [(1) = byte 6
      -- █ and ░ are 3 bytes each in UTF-8
      hl(bar_idx, 6, 6 + filled * 3, "NotesDashboardProgressFill")
      hl(bar_idx, 6 + filled * 3, 6 + BAR_WIDTH * 3, "NotesDashboardProgressEmpty")
    end

    -- ITEMS
    for _, item in ipairs(items) do
      local full_line

      if item.type == "task" then
        local icon = item.done and "☑" or "☐"
        full_line = make_content_line(icon .. " " .. item.text)
        local item_hl = item.done and "NotesDashboardDone" or "NotesDashboardPending"
        local task_idx = #lines
        add(full_line, entry.path)
        hl(task_idx, 0, 3, "NotesDashboardBorder")
        hl(task_idx, 3, #full_line - 3, item_hl)
        hl(task_idx, #full_line - 3, #full_line, "NotesDashboardBorder")
        task_map[#lines] = { path = entry.path, file_line = item.line_num, done = item.done }

      elseif item.type == "header" then
        full_line = make_content_line(string.rep("#", item.level) .. " " .. item.text)
        local item_idx = #lines
        add(full_line, entry.path)
        hl(item_idx, 0, 3, "NotesDashboardBorder")
        hl(item_idx, 3, #full_line - 3, "NotesDashboardHeader")
        hl(item_idx, #full_line - 3, #full_line, "NotesDashboardBorder")

      elseif item.type == "item" then
        full_line = make_content_line(" - " .. item.text)
        local item_idx = #lines
        add(full_line, entry.path)
        hl(item_idx, 0, 3, "NotesDashboardBorder")
        hl(item_idx, 3, #full_line - 3, "NotesDashboardItem")
        hl(item_idx, #full_line - 3, #full_line, "NotesDashboardBorder")

      else
        full_line = make_content_line(item.text)
        local item_idx = #lines
        add(full_line, entry.path)
        hl(item_idx, 0, 3, "NotesDashboardBorder")
        hl(item_idx, 3, #full_line - 3, "NotesDashboardItem")
        hl(item_idx, #full_line - 3, #full_line, "NotesDashboardBorder")
      end
    end

    -- BOTTOM BORDER: ╰────────────────────────────────────╯
    local bottom_border = "╰" .. string.rep("─", win_width - 2) .. "╯"
    local bot_idx = #lines
    add(bottom_border, entry.path)
    hl(bot_idx, 0, -1, "NotesDashboardBorder")

    if i < #entries then
      add("", nil)
    end
  end

  add("") -- bottom padding
  return lines, highlights, line_map, task_map
end

function M.render()
  if M.is_open() then
    M.close()
  end

  setup_highlights()

  local entries = scanner.get_active_notes()

  -- Calculate window size
  local ui_w = vim.o.columns
  local ui_h = vim.o.lines
  local win_w = math.floor(ui_w * 0.8)
  local win_h = math.floor(ui_h * 0.8)
  local row = math.floor((ui_h - win_h) / 2)
  local col = math.floor((ui_w - win_w) / 2)

  -- Build content
  local content_lines, highlights, line_map, task_map = build_content(entries, win_w)

  -- Clamp window height to content
  win_h = math.min(win_h, #content_lines + 2) -- +2 for border

  local project_count = #entries
  local title = " Notes Dashboard "

  -- Create buffer
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = bufnr })
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = bufnr })
  vim.api.nvim_set_option_value("filetype", "notes_dashboard", { buf = bufnr })

  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, content_lines)
  vim.api.nvim_set_option_value("modifiable", false, { buf = bufnr })

  -- Apply highlights
  for _, h in ipairs(highlights) do
    local line_idx, col_start, col_end, group = h[1], h[2], h[3], h[4]
    vim.api.nvim_buf_add_highlight(bufnr, ns, group, line_idx, col_start, col_end)
  end

  -- Create window
  local winnr = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    row = row,
    col = col,
    width = win_w,
    height = win_h,
    style = "minimal",
    border = "rounded",
    title = title,
    title_pos = "left",
    footer = "  [e] edit  [<Space>] toggle  [r] refresh  [q] close  ",
    footer_pos = "center",
  })

  vim.api.nvim_set_option_value("wrap", false, { win = winnr })
  vim.api.nvim_set_option_value("cursorline", true, { win = winnr })

  state.bufnr = bufnr
  state.winnr = winnr
  state.line_map = line_map
  state.task_map = task_map

  -- Keymaps
  local function map(key, fn, desc)
    vim.keymap.set("n", key, fn, { buffer = bufnr, nowait = true, desc = desc })
  end

  map("q", function() M.close() end, "Close Notes Dashboard")
  map("<Esc>", function() M.close() end, "Close Notes Dashboard")
  map("r", function() M.render() end, "Refresh Notes Dashboard")

  local function open_notes_under_cursor()
    local cursor_line = vim.api.nvim_win_get_cursor(winnr)[1]
    local notes_path = state.line_map[cursor_line]
    if notes_path then
      M.close()
      vim.cmd("vsplit " .. vim.fn.fnameescape(notes_path))
    end
  end

  map("e", open_notes_under_cursor, "Edit notes.md")
  map("<CR>", open_notes_under_cursor, "Edit notes.md")

  -- Toggle checkbox under cursor, write to disk, refresh in place
  map("<Space>", function()
    local cursor_line = vim.api.nvim_win_get_cursor(state.winnr)[1]
    local task = state.task_map[cursor_line]
    if task then
      toggle_task(task.path, task.file_line, task.done)
      local restore_line = cursor_line
      M.render()
      if state.winnr and vim.api.nvim_win_is_valid(state.winnr) then
        local line_count = vim.api.nvim_buf_line_count(state.bufnr)
        vim.api.nvim_win_set_cursor(state.winnr, { math.min(restore_line, line_count), 0 })
      end
    end
  end, "Toggle task checkbox")

  -- Auto-close when leaving the window
  vim.api.nvim_create_autocmd("WinLeave", {
    buffer = bufnr,
    once = true,
    callback = function()
      M.close()
    end,
  })
end

function M.is_open()
  return state.winnr ~= nil and vim.api.nvim_win_is_valid(state.winnr)
end

function M.close()
  if state.winnr and vim.api.nvim_win_is_valid(state.winnr) then
    vim.api.nvim_win_close(state.winnr, true)
  end
  state.winnr = nil
  state.bufnr = nil
  state.line_map = {}
  state.task_map = {}
end

return M
