# notes-dashboard.nvim

A Neovim plugin that surfaces your project notes in a floating dashboard — without you having to go find them.

![notes-dashboard screenshot](Screenshot%202026-03-01%20125043.png)

---

## What it does

Drop a `notes.md` file in any project folder. When you open the dashboard, the plugin walks up the directory tree from every open buffer, finds those `notes.md` files, and renders them all in one floating window — one card per project.

Each card shows:
- Project name, path, and how recently the file was modified
- A task progress bar (`done / total`)
- All your headers, tasks, list items, and text

You can toggle tasks done/undone directly from the dashboard. The change is written to the file on disk immediately.

---

## Installation

**lazy.nvim**
```lua
{
  "crcrist/notes-dashboard.nvim",
  config = function()
    require("notes_dashboard").setup()
  end,
}
```

**packer.nvim**
```lua
use {
  "crcrist/notes-dashboard.nvim",
  config = function()
    require("notes_dashboard").setup()
  end,
}
```

No required dependencies. No configuration needed to get started.

---

## Usage

Open the dashboard:
- Keybinding: `<leader>nd`
- Command: `:NotesDashboard`

Inside the dashboard:

| Key | Action |
|-----|--------|
| `<Space>` | Toggle task checkbox (writes to disk) |
| `e` or `<Enter>` | Open the notes file in a vertical split |
| `r` | Refresh the dashboard |
| `q` or `<Esc>` | Close |

---

## notes.md format

Standard markdown. The plugin parses:

```markdown
## Section header

- [ ] An incomplete task
- [x] A completed task
- A regular list item

Plain text also works.
```

Put a `notes.md` anywhere in your project tree. The plugin finds it automatically when you have files from that project open in Neovim.

---

## How discovery works

When you open the dashboard, the plugin looks at every loaded buffer. For each one, it walks up the directory tree until it finds a `notes.md` or reaches your home directory. Each unique `notes.md` gets its own card. No configuration required — just have files open and the notes appear.
