vim.api.nvim_create_user_command("NotesDashboard", function()
  require("notes_dashboard").open()
end, { desc = "Open Notes Dashboard" })

vim.keymap.set("n", "<leader>nd", function()
  require("notes_dashboard").open()
end, { desc = "Open Notes Dashboard" })
