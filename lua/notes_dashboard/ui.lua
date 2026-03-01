local M = {}

local scanner = require("notes_dashboard.scanner")
local parser  = require("notes_dashboard.parser")

local state = {
  bufnr    = nil,
  winnr    = nil,
  line_map = {},
  task_map = {},
  cwd      = nil,
  watchers = {},
}

local collapsed       = {}   -- notes path → bool, persists across renders
local refresh_pending = false
local show_done       = false  -- toggle with [d], persists across renders

local ns        = vim.api.nvim_create_namespace("notes_dashboard")
local BAR_WIDTH = 20
local ITEM_CAP  = 10  -- max items rendered per project before "... N more"

-- Status display config
local STATUS_LABEL = { ready = "● READY", working = "● WORKING", blocked = "● BLOCKED" }
local STATUS_HL    = {
  ready   = "NotesDashboardStatusReady",
  working = "NotesDashboardStatusWorking",
  blocked = "NotesDashboardStatusBlocked",
}

local function setup_highlights()
  vim.api.nvim_set_hl(0, "NotesDashboardBorder",        { link = "FloatBorder",    default = true })
  vim.api.nvim_set_hl(0, "NotesDashboardProject",        { bold = true,             default = true })
  vim.api.nvim_set_hl(0, "NotesDashboardHeader",         { bold = true, link = "Title", default = true })
  vim.api.nvim_set_hl(0, "NotesDashboardDone",           { link = "Comment",        default = true })
  vim.api.nvim_set_hl(0, "NotesDashboardPending",        { link = "Normal",         default = true })
  vim.api.nvim_set_hl(0, "NotesDashboardTimestamp",      { link = "Comment",        default = true })
  vim.api.nvim_set_hl(0, "NotesDashboardItem",           { link = "Normal",         default = true })
  vim.api.nvim_set_hl(0, "NotesDashboardProgressFill",   { link = "String",         default = true })
  vim.api.nvim_set_hl(0, "NotesDashboardProgressEmpty",  { link = "Comment",        default = true })
  vim.api.nvim_set_hl(0, "NotesDashboardAgent",          { link = "Special",        default = true })
  vim.api.nvim_set_hl(0, "NotesDashboardEmpty",          { link = "Comment",        default = true })
  vim.api.nvim_set_hl(0, "NotesDashboardStatusReady",    { link = "DiagnosticOk",   default = true })
  vim.api.nvim_set_hl(0, "NotesDashboardStatusWorking",  { link = "DiagnosticWarn", default = true })
  vim.api.nvim_set_hl(0, "NotesDashboardStatusBlocked",  { link = "DiagnosticError",default = true })
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

-- "fix bug (agent-1)" → "fix bug", "agent-1" / "fix bug" → "fix bug", nil
local function parse_agent_tag(text)
  local main, agent = text:match("^(.-)%s+%(([^)]+)%)%s*$")
  if main then return main, agent end
  return text, nil
end

local function pad_to(str, width)
  return str .. string.rep(" ", math.max(0, width - vim.fn.strdisplaywidth(str)))
end

-- Truncate str to `width` display columns, appending … if clipped
local function truncate_to(str, width)
  if vim.fn.strdisplaywidth(str) <= width then return str end
  local out = vim.fn.strcharpart(str, 0, width - 1)
  while vim.fn.strdisplaywidth(out) > width - 1 do
    out = vim.fn.strcharpart(out, 0, vim.fn.strchars(out) - 1)
  end
  return out .. "…"
end

-- Word-wrap a list of strings to fit within `width` display columns
local function wrap_text(text_lines, width)
  local result = {}
  for _, line in ipairs(text_lines) do
    if vim.fn.strdisplaywidth(line) <= width then
      table.insert(result, line)
    else
      local current, current_w = "", 0
      for word in line:gmatch("%S+") do
        local ww = vim.fn.strdisplaywidth(word)
        if current_w == 0 then
          current, current_w = word, ww
        elseif current_w + 1 + ww <= width then
          current, current_w = current .. " " .. word, current_w + 1 + ww
        else
          table.insert(result, current)
          current, current_w = word, ww
        end
      end
      if current_w > 0 then table.insert(result, current) end
    end
  end
  return result
end

local function stop_watchers()
  for _, w in ipairs(state.watchers) do
    pcall(function() w:stop(); w:close() end)
  end
  state.watchers = {}
end

-- Build a single-column content line: │ <content padded to text_w> │
-- display width = win_width, text_w = win_width - 4
local function make_line(content, text_w)
  return "│ " .. pad_to(" " .. content, text_w) .. " │"
end

-- Build a two-column content line: │ <left padded> │ <right padded> │
-- display: 1+1+left_w+1+1+right_w+1+1 = left_w+right_w+7 = win_width
local function make_two_col_line(left_str, right_str, left_w, right_w)
  return "│ " .. pad_to(" " .. left_str, left_w) .. " │ " .. pad_to(right_str, right_w) .. " │"
end

local function build_content(entries, win_width)
  local text_w = win_width - 4   -- single-column content display width

  local lines, highlights, line_map, task_map = {}, {}, {}, {}
  local total_pending = 0

  local function add(line, path)
    table.insert(lines, line)
    if path then line_map[#lines] = path end
  end

  local function hl(idx, cs, ce, group)
    table.insert(highlights, { idx, cs, ce, group })
  end

  add("")  -- top padding

  -- EMPTY STATE
  if #entries == 0 then
    local l1 = make_line("No notes.md files found in open buffers", text_w)
    local l2 = make_line("Press [n] to create one for the current project", text_w)
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

    -- TOP BORDER ────────────────────────────────────────────────────────────
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
    -- ╭(3)+─(3)+sp(1)+indicator(▸/▾=3+sp=1→4) = byte 11 for project_name
    hl(top_idx, 11, 11 + #project_name, "NotesDashboardProject")
    -- age ends 7 bytes before end: sp(1)+─(3)+╮(3) = 7
    hl(top_idx, #top - 7 - #age, #top - 7, "NotesDashboardTimestamp")

    -- Collapsed: just show bottom border and move on ───────────────────────
    if is_collapsed then
      local bi = #lines
      add("╰" .. string.rep("─", win_width - 2) .. "╯", entry.path)
      hl(bi, 0, -1, "NotesDashboardBorder")
      if i < #entries then add("", nil) end
      goto continue
    end

    -- Parse items and count tasks ──────────────────────────────────────────
    local items = parser.parse(entry.path)
    local total_tasks, done_tasks = 0, 0
    for _, it in ipairs(items) do
      if it.type == "task" then
        total_tasks = total_tasks + 1
        if it.done then done_tasks = done_tasks + 1
        else total_pending = total_pending + 1 end
      end
    end

    -- PROGRESS BAR (full-width, always above any column split) ─────────────
    if total_tasks > 0 then
      local filled = math.floor((done_tasks / total_tasks) * BAR_WIDTH)
      local bar = make_line(
        "[" .. string.rep("█", filled) .. string.rep("░", BAR_WIDTH - filled)
        .. "] " .. done_tasks .. "/" .. total_tasks,
        text_w
      )
      local bi = #lines
      add(bar, entry.path)
      hl(bi, 0, 3, "NotesDashboardBorder")
      hl(bi, #bar - 3, #bar, "NotesDashboardBorder")
      -- fill: │(3)+sp(1)+sp(1)+[(1) = byte 6; █/░ are 3 bytes each in UTF-8
      hl(bi, 6, 6 + filled * 3,          "NotesDashboardProgressFill")
      hl(bi, 6 + filled * 3, 6 + BAR_WIDTH * 3, "NotesDashboardProgressEmpty")
    end

    -- Check for a Context section ──────────────────────────────────────────
    local context = parser.get_context(entry.path)

    if not context then
      -- ── SINGLE COLUMN ───────────────────────────────────────────────────
      local visible, hidden_count = {}, 0
      for _, it in ipairs(items) do
        if it.type == "task" and it.done and not show_done then
          -- skip done tasks when hidden
        elseif #visible < ITEM_CAP then
          table.insert(visible, it)
        else
          hidden_count = hidden_count + 1
        end
      end

      for _, it in ipairs(visible) do
        local fl
        if it.type == "task" then
          local icon       = it.done and "☑" or "☐"
          local txt, agent = parse_agent_tag(it.text)
          local content    = icon .. " " .. txt
          if agent then content = content .. " (" .. agent .. ")" end
          fl = make_line(content, text_w)
          local item_hl = it.done and "NotesDashboardDone" or "NotesDashboardPending"
          local ti = #lines
          add(fl, entry.path)
          hl(ti, 0, 3, "NotesDashboardBorder")
          hl(ti, 3, #fl - 3, item_hl)
          hl(ti, #fl - 3, #fl, "NotesDashboardBorder")
          -- agent: │(3)+sp(1)+sp(1)+icon(3)+sp(1)+txt+sp(1) = byte 10+#txt
          if agent then
            local ts = 10 + #txt
            hl(ti, ts, ts + #agent + 2, "NotesDashboardAgent")
          end
          task_map[#lines] = { path = entry.path, file_line = it.line_num, done = it.done }

        elseif it.type == "header" then
          fl = make_line(string.rep("#", it.level) .. " " .. it.text, text_w)
          local ii = #lines
          add(fl, entry.path)
          hl(ii, 0, 3, "NotesDashboardBorder")
          hl(ii, 3, #fl - 3, "NotesDashboardHeader")
          hl(ii, #fl - 3, #fl, "NotesDashboardBorder")

        elseif it.type == "item" then
          fl = make_line(" - " .. it.text, text_w)
          local ii = #lines
          add(fl, entry.path)
          hl(ii, 0, 3, "NotesDashboardBorder")
          hl(ii, 3, #fl - 3, "NotesDashboardItem")
          hl(ii, #fl - 3, #fl, "NotesDashboardBorder")

        else
          fl = make_line(it.text, text_w)
          local ii = #lines
          add(fl, entry.path)
          hl(ii, 0, 3, "NotesDashboardBorder")
          hl(ii, 3, #fl - 3, "NotesDashboardItem")
          hl(ii, #fl - 3, #fl, "NotesDashboardBorder")
        end
      end

      if hidden_count > 0 then
        local more = make_line("  ... " .. hidden_count .. " more", text_w)
        local mi = #lines
        add(more, entry.path)
        hl(mi, 0, 3, "NotesDashboardBorder")
        hl(mi, 3, #more - 3, "NotesDashboardEmpty")
        hl(mi, #more - 3, #more, "NotesDashboardBorder")
      end

      local bi = #lines
      add("╰" .. string.rep("─", win_width - 2) .. "╯", entry.path)
      hl(bi, 0, -1, "NotesDashboardBorder")

    else
      -- ── TWO COLUMN ──────────────────────────────────────────────────────
      -- Layout: │ sp left_w sp │ sp right_w sp │  → total = left_w+right_w+7 = win_width
      local left_w  = math.floor((win_width - 7) * 0.55)
      local right_w = (win_width - 7) - left_w

      -- Collect left column items (everything before # Context header)
      local left_items = {}
      local hit_context = false
      for _, it in ipairs(items) do
        if it.type == "header" and it.text:lower() == "context" then
          hit_context = true
        end
        if not hit_context then table.insert(left_items, it) end
      end

      -- Filter and cap left column items
      local visible_left, hidden_count = {}, 0
      for _, it in ipairs(left_items) do
        if it.type == "task" and it.done and not show_done then
          -- skip
        elseif #visible_left < ITEM_CAP then
          table.insert(visible_left, it)
        else
          hidden_count = hidden_count + 1
        end
      end

      -- Build left column structs
      local left_col = {}
      for _, it in ipairs(visible_left) do
        if it.type == "task" then
          local icon       = it.done and "☑" or "☐"
          local txt, agent = parse_agent_tag(it.text)
          local content    = icon .. " " .. txt
          if agent then content = content .. " (" .. agent .. ")" end
          table.insert(left_col, {
            content  = content,
            hl       = it.done and "NotesDashboardDone" or "NotesDashboardPending",
            task     = { path = entry.path, file_line = it.line_num, done = it.done },
            agent    = agent,
            txt      = txt,
          })
        elseif it.type == "header" then
          table.insert(left_col, {
            content = string.rep("#", it.level) .. " " .. it.text,
            hl      = "NotesDashboardHeader",
          })
        elseif it.type == "item" then
          table.insert(left_col, { content = " - " .. it.text, hl = "NotesDashboardItem" })
        else
          table.insert(left_col, { content = it.text, hl = "NotesDashboardItem" })
        end
      end
      if hidden_count > 0 then
        table.insert(left_col, {
          content = "  ... " .. hidden_count .. " more",
          hl      = "NotesDashboardEmpty",
        })
      end

      -- Build right column rows: status + divider + wrapped context text
      -- row type: "status" | "divider" | "text"
      local right_col = {}
      if context.status then
        table.insert(right_col, { type = "status", status = context.status })
        table.insert(right_col, { type = "divider" })
      end
      for _, l in ipairs(wrap_text(context.lines, right_w)) do
        table.insert(right_col, { type = "text", text = l })
      end

      -- COLUMN DIVIDER ROW: ├──────────┬──────────┤
      local col_div = "├" .. string.rep("─", left_w + 2) .. "┬" .. string.rep("─", right_w + 2) .. "┤"
      local cd_idx  = #lines
      add(col_div, entry.path)
      hl(cd_idx, 0, -1, "NotesDashboardBorder")

      -- RENDER ROWS (zip left and right, padding whichever is shorter)
      local n_rows = math.max(#left_col, #right_col)
      for row = 1, n_rows do
        local lc = left_col[row]
        local rc = right_col[row]

        -- truncate_to(left_w-1): -1 for the leading space prefix
        local left_str    = lc and (" " .. truncate_to(lc.content, left_w - 1)) or " "
        local left_padded = pad_to(left_str, left_w)

        if rc and rc.type == "divider" then
          -- Status separator: left side normal, right side becomes ├────┤
          -- "│ " + left_padded + " ├" + "─"*(right_w+2) + "┤"
          local div_line = "│ " .. left_padded .. " ├" .. string.rep("─", right_w + 2) .. "┤"
          local di = #lines
          add(div_line, entry.path)
          hl(di, 0, 3, "NotesDashboardBorder")
          if lc then hl(di, 4, 4 + #left_padded, lc.hl) end
          -- " ├" starts at byte 4+#left_padded+1; highlight rest as border
          hl(di, 4 + #left_padded + 1, #div_line, "NotesDashboardBorder")
          if lc and lc.task then task_map[#lines] = lc.task end

        else
          -- Normal two-column line
          local right_str    = ""
          local right_hl_grp = nil
          if rc then
            if rc.type == "status" then
              right_str    = STATUS_LABEL[rc.status] or ("● " .. rc.status:upper())
              right_hl_grp = STATUS_HL[rc.status]
            elseif rc.type == "text" then
              right_str    = rc.text
              right_hl_grp = "NotesDashboardItem"
            end
          end

          local right_padded = pad_to(right_str, right_w)
          local fl = "│ " .. left_padded .. " │ " .. right_padded .. " │"
          -- Byte layout:
          --   │(3) sp(1) = 4B
          --   left_padded = #left_padded B
          --   sp(1) │(3) sp(1) = 5B  ← inner sep at byte 4+#left_padded+1
          --   right_padded = #right_padded B
          --   sp(1) │(3) = 4B

          local fi         = #lines
          local inner_byte = 4 + #left_padded + 1  -- byte where inner │ starts
          add(fl, entry.path)

          -- Border chars
          hl(fi, 0, 3, "NotesDashboardBorder")
          hl(fi, inner_byte, inner_byte + 3, "NotesDashboardBorder")
          hl(fi, #fl - 3, #fl, "NotesDashboardBorder")

          -- Left content
          if lc then
            hl(fi, 4, 4 + #left_padded, lc.hl)
            -- Agent tag: │(3)+sp(1)+sp(1)+icon(3)+sp(1)+txt+sp(1) → byte 10+#txt
            if lc.agent then
              local ts = 10 + #lc.txt
              hl(fi, ts, ts + #lc.agent + 2, "NotesDashboardAgent")
            end
          end

          -- Right content: starts after inner │(3)+sp(1) = inner_byte+4
          if right_hl_grp then
            local rs = inner_byte + 4
            hl(fi, rs, rs + #right_padded, right_hl_grp)
          end

          if lc and lc.task then task_map[#lines] = lc.task end
        end
      end

      -- BOTTOM BORDER WITH COLUMN SPLIT: ╰──────┴──────╯
      local bot = "╰" .. string.rep("─", left_w + 2) .. "┴" .. string.rep("─", right_w + 2) .. "╯"
      local bi  = #lines
      add(bot, entry.path)
      hl(bi, 0, -1, "NotesDashboardBorder")
    end

    if i < #entries then add("", nil) end
    ::continue::
  end

  add("")  -- bottom padding
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
    footer     = "  [e] edit  [<Space>] toggle  [a] add  [d] done  [<Tab>] collapse  [r] refresh  [n] new  [q] close  ",
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
  map("d",     function() show_done = not show_done; M.render() end, "Toggle done tasks")

  local function open_notes()
    local path = state.line_map[vim.api.nvim_win_get_cursor(winnr)[1]]
    if path then
      M.close()
      vim.cmd("vsplit " .. vim.fn.fnameescape(path))
    end
  end
  map("e",    open_notes, "Edit notes.md")
  map("<CR>", open_notes, "Edit notes.md")

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

  map("a", function()
    local path = state.line_map[vim.api.nvim_win_get_cursor(state.winnr)[1]]
    if not path then return end
    vim.ui.input({ prompt = "New task: " }, function(input)
      if not input or input == "" then return end
      local file_lines = vim.fn.readfile(path)
      -- Insert before # Context section (or append if none)
      local insert_at = #file_lines + 1
      for j, l in ipairs(file_lines) do
        if l:match("^#+%s+[Cc]ontext%s*$") then
          insert_at = j
          -- place before any blank line that precedes the header
          if j > 1 and file_lines[j - 1]:match("^%s*$") then
            insert_at = j - 1
          end
          break
        end
      end
      table.insert(file_lines, insert_at, "- [ ] " .. input)
      vim.fn.writefile(file_lines, path)
      M.render()
    end)
  end, "Add task")

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
