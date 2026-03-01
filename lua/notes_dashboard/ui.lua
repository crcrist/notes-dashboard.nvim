local M = {}

local scanner = require("notes_dashboard.scanner")
local parser  = require("notes_dashboard.parser")

-- State (reset on each render)
local state = {
  bufnr    = nil,
  winnr    = nil,
  line_map = {},  -- 1-indexed line → notes path
  task_map = {},  -- 1-indexed line → { path, file_line, done }
  cwd      = nil, -- captured at render time for [n] new notes
  watchers = {},  -- libuv fs_event handles, stopped on close
}

-- Collapse state persists across renders within a session
local collapsed = {}  -- notes path → bool

-- Debounce flag for watcher-triggered refreshes
local refresh_pending = false

local ns = vim.api.nvim_create_namespace("notes_dashboard")

local BAR_WIDTH = 20

local function setup_highlights()
  vim.api.nvim_set_hl(0, "NotesDashboardBorder",       { link = "FloatBorder", default = true })
  vim.api.nvim_set_hl(0, "NotesDashboardProject",       { bold = true, default = true })
  vim.api.nvim_set_hl(0, "NotesDashboardHeader",        { bold = true, link = "Title", default = true })
  vim.api.nvim_set_hl(0, "NotesDashboardDone",          { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "NotesDashboardPending",       { link = "Normal", default = true })
  vim.api.nvim_set_hl(0, "NotesDashboardTimestamp",     { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "NotesDashboardItem",          { link = "Normal", default = true })
  vim.api.nvim_set_hl(0, "NotesDashboardProgressFill",  { link = "String", default = true })
  vim.api.nvim_set_hl(0, "NotesDashboardProgressEmpty", { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "NotesDashboardAgent",         { link = "Special", default = true })
  vim.api.nvim_set_hl(0, "NotesDashboardEmpty",         { link = "Comment", default = true })
end

local function format_age(path)
  local stat = vim.loop.fs_stat(path)
  if not stat then return "" end
  local age = os.time() - stat.mtime.sec
  if     age < 60    then return age .. "s ago"
  elseif age < 3600  then return math.floor(age / 60) .. "m ago"
  elseif age < 86400 then return math.floor(age / 3600) .. "h ago"
  else                    return math.floor(age / 86400) .. "d ago"
  end
end

local function short_path(p)
  local home = vim.fn.expand("~")
  if p:sub(1, #home) == home then return "~" .. p:sub(#home + 1) end
  return p
end

local function toggle_task(path, file_line, done)
  local lines = vim.fn.readfile(path)
  local line  = lines[file_line]
  if not line then return end
  lines[file_line] = done
    and line:gsub("%[[xX]%]", "[ ]", 1)
    or  line:gsub("%[ %]",    "[x]", 1)
  vim.fn.writefile(lines, path)
end

-- "fix bug (agent-1)" → "fix bug", "agent-1"
-- "fix bug"           → "fix bug", nil
local function parse_agent_tag(text)
  local main, agent = text:match("^(.-)%s+%(([^)]+)%)%s*$")
  if main then return main, agent end
  return text, nil
end

local function pad_to(str, width)
  return str .. string.rep(" ", math.max(0, width - vim.fn.strdisplaywidth(str)))
end

local function stop_watchers()
  for _, w in ipairs(state.watchers) do
    pcall(function() w:stop(); w:close() end)
  end
  state.watchers = {}
end

-- Build buffer lines + highlights from notes entries.
-- Returns: lines, highlights, line_map, task_map, total_pending
local function build_content(entries, win_width)
  -- Layout: │ <space> <text_w cols of content> <space> │
  local text_w = win_width - 4

  local lines, highlights, line_map, task_map = {}, {}, {}, {}
  local total_pending = 0

  local function add(line, path)
    table.insert(lines, line)
    if path then line_map[#lines] = path end
  end

  local function hl(idx, cs, ce, group)
    table.insert(highlights, { idx, cs, ce, group })
  end

  -- Wrap content in box sides. Display width = win_width.
  local function make_line(content)
    return "│ " .. pad_to(" " .. content, text_w) .. " │"
    -- bytes: │(3)+sp(1) + padded + sp(1)+│(3)
    -- display: 1+1 + text_w + 1+1 = win_width ✓
  end

  add("") -- top padding

  -- EMPTY STATE
  if #entries == 0 then
    local l1 = make_line("No notes.md files found in open buffers")
    local l2 = make_line("Press [n] to create one for the current project")
    add(l1, nil); hl(#lines - 1, 3, #l1 - 3, "NotesDashboardEmpty")
    add(l2, nil); hl(#lines - 1, 3, #l2 - 3, "NotesDashboardEmpty")
    add("")
    return lines, highlights, line_map, task_map, 0
  end

  for i, entry in ipairs(entries) do
    local project_name = vim.fn.fnamemodify(entry.dir, ":t")
    local display_dir  = short_path(entry.dir)
    local age          = format_age(entry.path)
    local is_collapsed = collapsed[entry.path]
    local indicator    = is_collapsed and "▸ " or "▾ "

    -- TOP BORDER: ╭─ ▸/▾ project_name  display_dir ──── age ─╮
    local fill_w     = win_width - 2
    local left_text  = "─ " .. indicator .. project_name .. "  " .. display_dir .. " "
    local right_text = " " .. age .. " ─"
    local dashes     = math.max(0, fill_w
      - vim.fn.strdisplaywidth(left_text)
      - vim.fn.strdisplaywidth(right_text))
    local top = "╭" .. left_text .. string.rep("─", dashes) .. right_text .. "╮"

    local top_idx = #lines
    add(top, entry.path)
    hl(top_idx, 0, -1, "NotesDashboardBorder")
    -- project_name byte offset: ╭(3)+─(3)+sp(1)+indicator(▸/▾=3+sp=1=4) = 11
    hl(top_idx, 11, 11 + #project_name, "NotesDashboardProject")
    -- age ends 7 bytes before end: sp(1)+─(3)+╮(3) = 7
    hl(top_idx, #top - 7 - #age, #top - 7, "NotesDashboardTimestamp")

    local bot = "╰" .. string.rep("─", win_width - 2) .. "╯"

    if is_collapsed then
      local bi = #lines
      add(bot, entry.path)
      hl(bi, 0, -1, "NotesDashboardBorder")
    else
      local items = parser.parse(entry.path)
      local total_tasks, done_tasks = 0, 0
      for _, it in ipairs(items) do
        if it.type == "task" then
          total_tasks = total_tasks + 1
          if it.done then done_tasks = done_tasks + 1
          else total_pending = total_pending + 1 end
        end
      end

      -- PROGRESS BAR
      if total_tasks > 0 then
        local filled = math.floor((done_tasks / total_tasks) * BAR_WIDTH)
        local bar = make_line(
          "[" .. string.rep("█", filled) .. string.rep("░", BAR_WIDTH - filled)
          .. "] " .. done_tasks .. "/" .. total_tasks
        )
        local bi = #lines
        add(bar, entry.path)
        hl(bi, 0, 3, "NotesDashboardBorder")
        hl(bi, #bar - 3, #bar, "NotesDashboardBorder")
        -- fill byte offset: │(3)+sp(1)+sp(1)+[(1) = 6
        -- █ and ░ are 3 bytes each in UTF-8
        hl(bi, 6, 6 + filled * 3,        "NotesDashboardProgressFill")
        hl(bi, 6 + filled * 3, 6 + BAR_WIDTH * 3, "NotesDashboardProgressEmpty")
      end

      -- ITEMS
      for _, it in ipairs(items) do
        local fl
        if it.type == "task" then
          local icon       = it.done and "☑" or "☐"
          local txt, agent = parse_agent_tag(it.text)
          local content    = icon .. " " .. txt
          if agent then content = content .. " (" .. agent .. ")" end
          fl = make_line(content)
          local item_hl = it.done and "NotesDashboardDone" or "NotesDashboardPending"
          local ti = #lines
          add(fl, entry.path)
          hl(ti, 0, 3, "NotesDashboardBorder")
          hl(ti, 3, #fl - 3, item_hl)
          hl(ti, #fl - 3, #fl, "NotesDashboardBorder")
          -- agent tag byte offset: │(3)+sp(1)+sp(1)+icon(3)+sp(1)+txt(#txt)+sp(1) = 10+#txt
          -- tag = "(" + agent + ")" = #agent+2 bytes
          if agent then
            local ts = 10 + #txt
            hl(ti, ts, ts + #agent + 2, "NotesDashboardAgent")
          end
          task_map[#lines] = { path = entry.path, file_line = it.line_num, done = it.done }

        elseif it.type == "header" then
          fl = make_line(string.rep("#", it.level) .. " " .. it.text)
          local ii = #lines
          add(fl, entry.path)
          hl(ii, 0, 3, "NotesDashboardBorder")
          hl(ii, 3, #fl - 3, "NotesDashboardHeader")
          hl(ii, #fl - 3, #fl, "NotesDashboardBorder")

        elseif it.type == "item" then
          fl = make_line(" - " .. it.text)
          local ii = #lines
          add(fl, entry.path)
          hl(ii, 0, 3, "NotesDashboardBorder")
          hl(ii, 3, #fl - 3, "NotesDashboardItem")
          hl(ii, #fl - 3, #fl, "NotesDashboardBorder")

        else
          fl = make_line(it.text)
          local ii = #lines
          add(fl, entry.path)
          hl(ii, 0, 3, "NotesDashboardBorder")
          hl(ii, 3, #fl - 3, "NotesDashboardItem")
          hl(ii, #fl - 3, #fl, "NotesDashboardBorder")
        end
      end

      local bi = #lines
      add(bot, entry.path)
      hl(bi, 0, -1, "NotesDashboardBorder")
    end

    if i < #entries then add("", nil) end
  end

  add("") -- bottom padding
  return lines, highlights, line_map, task_map, total_pending
end

function M.render()
  if M.is_open() then M.close() end

  setup_highlights()
  state.cwd = vim.fn.getcwd()

  local entries = scanner.get_active_notes()

  local ui_w  = vim.o.columns
  local ui_h  = vim.o.lines
  local win_w = math.floor(ui_w * 0.8)
  local win_h = math.floor(ui_h * 0.8)
  local row   = math.floor((ui_h - win_h) / 2)
  local col   = math.floor((ui_w - win_w) / 2)

  local content_lines, highlights, line_map, task_map, total_pending =
    build_content(entries, win_w)

  win_h = math.min(win_h, #content_lines + 2)

  local pending_str = total_pending > 0 and (" · " .. total_pending .. " pending") or ""
  local title = " Notes Dashboard" .. pending_str .. " "

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("bufhidden",  "wipe",            { buf = bufnr })
  vim.api.nvim_set_option_value("buftype",    "nofile",          { buf = bufnr })
  vim.api.nvim_set_option_value("filetype",   "notes_dashboard", { buf = bufnr })
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, content_lines)
  vim.api.nvim_set_option_value("modifiable", false,             { buf = bufnr })

  for _, h in ipairs(highlights) do
    vim.api.nvim_buf_add_highlight(bufnr, ns, h[4], h[1], h[2], h[3])
  end

  local winnr = vim.api.nvim_open_win(bufnr, true, {
    relative   = "editor",
    row        = row,
    col        = col,
    width      = win_w,
    height     = win_h,
    style      = "minimal",
    border     = "rounded",
    title      = title,
    title_pos  = "left",
    footer     = "  [e] edit  [<Space>] toggle  [a] add task  [<Tab>] collapse  [r] refresh  [n] new notes  [q] close  ",
    footer_pos = "center",
  })

  vim.api.nvim_set_option_value("wrap",       false, { win = winnr })
  vim.api.nvim_set_option_value("cursorline", true,  { win = winnr })

  state.bufnr    = bufnr
  state.winnr    = winnr
  state.line_map = line_map
  state.task_map = task_map

  local function map(key, fn, desc)
    vim.keymap.set("n", key, fn, { buffer = bufnr, nowait = true, desc = desc })
  end

  map("q",     function() M.close() end, "Close")
  map("<Esc>", function() M.close() end, "Close")
  map("r",     function() M.render() end, "Refresh")

  -- Open notes.md under cursor
  local function open_notes()
    local path = state.line_map[vim.api.nvim_win_get_cursor(winnr)[1]]
    if path then
      M.close()
      vim.cmd("vsplit " .. vim.fn.fnameescape(path))
    end
  end
  map("e",    open_notes, "Edit notes.md")
  map("<CR>", open_notes, "Edit notes.md")

  -- Toggle task checkbox
  map("<Space>", function()
    local cursor = vim.api.nvim_win_get_cursor(state.winnr)[1]
    local task   = state.task_map[cursor]
    if task then
      toggle_task(task.path, task.file_line, task.done)
      local restore = cursor
      M.render()
      if state.winnr and vim.api.nvim_win_is_valid(state.winnr) then
        vim.api.nvim_win_set_cursor(state.winnr,
          { math.min(restore, vim.api.nvim_buf_line_count(state.bufnr)), 0 })
      end
    end
  end, "Toggle task")

  -- Collapse/expand project under cursor
  map("<Tab>", function()
    local path = state.line_map[vim.api.nvim_win_get_cursor(state.winnr)[1]]
    if path then
      collapsed[path] = not collapsed[path]
      local restore = vim.api.nvim_win_get_cursor(state.winnr)[1]
      M.render()
      if state.winnr and vim.api.nvim_win_is_valid(state.winnr) then
        vim.api.nvim_win_set_cursor(state.winnr,
          { math.min(restore, vim.api.nvim_buf_line_count(state.bufnr)), 0 })
      end
    end
  end, "Collapse/expand project")

  -- Add task to the project under cursor
  map("a", function()
    local path = state.line_map[vim.api.nvim_win_get_cursor(state.winnr)[1]]
    if not path then return end
    vim.ui.input({ prompt = "New task: " }, function(input)
      if not input or input == "" then return end
      local file_lines = vim.fn.readfile(path)
      table.insert(file_lines, "- [ ] " .. input)
      vim.fn.writefile(file_lines, path)
      M.render()
    end)
  end, "Add task")

  -- Create notes.md in cwd, or open it if it already exists
  map("n", function()
    local notes_path = state.cwd .. "/notes.md"
    if vim.fn.filereadable(notes_path) == 1 then
      M.close()
      vim.cmd("vsplit " .. vim.fn.fnameescape(notes_path))
      return
    end
    local name = vim.fn.fnamemodify(state.cwd, ":t")
    vim.fn.writefile({ "## " .. name, "", "- [ ] " }, notes_path)
    M.render()
  end, "Create/open notes.md for cwd")

  -- Auto-close when leaving the window
  vim.api.nvim_create_autocmd("WinLeave", {
    buffer   = bufnr,
    once     = true,
    callback = function() M.close() end,
  })

  -- File watchers: auto-refresh when any tracked notes.md changes on disk
  for _, entry in ipairs(entries) do
    local w = vim.loop.new_fs_event()
    if w then
      w:start(entry.path, {}, vim.schedule_wrap(function(err)
        if err or refresh_pending then return end
        refresh_pending = true
        vim.defer_fn(function()
          refresh_pending = false
          if M.is_open() then M.render() end
        end, 150)
      end))
      table.insert(state.watchers, w)
    end
  end
end

function M.is_open()
  return state.winnr ~= nil and vim.api.nvim_win_is_valid(state.winnr)
end

function M.close()
  stop_watchers()
  if state.winnr and vim.api.nvim_win_is_valid(state.winnr) then
    vim.api.nvim_win_close(state.winnr, true)
  end
  state.winnr    = nil
  state.bufnr    = nil
  state.line_map = {}
  state.task_map = {}
end

return M
